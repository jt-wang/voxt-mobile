import SwiftUI

// Small pictures of the screens the guide sends the user to. Labels are copied from Voxt's
// Settings (its English strings) and from the macOS dialogs; each picture shows only the
// controls the step needs. A ring moves to the control to click, like the iPhone onboarding.

/// Plays a picture's moments in a loop; with Reduce Motion, or a fixed phase, shows one moment.
private struct LoopingPicture<Content: View>: View {
    let phases: Int
    let fixed: Int?
    let summary: String
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content(fixed.map { min(max($0, 0), phases - 1) } ?? (reduceMotion ? phases - 1 : phase))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
            if phases > 1, fixed == nil, !reduceMotion {
                Text("The picture plays these clicks in a loop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard phases > 1, fixed == nil, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % phases }
            }
        }
    }
}

private extension View {
    /// The highlight ring around the control to click.
    func ring(_ shown: Bool, cornerRadius: CGFloat = 6) -> some View {
        overlay {
            if shown {
                RoundedRectangle(cornerRadius: cornerRadius + 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-4)
                    .transition(.opacity)
            }
        }
    }
}

private struct MockSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).padding(2).shadow(radius: 0.5)
            }
    }
}

/// A window frame with the three title bar buttons drawn grey.
private struct MockWindow<Content: View>: View {
    var width: CGFloat = 460
    var height: CGFloat = 200
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8) }
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    var active = false
    var ring = false
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 13)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .ring(ring)
    }
}

/// Voxt's window: its sidebar on the left, one page on the right.
private struct VoxtWindow<Sidebar: View, Page: View>: View {
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let page: Page

