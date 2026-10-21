import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: FocusablePanel?
    private static let anchor = TopAnchor()

    static func show() {
        if window == nil {
            let window = FocusablePanel()
            window.title = "Clementine Settings" // hidden, but used by Mission Control and VoiceOver
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .preferredContentSize
            window.contentViewController = host
            window.center()
            window.delegate = anchor
            self.window = window
        }
        window?.present()
    }
}

/// Keeps the window's top edge still when switching tabs changes its height, as macOS settings windows do.
private final class TopAnchor: NSObject, NSWindowDelegate {
    private var top: CGFloat?

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let top, window.isVisible, abs(window.frame.maxY - top) > 0.5 {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        }
        top = window.frame.maxY
    }

    func windowDidMove(_ notification: Notification) {
        top = (notification.object as? NSWindow)?.frame.maxY
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case wheel = "Wheel"

    var id: Self { self }
    var symbol: String { self == .general ? "gearshape" : "chart.pie" }
}

struct SettingsView: View {
    @State private var tab: SettingsTab
    @AppStorage(Prefs.enabledKey) private var enabled = true
    @AppStorage(Prefs.revealKey) private var reveal = true
    @AppStorage(Prefs.qualityKey) private var quality = 0.85
    @AppStorage(Prefs.toolsDirectoryKey) private var toolsDirectory = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    init(tab: SettingsTab = .general) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()
                .padding(.horizontal, 22)
                .padding(.top, 6)
            SettingsTabs(selection: $tab)
                .padding(.top, 14)
            switch tab {
            case .general: form
            case .wheel: WheelSettingsView()
            }
        }
        .frame(width: 520)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
    }

    private var form: some View {
        Form {
            Section("How to use") {
                ShortcutRow(keys: ["⇧"], action: "Convert", detail: "Change a file's format")
                ShortcutRow(keys: ["⌥", "⇧"], action: "Tools", detail: "Compress, trim, resize and more")
            }

            Section {
                Toggle("Show the wheel while dragging", isOn: $enabled)
                Toggle("Reveal finished files in Finder", isOn: $reveal)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        // Also fires when we snap the toggle back to the real status below.
                        guard on != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            loginError = SMAppService.mainApp.status == .requiresApproval
                                ? "Approve Clementine in System Settings › General › Login Items." : nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        let actual = SMAppService.mainApp.status == .enabled
                        if launchAtLogin != actual { launchAtLogin = actual }
                    }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cherry)
                }
            }

            Section("Images") {
                LabeledContent("JPEG / HEIC quality") {
                    HStack {
                        Slider(value: $quality, in: 0.5...1)
                        Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                TextField("Extra tools folder", text: $toolsDirectory, prompt: Text("/opt/homebrew/bin"))
                ToolStatus(name: "ffmpeg", purpose: "video & audio", directory: toolsDirectory)
                ToolStatus(name: "ffprobe", purpose: "media info", directory: toolsDirectory)
                ToolStatus(name: "cwebp", purpose: "WebP output", directory: toolsDirectory)
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Install missing tools with `brew install ffmpeg webp`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Two pill tabs under the header; the selected one slides between them.
private struct SettingsTabs: View {
    @Binding var selection: SettingsTab
    @Namespace private var lens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { withAnimation(Theme.spring) { selection = tab } } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.secondaryText(scheme))
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accent)
                                    .shadow(color: Theme.glow, radius: 5, y: 2)
                                    .matchedGeometryEffect(id: "tab", in: lens)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05)))
        .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1))
    }
}

/// App glyph, name and tagline at the top of Settings.
private struct AppHeader: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            GradientBadge(symbol: "camera.aperture", size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Clementine")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Drag a file, pick a format. Nothing leaves your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// "Hold these keys while dragging" with the keys drawn as keycaps.
private struct ShortcutRow: View {
    let keys: [String]
    let action: String
    let detail: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text("Hold").foregroundStyle(.secondary)
                HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(key: $0) } }
                Text("while dragging").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        } label: {
            Text(action)
            Text(detail)
        }
    }
}

private struct ToolStatus: View {
    let name: String
    let purpose: String
    /// Only here so the row refreshes when the folder changes.
    let directory: String

    var body: some View {
        let path = ToolLocator.find(name)?.path
        LabeledContent {
            HStack(spacing: 6) {
                Text(path ?? "Not found")
                    .foregroundStyle(path == nil ? Theme.cherry : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(path == nil ? Theme.cherry : Theme.leaf)
            }
        } label: {
            Text(name)
            Text(purpose)
        }
    }
}
