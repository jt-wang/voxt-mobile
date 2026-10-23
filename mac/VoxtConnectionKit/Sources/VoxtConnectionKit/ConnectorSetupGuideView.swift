import AppKit
import SwiftUI

/// What the guide's screens show from the app model, as plain values so each screen can be drawn
/// without a running Voxt.
public struct ConnectorSetupLinkState {
    public var voxtInstalled: Bool
    public var feedback: ConnectorAppModel.ConnectFeedback
    public var isConnecting: Bool
    public var isAuthorizing: Bool
    public var canPair: Bool
    public var isPreparingPairing: Bool
    public var pairingCode: ConnectorPairingCode?
    public var pairingError: String?
    public var iPhoneApp: ConnectorIPhoneApp

    public init(voxtInstalled: Bool, iPhoneApp: ConnectorIPhoneApp = ConnectorIPhoneApp(), feedback: ConnectorAppModel.ConnectFeedback = .idle, isConnecting: Bool = false,
                isAuthorizing: Bool = false, canPair: Bool = false, isPreparingPairing: Bool = false,
                pairingCode: ConnectorPairingCode? = nil, pairingError: String? = nil) {
        self.voxtInstalled = voxtInstalled; self.feedback = feedback; self.isConnecting = isConnecting
        self.isAuthorizing = isAuthorizing; self.canPair = canPair; self.isPreparingPairing = isPreparingPairing
        self.pairingCode = pairingCode; self.pairingError = pairingError; self.iPhoneApp = iPhoneApp
    }

    @MainActor public init(model: ConnectorAppModel, voxtInstalled: Bool) {
        self.init(voxtInstalled: voxtInstalled, feedback: model.connectFeedback, isConnecting: model.isConnecting,
                  isAuthorizing: model.isAuthorizing, canPair: model.canPair, isPreparingPairing: model.isPreparingPairing,
                  pairingCode: model.pairingCode, pairingError: model.pairingError)
    }
}

public struct ConnectorSetupActions {
    public var openVoxt: () -> Void
    public var connect: () -> Void
    public var cancelConnect: () -> Void
    public var addPhone: () -> Void
    public var cancelPairing: () -> Void
    /// Connector's Settings window, with the port and Access token fields.
    public var openSettings: () -> Void
    public var close: () -> Void

    public init(openVoxt: @escaping () -> Void = {}, connect: @escaping () -> Void = {}, cancelConnect: @escaping () -> Void = {},
                addPhone: @escaping () -> Void = {}, cancelPairing: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {}, close: @escaping () -> Void = {}) {
        self.openVoxt = openVoxt; self.connect = connect; self.cancelConnect = cancelConnect
        self.addPhone = addPhone; self.cancelPairing = cancelPairing; self.openSettings = openSettings; self.close = close
    }
}

/// The guide with live detection: reads every fact once a second while the window shows it.
public struct ConnectorSetupGuideLiveView: View {
    let model: ConnectorAppModel
    let guide: ConnectorSetupGuide
    let probes: ConnectorSetupProbes
    let actions: ConnectorSetupActions
    @State private var voxtInstalled = ConnectorSetupProbes.installedVoxt() != nil

    public init(model: ConnectorAppModel, guide: ConnectorSetupGuide, probes: ConnectorSetupProbes, actions: ConnectorSetupActions) {
        self.model = model; self.guide = guide; self.probes = probes; self.actions = actions
    }

