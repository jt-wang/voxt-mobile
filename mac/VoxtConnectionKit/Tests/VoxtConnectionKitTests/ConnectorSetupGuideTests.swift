import Foundation
import Testing
@testable import VoxtConnectionKit

private typealias Facts = ConnectorSetupFacts
private let ready = ConnectorModelStatus(transcription: .ready, text: .ready)

/// Every step in order, from nothing done to a paired phone.
@Test func guideTicksOffEachStepInOrder() {
    let all = Set(ConnectorSetupStep.allCases)
    let cases: [(Facts, ConnectorSetupStep?, Set<ConnectorSetupStep>)] = [
        (Facts(), .openVoxt, []),
        (Facts(voxtRunning: true), .permissions, [.openVoxt]),
        (Facts(voxtRunning: true, permissionsConfirmed: true), .turnOnLocalAPI, [.openVoxt, .permissions]),
        (Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true), .allowConnector,
         [.openVoxt, .permissions, .turnOnLocalAPI]),
        (Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .waitingForApproval), .allowConnector,
         [.openVoxt, .permissions, .turnOnLocalAPI]),
        (Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected), .chooseModels,
         [.openVoxt, .permissions, .turnOnLocalAPI, .allowConnector]),
        (Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected, models: ready), .addPhone,
         all.subtracting([.addPhone])),
        (Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected, models: ready, pairedPhones: 1),
         nil, all),
    ]
    for (facts, current, done) in cases {
        #expect(facts.current == current, "\(facts)")
        #expect(facts.done == done, "\(facts)")
    }
}

/// Phone dictation needs neither Microphone nor Accessibility for Voxt: the phone sends a recorded
/// file over the Local API and the text comes back to the phone. So the permissions step is optional:
/// it is shown right after Voxt opens, when macOS asks, and stops being the current step once any
/// later step is done. Connector can't read another app's grants, so only the user's Done ticks it.
@Test func permissionsAreOptionalAndTickOnlyFromTheUser() {
    #expect(ConnectorSetupStep.permissions.isOptional)
    #expect(ConnectorSetupStep.allCases.filter(\.isOptional) == [.permissions])
    let rest = Facts(voxtRunning: true, voxtAnswers: true, link: .connected, models: ready, pairedPhones: 1)
    #expect(rest.done == Set(ConnectorSetupStep.allCases).subtracting([.permissions]))
    #expect(rest.current == nil, "finished without the optional step")
    let justOpened = Facts(voxtRunning: true)
    #expect(justOpened.current == .permissions, "shown while macOS asks for them")
    let skipped = Facts(voxtRunning: true, voxtAnswers: true)
    #expect(skipped.current == .allowConnector, "a later step done moves past it")
    #expect(!skipped.isDone(.permissions))
    #expect(skipped.isSkipped(.permissions))
    #expect(!justOpened.isSkipped(.permissions))
    #expect(!Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true).isSkipped(.permissions))
    let confirmedEarly = Facts(permissionsConfirmed: true)
    #expect(confirmedEarly.done == [.permissions])
    #expect(confirmedEarly.current == .openVoxt)
}

@Test func modelsCountOnlyWhenBothAreReady() {
    for (transcription, text) in [(ConnectorModelReadiness.ready, ConnectorModelReadiness.missing), (.ready, .off),
                                  (.missing, .ready), (.unsupported, .ready), (.ready, .unsupported)] {
        let facts = Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected,
                          models: .init(transcription: transcription, text: text))
        #expect(!facts.isDone(.chooseModels), "\(transcription) / \(text)")
        #expect(facts.current == .chooseModels)
    }
    let unread = Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected, models: nil)
    #expect(unread.current == .chooseModels, "an older Voxt that reports no models never ticks the step")
}

@Test func laterEvidenceImpliesEarlierSteps() {
    // Voxt answering on its socket means it runs, even under a bundle ID NSWorkspace wasn't asked about.
    let answers = Facts(voxtAnswers: true)
    #expect(answers.done == [.openVoxt, .turnOnLocalAPI])
    // Waiting for the Allow dialog means Voxt answered.
    let waiting = Facts(link: .waitingForApproval)
    #expect(waiting.done == [.openVoxt, .turnOnLocalAPI])
    #expect(waiting.current == .allowConnector)
    let connected = Facts(link: .connected)
    #expect(connected.done == [.openVoxt, .turnOnLocalAPI, .allowConnector])
    // Ready models read before the Connector connected don't count: they can only come from a connected read.
    let modelsWithoutLink = Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, models: ready)
    #expect(!modelsWithoutLink.isDone(.chooseModels))
    #expect(modelsWithoutLink.current == .allowConnector)
}

@Test func outOfOrderStatesPointAtTheFirstUnfinishedStep() {
    // A phone paired earlier, Voxt quit since: the phone step stays done, the guide points at Voxt.
    let quit = Facts(pairedPhones: 2)
    #expect(quit.done == [.addPhone])
    #expect(quit.current == .openVoxt)
    // Connected and paired, but the text model was turned off in Voxt.
    let textOff = Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected,
                        models: .init(transcription: .ready, text: .off), pairedPhones: 1)
    #expect(textOff.current == .chooseModels)
    #expect(textOff.isDone(.addPhone))
    // Local API turned off after connecting once: Voxt runs but doesn't answer.
    let apiOff = Facts(voxtRunning: true, permissionsConfirmed: true, pairedPhones: 1)
    #expect(apiOff.current == .turnOnLocalAPI)
}

