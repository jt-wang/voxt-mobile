import AppKit
import Foundation
import Observation

/// The first-run guide's steps, in the order Connector can detect them: the models can only be
/// read from Voxt's Local API once Voxt has allowed this Connector.
public enum ConnectorSetupStep: Int, CaseIterable, Identifiable, Sendable {
    case openVoxt, permissions, turnOnLocalAPI, allowConnector, chooseModels, addPhone
    public var id: Int { rawValue }
    /// Voxt's Microphone and Accessibility serve dictation on the Mac itself; the phone sends a
    /// recorded file over the Local API and gets the text back, and nothing is pasted on the Mac.
    public var isOptional: Bool { self == .permissions }
}

/// One model's state as Voxt's `GET /v1/capabilities` reports it under `models`.
public enum ConnectorModelReadiness: String, Equatable, Sendable {
    case ready, missing, off, unsupported
}

public struct ConnectorModelStatus: Equatable, Sendable, Decodable {
    public var transcription: ConnectorModelReadiness
    public var text: ConnectorModelReadiness
    public init(transcription: ConnectorModelReadiness, text: ConnectorModelReadiness) {
        self.transcription = transcription; self.text = text
    }
    public var isReady: Bool { transcription == .ready && text == .ready }

    private enum CodingKeys: String, CodingKey { case transcription, text }
    /// A value this build doesn't know counts as not ready.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> ConnectorModelReadiness {
            ConnectorModelReadiness(rawValue: try container.decode(String.self, forKey: key)) ?? .missing
        }
        transcription = try value(.transcription); text = try value(.text)
    }
}

/// What Connector knows about the setup at one moment.
public struct ConnectorSetupFacts: Equatable, Sendable {
    public enum Link: Equatable, Sendable { case notConnected, waitingForApproval, connected }
    /// A Voxt app from VoxtBundleIdentifiers is running.
    public var voxtRunning: Bool
    /// The user clicked Done on the permissions step; Connector can't read another app's grants.
    public var permissionsConfirmed: Bool
    /// Voxt accepts a connection on its Connector socket, which it opens only while the Local API is on.
    public var voxtAnswers: Bool
    public var link: Link
    /// nil until read from a connected Voxt, or when that Voxt doesn't report models.
    public var models: ConnectorModelStatus?
    public var pairedPhones: Int

    public init(voxtRunning: Bool = false, permissionsConfirmed: Bool = false, voxtAnswers: Bool = false,
                link: Link = .notConnected, models: ConnectorModelStatus? = nil, pairedPhones: Int = 0) {
        self.voxtRunning = voxtRunning; self.permissionsConfirmed = permissionsConfirmed
        self.voxtAnswers = voxtAnswers; self.link = link; self.models = models; self.pairedPhones = pairedPhones
    }

    /// Later evidence implies earlier steps: a connected Voxt answered, and an answering Voxt runs.
    public func isDone(_ step: ConnectorSetupStep) -> Bool {
        let connected = link == .connected
        let answered = voxtAnswers || link != .notConnected
        switch step {
        case .openVoxt: return voxtRunning || answered
        case .permissions: return permissionsConfirmed
        case .turnOnLocalAPI: return answered
        case .allowConnector: return connected
        case .chooseModels: return connected && models?.isReady == true
        case .addPhone: return pairedPhones > 0
        }
    }

    public var done: Set<ConnectorSetupStep> { Set(ConnectorSetupStep.allCases.filter(isDone)) }
    /// An optional step left undone once the user moved on to a later one.
    public func isSkipped(_ step: ConnectorSetupStep) -> Bool {
        step.isOptional && !isDone(step) && ConnectorSetupStep.allCases.contains { $0.rawValue > step.rawValue && isDone($0) }
    }
    /// The first step neither done nor skipped; nil when everything required is done.
    public var current: ConnectorSetupStep? { ConnectorSetupStep.allCases.first { !isDone($0) && !isSkipped($0) } }