    public var body: some View {
        ConnectorSetupGuideView(guide: guide, link: ConnectorSetupLinkState(model: model, voxtInstalled: voxtInstalled),
                                actions: actions)
            .task {
                while !Task.isCancelled {
                    voxtInstalled = ConnectorSetupProbes.installedVoxt() != nil
                    await guide.refresh(model: model, probes: probes)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// The step list on the left and one step on the right.
public struct ConnectorSetupGuideView: View {
    let guide: ConnectorSetupGuide
    let link: ConnectorSetupLinkState
    let actions: ConnectorSetupActions
    /// Snapshots draw one moment of a picture; nil plays it, or shows its last moment with Reduce Motion.
    let picturePhase: Int?

    public init(guide: ConnectorSetupGuide, link: ConnectorSetupLinkState, actions: ConnectorSetupActions, picturePhase: Int? = nil) {
        self.guide = guide; self.link = link; self.actions = actions; self.picturePhase = picturePhase
    }

    public static let size = CGSize(width: 760, height: 560)

    public var body: some View {
        HStack(spacing: 0) {
            SetupStepList(guide: guide)
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            Group {
                switch guide.screen {
                case let .step(step):
                    SetupStepScreen(step: step, guide: guide, link: link, actions: actions, picturePhase: picturePhase)
                        .id(step)
                case .finished:
                    SetupFinishedScreen(close: actions.close)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension ConnectorSetupStep {
    var title: String {
        switch self {
        case .openVoxt: return "Open Voxt Omni Dev"
        case .permissions: return "Mac permissions"
        case .turnOnLocalAPI: return "Turn on Local API"
        case .allowConnector: return "Allow Voxt Connector"
        case .chooseModels: return "Choose models"
        case .addPhone: return "Add your iPhone"
        }
    }

    /// One line under the title: what the step lets happen, and where the data goes.
    var reason: String {
        switch self {
        case .openVoxt:
            return "Voxt Omni Dev turns your speech into text on this Mac; Voxt Connector, this app, links it to your iPhone."
        case .permissions:
            return "Needed only to dictate on the Mac itself; the phone sends its own audio and gets its text back."
        case .turnOnLocalAPI:
            return "Lets Voxt Connector reach Voxt on this Mac only (127.0.0.1); it is off by default and opens nothing to the internet."
        case .allowConnector:
            return "Voxt gives its port and access token only to a Connector signed by the same developer as Voxt."
        case .chooseModels:
            return "Voxt turns your speech into text with these models; local models run on this Mac and download once."
        case .addPhone:
            return "Only phones you add can connect, over an end-to-end encrypted link; each code adds one phone and expires in two minutes."
        }
    }
}

private struct SetupStepList: View {
    let guide: ConnectorSetupGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(ConnectorSetupStep.allCases) { step in
                row(step)
            }
            finishedRow
        }
        .padding(12)
        .padding(.top, 8)
    }

    private func row(_ step: ConnectorSetupStep) -> some View {
        let facts = guide.facts
        let done = facts.isDone(step), current = facts.current == step
        let selected = guide.screen == .step(step)
        return Button { guide.show(step) } label: {
            HStack(spacing: 8) {
                ZStack {
                    if done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if current {
                        Circle().fill(Color.accentColor)
                        Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(.secondary, lineWidth: 1)
                        Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.title)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(done || current ? .primary : .secondary)
                    if step.isOptional {
                        Text(facts.isSkipped(step) ? "Optional · skipped" : "Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.title), \(done ? "done" : current ? "current step" : "not done")")
        .accessibilityIdentifier("setupStep\(step.rawValue + 1)")
    }

    private var finishedRow: some View {
        let finished = guide.facts.current == nil
        return HStack(spacing: 8) {
            Image(systemName: finished ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(finished ? Color.green : Color.secondary)
                .font(.system(size: 15))
                .frame(width: 18, height: 18)
            Text("You're set")
                .fontWeight(finished ? .semibold : .regular)
                .foregroundStyle(finished ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct SetupStepScreen: View {
    let step: ConnectorSetupStep
    let guide: ConnectorSetupGuide
    let link: ConnectorSetupLinkState
    let actions: ConnectorSetupActions
    let picturePhase: Int?

    private var done: Bool { guide.facts.isDone(step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title).font(.title2.weight(.semibold))
                    if step.isOptional {
                        Text("Optional")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(step.reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setupReason")
            }
            content
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                status
                Spacer(minLength: 8)
                if guide.hasNext {
                    Button(step.isOptional && !done ? "Skip" : "Next") { guide.next() }
                        .accessibilityIdentifier("setupNext")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .openVoxt:
            Text("Keep both apps open. Work through the steps here: each one ticks off by itself when Voxt Connector sees it done.")
                .fixedSize(horizontal: false, vertical: true)
            if link.voxtInstalled {
                Button("Open Voxt Omni Dev", action: actions.openVoxt)
                    .buttonStyle(.borderedProminent)
                    .disabled(done)
                    .accessibilityIdentifier("setupOpenVoxt")
            } else {
                Label("Voxt Omni Dev isn't in Applications yet. Open the downloaded disk image and drag Voxt Omni Dev into Applications, then come back here.",
                      systemImage: "arrow.down.app")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .permissions:
            Text("When Voxt Omni Dev asks for Accessibility, click Open System Settings and turn on Voxt Omni Dev: Voxt uses it to type into the Mac app you are using and for its keyboard shortcut. It asks for the Microphone when you first dictate on the Mac. Voxt's sidebar shows Permissions Disabled until both are on.")
                .fixedSize(horizontal: false, vertical: true)
            PermissionsPicture(phase: picturePhase)
            if !done {
                Button("Done") { guide.confirmPermissions() }
                    .accessibilityIdentifier("setupPermissionsDone")
            }
        case .turnOnLocalAPI:
            Text("In Voxt Omni Dev, click Settings in the sidebar, then General. Scroll down to Local API and turn on “Allow other apps to dictate through Voxt”.")
                .fixedSize(horizontal: false, vertical: true)
            LocalAPIPicture(phase: picturePhase)
        case .allowConnector:
            Text("Click Connect. Voxt asks “Allow Voxt Connector to use Voxt?”: click Always Allow, so the Connector connects by itself next time.")
                .fixedSize(horizontal: false, vertical: true)
            AllowPicture(phase: picturePhase)
            HStack(spacing: 10) {
                Button("Connect", action: actions.connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(link.isConnecting || done)
                    .accessibilityIdentifier("setupConnect")
                ConnectFeedbackView(feedback: link.feedback)
                if link.isAuthorizing { Button("Cancel", action: actions.cancelConnect) }
            }
            HStack(spacing: 6) {
                Text("To enter the port and Access token by hand:").foregroundStyle(.secondary)
                Button("Open Connector Settings", action: actions.openSettings)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("setupOpenSettings")
            }
            .font(.callout)
        case .chooseModels:
            Text("In Voxt Omni Dev, click Feature, then Transcription. Choose a Speech Model, turn on Text Enhancement and choose an Enhancement Model. If the sidebar shows Model Setup Required, click it and download the models there.")
                .fixedSize(horizontal: false, vertical: true)
            ModelsPicture(phase: picturePhase)
            ModelReadinessView(link: guide.facts.link, models: guide.facts.models)
        case .addPhone:
            VStack(alignment: .leading, spacing: 6) {
                installLine
                Text("2. Open Voxt on the iPhone and add the Voxt keyboard.")
                Text("3. Click Add iPhone, then scan the code with the iPhone Camera.")
            }
            .fixedSize(horizontal: false, vertical: true)
            if let code = link.pairingCode {
                HStack(alignment: .top, spacing: 16) {
                    PairingQRCode(code: code, side: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("An iPhone on the same Wi-Fi can also connect from Voxt; Voxt Connector then asks you to allow it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Cancel pairing", action: actions.cancelPairing)
                    }
                }
            } else if !done {
                HStack(spacing: 10) {
                    Button(link.isPreparingPairing ? "Preparing…" : "Add iPhone", action: actions.addPhone)
                        .buttonStyle(.borderedProminent)
                        .disabled(!link.canPair)
                        .accessibilityIdentifier("setupAddPhone")
                    if !link.canPair, !link.isPreparingPairing {
                        Text("Connect first (step 4).").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = link.pairingError { Text(error).foregroundStyle(.red) }
        }
    }

    /// The build's own iPhone app link (a TestFlight beta, say), or the setup steps when it names none.
    private var installLine: Text {
        let app = link.iPhoneApp
        if app.isSetupSteps {
            var steps = AttributedString("Set it up"); steps.link = app.url
            return Text("1. Install the Voxt iPhone app (see ") + Text(steps) + Text(").")
        }
        var address = AttributedString(app.shownAddress); address.link = app.url
        if app.url.host == "testflight.apple.com" {
            return Text("1. On your iPhone, join the beta at ") + Text(address) + Text(" and install Voxt.")
        }
        return Text("1. On your iPhone, install Voxt from ") + Text(address) + Text(".")
    }

    @ViewBuilder private var status: some View {
        if done {
            Label(doneText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("setupStepStatus")
        } else if let waiting = waitingText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(waiting).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setupStepStatus")
        }
    }

    private var doneText: String {
        switch step {
        case .openVoxt: return "Voxt Omni Dev is running."
        case .permissions: return "Marked as done."
        case .turnOnLocalAPI: return "The Local API is on."
        case .allowConnector: return "Voxt allowed this Connector."
        case .chooseModels: return "Both models are ready."
        case .addPhone: return guide.facts.pairedPhones == 1 ? "1 iPhone is added." : "\(guide.facts.pairedPhones) iPhones are added."
        }
    }

    private var waitingText: String? {
        switch step {
        case .openVoxt: return "Waiting for Voxt Omni Dev to open…"
        case .permissions: return nil
        case .turnOnLocalAPI: return "Waiting for the Local API…"
        case .allowConnector: return nil
        case .chooseModels: return guide.facts.link == .connected ? "Waiting for both models…" : nil
        case .addPhone: return link.pairingCode == nil ? nil : "Waiting for your iPhone…"
        }
    }
}

private struct ModelReadinessView: View {
    let link: ConnectorSetupFacts.Link
    let models: ConnectorModelStatus?

    var body: some View {
        if link != .connected {
            Text("Voxt Connector reads the models from Voxt once it is connected (step 4).")
                .foregroundStyle(.secondary)
        } else if let models {
            VStack(alignment: .leading, spacing: 4) {
                row("Speech model", models.transcription, unsupported: "Direct Dictation can't take audio from the phone. Choose another Speech Model.")
                row("Text model", models.text, unsupported: "This text model can't be used here. Choose another Enhancement Model.")
            }
        } else {
            Text("This Voxt doesn't report its models. Check them in Voxt, then click Next.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ readiness: ConnectorModelReadiness, unsupported: String) -> some View {
        let (symbol, color, text): (String, Color, String) = switch readiness {
        case .ready: ("checkmark.circle.fill", .green, "ready")
        case .missing: ("arrow.down.circle", .orange, "not downloaded or not set up yet")
        case .off: ("circle.slash", .orange, "Text Enhancement is off")
        case .unsupported: ("exclamationmark.triangle.fill", .orange, unsupported)
        }
        return Label {
            Text(name).fontWeight(.medium) + Text(": " + text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SetupFinishedScreen: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're set").font(.title2.weight(.semibold))
            Text("Voxt Omni Dev, Voxt Connector and your iPhone are connected. Keep both Mac apps open while you dictate from the phone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Try it: tap the mic on the Voxt keyboard in any app.", systemImage: "mic.fill")
                .font(.title3)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setupDone")
            }
        }
    }
}