@Test func guideOpensAtLaunchOnlyUntilFinishedAndWithoutAPhone() {
    #expect(Facts.showsAtLaunch(guideFinished: false, pairedPhones: 0))
    #expect(!Facts.showsAtLaunch(guideFinished: false, pairedPhones: 1), "phone already paired")
    #expect(!Facts.showsAtLaunch(guideFinished: true, pairedPhones: 0), "finished once")
    #expect(!Facts.showsAtLaunch(guideFinished: true, pairedPhones: 3))
}

@MainActor @Test func guideFollowsTheCurrentStepUnlessTheUserPickedOne() {
    var finished = 0
    let preferences = TestPreferences()
    let guide = ConnectorSetupGuide(preferences: preferences, onFinished: { finished += 1 })
    #expect(guide.screen == .step(.openVoxt))
    guide.update(Facts(voxtRunning: true))
    #expect(guide.screen == .step(.permissions), "advances when a step is done")
    guide.show(.addPhone)
    #expect(guide.screen == .step(.addPhone))
    guide.update(Facts(voxtRunning: true))
    #expect(guide.screen == .step(.addPhone), "the same facts keep the user's choice")
    guide.update(Facts(voxtRunning: true, permissionsConfirmed: true))
    #expect(guide.screen == .step(.turnOnLocalAPI), "a newly finished current step moves on")
    guide.show(.addPhone)
    guide.update(Facts(voxtRunning: true, permissionsConfirmed: true, pairedPhones: 1))
    #expect(guide.screen == .step(.addPhone), "a new fact that leaves the current step alone keeps the choice")
    guide.update(Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, pairedPhones: 1))
    #expect(guide.screen == .step(.allowConnector), "a newly finished current step moves on")
    #expect(finished == 0)
    let all = Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected, models: ready, pairedPhones: 1)
    guide.update(all)
    #expect(guide.screen == .finished)
    guide.update(all)
    #expect(finished == 1, "finishing is reported once")
    #expect(preferences.setupGuideFinished, "a finished guide doesn't open at the next launch")
}

@MainActor @Test func nextMovesOneStepAndStopsAtTheLast() {
    let guide = ConnectorSetupGuide(preferences: TestPreferences())
    guide.next()
    #expect(guide.screen == .step(.permissions))
    guide.show(.addPhone)
    #expect(!guide.hasNext)
    guide.next()
    #expect(guide.screen == .step(.addPhone))
    guide.show(.chooseModels)
    #expect(guide.hasNext)
}

/// Facts come from the probes and the app model; the models are read only once connected.
@MainActor @Test func refreshReadsProbesAndTheConnectedModel() async {
    let store = SetupStoreFixture()
    var capabilityReads = 0
    let model = ConnectorAppModel(runtimeURL: URL(fileURLWithPath: "/missing-owned-runtime"), store: store,
        health: { _, _ in .init(ok: true, app: "Voxt", version: "fixture") },
        capabilities: { port, token in
            capabilityReads += 1
            #expect(port == 47920); #expect(token == "owned-fixture")
            return .init(models: .init(transcription: .ready, text: .missing))
        }, authorizer: nil, preferences: TestPreferences())
    let voxt = VoxtFlags()
    let probes = ConnectorSetupProbes(voxtRunning: { voxt.running }, voxtAnswers: { voxt.answers })
    let preferences = TestPreferences()
    let guide = ConnectorSetupGuide(preferences: preferences)
    await guide.refresh(model: model, probes: probes)
    #expect(guide.facts == Facts())
    guide.confirmPermissions()
    #expect(preferences.setupPermissionsConfirmed, "kept for the next time the guide opens")
    #expect(guide.facts == Facts(permissionsConfirmed: true))
    await guide.refresh(model: model, probes: probes)
    #expect(guide.facts == Facts(permissionsConfirmed: true))
    #expect(capabilityReads == 0, "nothing to read before the Connector is connected")
    voxt.running = true; voxt.answers = true
    model.port = "47920"; model.token = "owned-fixture"
    await model.connect()
    await guide.refresh(model: model, probes: probes)
    #expect(guide.facts == Facts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true, link: .connected,
                                 models: .init(transcription: .ready, text: .missing)))
    #expect(capabilityReads == 1)
    store.value = .init(allowedClients: ["nodekey:" + String(repeating: "b", count: 64)], state: nil)
    await guide.refresh(model: model, probes: probes)
    #expect(guide.facts.pairedPhones == 1)
}