    /// The guide opens by itself until it was finished once, and never when a phone is already paired.
    public static func showsAtLaunch(guideFinished: Bool, pairedPhones: Int) -> Bool {
        !guideFinished && pairedPhones == 0
    }
}

/// How the guide reads the parts of the setup that aren't in ConnectorAppModel.
public struct ConnectorSetupProbes {
    public var voxtRunning: @MainActor () -> Bool
    public var voxtAnswers: @MainActor () async -> Bool
    public init(voxtRunning: @escaping @MainActor () -> Bool, voxtAnswers: @escaping @MainActor () async -> Bool) {
        self.voxtRunning = voxtRunning; self.voxtAnswers = voxtAnswers
    }

    /// NSWorkspace for a running Voxt; a connect-and-close on Voxt's socket, which sends nothing,
    /// so Voxt reads end of file and shows no dialog.
    @MainActor public static var live: ConnectorSetupProbes {
        let identifiers = Set(ConnectorIdentity.voxtBundleIdentifiers())
        return ConnectorSetupProbes(
            voxtRunning: {
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(identifiers.contains) ?? false }
            },
            voxtAnswers: { await Task.detached { ConnectorLink.voxtAnswers() }.value })
    }

    /// The installed Voxt to open, the first of VoxtBundleIdentifiers that Launch Services finds.
    @MainActor public static func installedVoxt() -> URL? {
        for identifier in ConnectorIdentity.voxtBundleIdentifiers() {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        return nil
    }
}

/// The guide's state: the facts, the screen shown, and the user's own step choice.
@MainActor @Observable public final class ConnectorSetupGuide {
    public enum Screen: Equatable, Sendable { case step(ConnectorSetupStep), finished }

    public private(set) var facts: ConnectorSetupFacts
    /// A step the user clicked; cleared when the first unfinished step changes.
    private var chosen: ConnectorSetupStep?
    @ObservationIgnored private let preferences: any ConnectorPreferences
    @ObservationIgnored private let onFinished: () -> Void

    public init(preferences: any ConnectorPreferences = UserDefaultsConnectorPreferences(), facts: ConnectorSetupFacts? = nil,
                onFinished: @escaping () -> Void = {}) {
        self.preferences = preferences; self.onFinished = onFinished
        self.facts = facts ?? ConnectorSetupFacts(permissionsConfirmed: preferences.setupPermissionsConfirmed)
    }

    public var screen: Screen {
        if let chosen { return .step(chosen) }
        return facts.current.map(Screen.step) ?? .finished
    }

    public func update(_ next: ConnectorSetupFacts) {
        let before = facts.current
        facts = next
        guard next.current != before else { return }
        chosen = nil
        if next.current == nil {
            preferences.setupGuideFinished = true
            onFinished()
        }
    }

    public func show(_ step: ConnectorSetupStep) { chosen = step }

    public var hasNext: Bool {
        guard case let .step(step) = screen else { return false }
        return step != ConnectorSetupStep.allCases.last
    }

    public func next() {
        guard hasNext, case let .step(step) = screen, let following = ConnectorSetupStep(rawValue: step.rawValue + 1) else { return }
        chosen = following
    }

    public func confirmPermissions() {
        preferences.setupPermissionsConfirmed = true
        var next = facts
        next.permissionsConfirmed = true
        update(next)
    }

    /// Reads every fact once. The models are read only from a connected Voxt.
    public func refresh(model: ConnectorAppModel, probes: ConnectorSetupProbes) async {
        let running = probes.voxtRunning()
        let answers = await probes.voxtAnswers()
        let link: ConnectorSetupFacts.Link = model.isConnected ? .connected : model.isAuthorizing ? .waitingForApproval : .notConnected
        let models = link == .connected ? await model.modelStatus() : nil
        update(ConnectorSetupFacts(voxtRunning: running, permissionsConfirmed: preferences.setupPermissionsConfirmed,
                                   voxtAnswers: answers, link: link, models: models, pairedPhones: model.pairedPhoneCount))
    }
}
