import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxtConnectionKit

/// Draws the guide's pictures alone, every moment of each animation, light and dark, at a fixed pixel scale, for the
/// DMG's Start Here page. With CONNECTOR_GUIDE_PICTURES set to a folder, the frames are written there as
/// <name>-<light|dark>-<moment>.png; tools/build-start-here.py joins them into looping animations.
@MainActor @Suite struct ConnectorSetupPictureSnapshotTests {
    /// Every picture sits centered on a stage of this size, so the page shows them at one width.
    static let stage = CGSize(width: 520, height: 240)
    static let scale: CGFloat = 2

    private struct Picture {
        let name: String
        let moments: Int
        let draw: (Int) -> AnyView
    }

    private static var pictures: [Picture] {
        // A fixed code, so the pictures come out the same on every run.
        let code = try! ConnectorPairingCode(url: URL(string: "voxtmobile://connect?v=1&tailcat=tc-picture&port=48932&key=privkey:"
            + String(repeating: "0", count: 64) + "&proof=picture-proof&expires=100")!, now: Date(timeIntervalSince1970: 0))
        return [
            Picture(name: "2-accessibility", moments: 3) { AnyView(PermissionsPicture(phase: $0)) },
            Picture(name: "3-local-api", moments: 4) { AnyView(LocalAPIPicture(phase: $0)) },
            Picture(name: "4-allow", moments: 1) { AnyView(AllowPicture(phase: $0)) },
            Picture(name: "5-models", moments: 6) { AnyView(ModelsPicture(phase: $0)) },
            // The still for Reduce Motion: both model controls ringed at once.
            Picture(name: "5-models-still", moments: 1) { _ in AnyView(ModelsPicture(phase: nil, ringsModels: true)) },
            Picture(name: "6-add-iphone", moments: 2) { AnyView(AddPhonePicture(code: code, phase: $0)) },
        ]
    }

    @Test func everyMomentOfEveryPictureDrawsInLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["CONNECTOR_GUIDE_PICTURES"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for picture in Self.pictures {
            for dark in [false, true] {
                var frames: [Data] = []
                for moment in 0..<picture.moments {
                    let name = "\(picture.name)-\(dark ? "dark" : "light")-\(moment)"
                    let bitmap = try #require(Self.render(picture.draw(moment), dark: dark), "\(name)")
                    #expect(bitmap.pixelsWide == Int(Self.stage.width * Self.scale), "\(name) is drawn at \(Self.scale)x")
                    #expect(bitmap.pixelsHigh == Int(Self.stage.height * Self.scale))
                    // The stage around the picture stays clear, so the page's own background shows there.
                    #expect(bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 1 < 0.01, "\(name) has a clear stage")
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 10_000, "\(name) drew something")
                    frames.append(png)
                    if let folder { try png.write(to: folder.appending(path: "\(name).png")) }
                }
                #expect(Set(frames).count == frames.count, "\(picture.name): each moment looks different")
            }
        }
    }

    @Test func modelsPictureRingsBothModelControlsAtOnce() throws {
        let both = try #require(Self.render(AnyView(ModelsPicture(phase: nil, ringsModels: true)), dark: false))
        let speechOnly = try #require(Self.render(AnyView(ModelsPicture(phase: 2)), dark: false))
        #expect(Self.accentPixels(both) > Self.accentPixels(speechOnly) * 3 / 2, "two rings and the switch draw more accent than one ring")
    }

    /// Pixels close to the accent color, the color of the rings and of a switch that is on.
    private static func accentPixels(_ bitmap: NSBitmapImageRep) -> Int {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                if abs(color.redComponent - accent.redComponent) < 0.08, abs(color.greenComponent - accent.greenComponent) < 0.08,
                   abs(color.blueComponent - accent.blueComponent) < 0.08 { count += 1 }
            }
        }
        return count
    }

    /// NSHostingView draws AppKit-backed controls; the bitmap's pixel size fixes the scale whatever the screen's.
    private static func render(_ view: AnyView, dark: Bool) -> NSBitmapImageRep? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let staged = view
            .frame(width: stage.width, height: stage.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: staged)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: stage)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(stage.width * scale),
                                            pixelsHigh: Int(stage.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = stage
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return bitmap
    }
}