    var body: some View {
        MockWindow {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) { sidebar }
                    .padding(8)
                    .frame(width: 170)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.secondary.opacity(0.07))
                VStack(alignment: .leading, spacing: 8) { page }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Voxt's root sidebar items, in Voxt's order.
private struct VoxtRootSidebar: View {
    var ringOn: String?
    var showsBadges = false
    var body: some View {
        SidebarItem(icon: "house", title: "Home", active: ringOn == nil)
        SidebarItem(icon: "square.grid.2x2", title: "Feature", ring: ringOn == "Feature")
        SidebarItem(icon: "book.closed", title: "Dictionary")
        SidebarItem(icon: "clock.arrow.circlepath", title: "History")
        SidebarItem(icon: "gearshape", title: "Settings", ring: ringOn == "Settings")
        if showsBadges {
            Spacer(minLength: 4)
            SidebarItem(icon: "exclamationmark.triangle.fill", title: "Permissions Disabled", tint: .red)
            SidebarItem(icon: "exclamationmark.circle.fill", title: "Model Setup Required",
                        ring: ringOn == "Model Setup Required", tint: .orange)
        }
    }
}

/// Grey lines standing for a page the step doesn't need.
private struct PlaceholderPage: View {
    var body: some View {
        ForEach([0.7, 0.9, 0.5], id: \.self) { fraction in
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                .frame(width: 240 * fraction, height: 9)
        }
    }
}

struct LocalAPIPicture: View {
    let phase: Int?
    var body: some View {
        LoopingPicture(phases: 4, fixed: phase,
                       summary: "In Voxt, click Settings, then General, then turn on Allow other apps to dictate through Voxt.") { phase in
            VoxtWindow {
                if phase == 0 {
                    VoxtRootSidebar(ringOn: "Settings", showsBadges: true)
                } else {
                    SidebarItem(icon: "slider.horizontal.3", title: "General", active: phase >= 1, ring: phase == 1)
                    SidebarItem(icon: "waveform", title: "Model")
                    SidebarItem(icon: "lock.shield", title: "Permissions")
                    SidebarItem(icon: "keyboard", title: "Hotkey")
                    SidebarItem(icon: "info.circle", title: "About")
                }
            } page: {
                if phase < 2 {
                    PlaceholderPage()
                } else {
                    Text("Local API").font(.system(size: 12, weight: .semibold))
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow other apps to dictate through Voxt").font(.system(size: 11, weight: .medium))
                            Text("Scripts, shortcuts and tools on this Mac send audio over HTTP. Voxt transcribes it with your current model, enhancement and dictionary, and returns the text.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        MockSwitch(isOn: phase >= 3).ring(true, cornerRadius: 8)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct ModelsPicture: View {
    let phase: Int?
    var body: some View {
        LoopingPicture(phases: 6, fixed: phase,
                       summary: "In Voxt, click Feature, then Transcription. Choose a Speech Model, turn on Text Enhancement and choose an Enhancement Model. Then click Model Setup Required to download them.") { phase in
            VoxtWindow {
                if phase == 0 || phase == 5 {
                    VoxtRootSidebar(ringOn: phase == 0 ? "Feature" : "Model Setup Required", showsBadges: true)
                } else {
                    SidebarItem(icon: "switch.2", title: "Feature")
                    SidebarItem(icon: "waveform.and.mic", title: "Transcription", active: true, ring: phase == 1)
                }
            } page: {
                if phase == 0 {
                    PlaceholderPage()
                } else {
                    Text("Transcription").font(.system(size: 12, weight: .semibold))
                    Text("Choose a speech model, then add text enhancement if needed.")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        selector("Speech Model", chosen: phase >= 3, ring: phase == 2)
                        Divider()
                        HStack {
                            Text("Text Enhancement").font(.system(size: 11, weight: .medium))
                            Spacer()
                            MockSwitch(isOn: phase >= 3).ring(phase == 3, cornerRadius: 8)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        if phase >= 3 {
                            Divider()
                            selector("Enhancement Model", chosen: phase >= 5, ring: phase == 4)
                        }
                    }
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func selector(_ title: String, chosen: Bool, ring: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            // The value is the model the user picks; drawn as a grey bar once chosen.
            Text(chosen ? "Model name" : "Not selected")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .redacted(reason: chosen ? .placeholder : [])
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .ring(ring)
    }
}

/// A macOS alert as Voxt and macOS draw it: icon, title, message, buttons stacked.
private struct MockAlert: View {
    let icon: String
    let title: String
    let message: String
    let buttons: [String]
    let ringOn: Int?

    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary))
            Text(title).font(.system(size: 11, weight: .bold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 9.5)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 5) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, title in
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(index == 0 ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity).frame(height: 20)
                        .background(index == 0 ? Color.accentColor : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        .ring(ringOn == index)
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 175)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

struct AllowPicture: View {
    let phase: Int?
    var body: some View {
        LoopingPicture(phases: 1, fixed: phase, summary: "In Voxt's dialog, click Always Allow.") { _ in
            MockAlert(icon: "waveform", title: "Allow Voxt Connector to use Voxt?",
                      message: "It will forward dictations from your paired iPhone to Voxt on this Mac.",
                      buttons: ["Always Allow", "Allow Once", "Don't Allow"], ringOn: 0)
                .padding(.vertical, 4)
        }
    }
}

struct PermissionsPicture: View {
    let phase: Int?
    var body: some View {
        LoopingPicture(phases: 3, fixed: phase,
                       summary: "Click Open System Settings, then in Privacy & Security › Accessibility turn on Voxt Omni Dev.") { phase in
            HStack(alignment: .top, spacing: 14) {
                MockAlert(icon: "accessibility", title: "Accessibility Access",
                          message: "“Voxt Omni Dev” would like to control this computer using accessibility features.",
                          buttons: ["Open System Settings", "Deny"], ringOn: phase == 0 ? 0 : nil)
                    .opacity(phase == 0 ? 1 : 0.45)
                MockWindow(width: 300, height: 170) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            SidebarItem(icon: "hand.raised.fill", title: "Privacy & Security", active: true)
                        }
                        .padding(6)
                        .frame(width: 142)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.secondary.opacity(0.07))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accessibility").font(.system(size: 11, weight: .semibold))
                                .padding(.top, 4)
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.25)).frame(width: 15, height: 15)
                                Text("Voxt Omni Dev").font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                                Spacer(minLength: 2)
                                MockSwitch(isOn: phase >= 2).ring(phase >= 1, cornerRadius: 8)
                            }
                            .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 8)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .opacity(phase == 0 ? 0.45 : 1)
            }
        }
    }
}
