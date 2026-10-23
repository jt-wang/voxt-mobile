import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxtConnectionKit

/// Draws every screen of the setup guide offscreen, light and dark, without launching the app.
/// With CONNECTOR_GUIDE_SNAPSHOTS set to a folder, the images are written there to look at.
@MainActor @Suite struct ConnectorSetupGuideSnapshotTests {
    private struct Shot {
        let name: String
        let facts: ConnectorSetupFacts
        var shown: ConnectorSetupStep?
        var link = ConnectorSetupLinkState(voxtInstalled: true)
        var phase: Int?
    }

    private static let ready = ConnectorModelStatus(transcription: .ready, text: .ready)

    private static var shots: [Shot] {
        let opened = ConnectorSetupFacts(voxtRunning: true)
        let answering = ConnectorSetupFacts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true)
        let modelsReady = ConnectorSetupFacts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true,
                                              link: .connected, models: ready)
        let paired = ConnectorSetupFacts(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true,
                                         link: .connected, models: ready, pairedPhones: 1)
        let code = try? ConnectorPairingCode(url: URL(string: "voxtmobile://connect?v=1&tailcat=tc-snapshot&port=48932&key=privkey:"
            + String(repeating: "0", count: 64) + "&proof=snapshot-proof&expires=\(Int(Date().timeIntervalSince1970) + 100)")!)
        return [
            Shot(name: "1-open-voxt", facts: .init()),
            Shot(name: "1-open-voxt-not-installed", facts: .init(), link: .init(voxtInstalled: false)),
            Shot(name: "2-permissions-dialog", facts: opened, phase: 0),
            Shot(name: "2-permissions", facts: opened),
            Shot(name: "3-local-api-sidebar", facts: .init(voxtRunning: true, permissionsConfirmed: true), phase: 0),
            Shot(name: "3-local-api", facts: .init(voxtRunning: true, permissionsConfirmed: true)),
            Shot(name: "4-allow", facts: answering),
            Shot(name: "4-allow-waiting", facts: .init(voxtRunning: true, permissionsConfirmed: true, voxtAnswers: true,
                                                      link: .waitingForApproval),
                 link: .init(voxtInstalled: true, feedback: .waitingForApproval, isConnecting: true, isAuthorizing: true)),
            Shot(name: "5-models-feature", facts: .init(voxtRunning: true, voxtAnswers: true, link: .connected,
                                                       models: .init(transcription: .missing, text: .off)),
                 link: .init(voxtInstalled: true, feedback: .connected("Connected to Voxt 1.16.0"), canPair: true), phase: 2),
            Shot(name: "5-models", facts: .init(voxtRunning: true, voxtAnswers: true, link: .connected,
                                                models: .init(transcription: .missing, text: .off)),
                 link: .init(voxtInstalled: true, feedback: .connected("Connected to Voxt 1.16.0"), canPair: true)),
            Shot(name: "5-models-before-connect", facts: answering, shown: .chooseModels),
            Shot(name: "6-add-phone", facts: modelsReady,
                 link: .init(voxtInstalled: true, iPhoneApp: .init(info: nil), feedback: .connected("Connected to Voxt 1.16.0"),
                             canPair: true)),
            Shot(name: "6-add-phone-build-link", facts: modelsReady,
                 link: .init(voxtInstalled: true, iPhoneApp: .init(info: [ConnectorIPhoneApp.infoKey: "beta.example.com/voxt"]),
                             feedback: .connected("Connected to Voxt 1.16.0"), canPair: true)),
            Shot(name: "6-add-phone-qr", facts: modelsReady,
                 link: .init(voxtInstalled: true, iPhoneApp: .init(info: nil), feedback: .connected("Connected to Voxt 1.16.0"),
                             canPair: true, pairingCode: code)),
            Shot(name: "7-finished", facts: paired),
            Shot(name: "out-of-order-phone-paired-voxt-quit", facts: .init(pairedPhones: 1)),
        ]
    }

    @Test func everyScreenDrawsInLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["CONNECTOR_GUIDE_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for shot in Self.shots {
            for dark in [false, true] {
                let guide = ConnectorSetupGuide(preferences: TestPreferences(), facts: shot.facts)
                if let shown = shot.shown { guide.show(shown) }
                let view = ConnectorSetupGuideView(guide: guide, link: shot.link, actions: .init(), picturePhase: shot.phase ?? 99)
                let png = try #require(Self.render(view, dark: dark), "\(shot.name)")
                #expect(png.count > 10_000, "\(shot.name) drew something")
                if let folder {
                    try png.write(to: folder.appending(path: "\(shot.name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// NSHostingView draws AppKit-backed controls (buttons, switches), which ImageRenderer leaves out.
    private static func render(_ view: some View, dark: Bool) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: ConnectorSetupGuideView.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var result: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            result = bitmap.representation(using: .png, properties: [:])
        }
        return result
    }
}