@MainActor @Test func modelStatusIsNilWhenTheReadFails() async {
    let model = ConnectorAppModel(runtimeURL: URL(fileURLWithPath: "/missing-owned-runtime"), store: SetupStoreFixture(),
        health: { _, _ in .init(ok: true, app: "Voxt", version: "fixture") },
        capabilities: { _, _ in throw LocalInferenceClient.Failure.unavailable }, authorizer: nil, preferences: TestPreferences())
    #expect(await model.modelStatus() == nil, "not connected")
    model.token = "owned-fixture"; await model.connect()
    #expect(await model.modelStatus() == nil, "read failed")
}

@Test func capabilitiesDecodeTheContractFixture() throws {
    // contract/capabilities.json as recorded from Voxt.
    let fixture = #"""
    {"api":{"major":1,"minor":0},"app":"Voxt",
     "audio":{"contentTypes":["audio/wav"],"maxBodyBytes":26214400},
     "endpoints":["health","capabilities","dictations","history/sync","compose","compose/prompts","corrections"],
     "locations":{"text":"local","transcription":"local"},
     "models":{"text":"ready","transcription":"ready"},"version":"1.16.0"}
    """#
    let decoded = try JSONDecoder().decode(LocalInferenceClient.Capabilities.self, from: Data(fixture.utf8))
    #expect(decoded.models == ready)
    let others = try JSONDecoder().decode(LocalInferenceClient.Capabilities.self,
        from: Data(#"{"models":{"transcription":"unsupported","text":"off"}}"#.utf8))
    #expect(others.models == .init(transcription: .unsupported, text: .off))
    let unknown = try JSONDecoder().decode(LocalInferenceClient.Capabilities.self,
        from: Data(#"{"models":{"transcription":"warming","text":"ready"}}"#.utf8))
    #expect(unknown.models == .init(transcription: .missing, text: .ready), "a value this build doesn't know is not ready")
    let older = try JSONDecoder().decode(LocalInferenceClient.Capabilities.self, from: Data(#"{"app":"Voxt"}"#.utf8))
    #expect(older.models == nil)
}

@Test func socketProbeAnswersOnlyForAListeningVoxt() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: String(UUID().uuidString.prefix(6)))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let live = folder.appending(path: "l.sock").path, stale = folder.appending(path: "s.sock").path
    let listener = try listen(at: live)
    defer { close(listener) }
    close(try listen(at: stale))   // a quit Voxt leaves its socket file behind
    #expect(ConnectorLink.voxtAnswers(paths: [live]))
    #expect(ConnectorLink.voxtAnswers(paths: [folder.appending(path: "missing.sock").path, live]))
    #expect(!ConnectorLink.voxtAnswers(paths: [stale]))
    #expect(!ConnectorLink.voxtAnswers(paths: [folder.appending(path: "missing.sock").path]))
    // The probe sends nothing: Voxt reads end of file and shows no dialog.
    let client = accept(listener, nil, nil)
    #expect(client >= 0)
    var byte: UInt8 = 0
    #expect(read(client, &byte, 1) == 0)
    close(client)
}

private func listen(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(fd, 4) == 0)
    return fd
}

@MainActor private final class VoxtFlags {
    var running = false
    var answers = false
}

@MainActor private final class SetupStoreFixture: ConnectorConfigurationStore {
    var value = ConnectorConfiguration(allowedClients: [], state: nil)
    func load() throws -> ConnectorConfiguration { value }
    func save(_ value: ConnectorConfiguration) throws { self.value = value }
}

@MainActor @Test func aConfirmationFromAnEarlierRunIsKept() {
    let preferences = TestPreferences()
    preferences.setupPermissionsConfirmed = true
    #expect(ConnectorSetupGuide(preferences: preferences).facts == Facts(permissionsConfirmed: true))
}

/// The add-iPhone step links where the build says (VOXT_IPHONE_APP_URL, Info.plist VoxtIPhoneAppURL),
/// or to the upstream setup steps, which say how to build the iPhone app.
@Test func iPhoneAppLinkComesFromTheBuildOrFallsBackToTheSetupSteps() {
    let steps = URL(string: "https://github.com/sgl-project/sglang-omni/tree/main/Voxt/Mobile#set-it-up")!
    #expect(ConnectorIPhoneApp.setupSteps == steps)
    let key = ConnectorIPhoneApp.infoKey
    let unset: [[String: Any]?] = [nil, [:], [key: ""], [key: "$(VOXT_IPHONE_APP_URL)"], [key: 3],
                                   [key: "github.com/sgl-project/sglang-omni/tree/main/Voxt/Mobile#set-it-up"]]
    for info in unset {
        let app = ConnectorIPhoneApp(info: info)
        #expect(app.url == steps, "\(String(describing: info))")
        #expect(app.isSetupSteps)
    }
    // xcconfig reads // as a comment, so the setting has no scheme; https is added.
    let named = ConnectorIPhoneApp(info: [key: "beta.example.com/join/abc/"])
    #expect(named.url == URL(string: "https://beta.example.com/join/abc")!)
    #expect(!named.isSetupSteps)
    #expect(named.shownAddress == "beta.example.com/join/abc")
    #expect(ConnectorIPhoneApp(info: [key: "https://apps.example.com/voxt"]).url == URL(string: "https://apps.example.com/voxt")!)
}
