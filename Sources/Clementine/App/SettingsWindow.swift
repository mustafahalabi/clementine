import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: FocusablePanel?

    static func show() {
        if window == nil {
            let window = FocusablePanel()
            window.title = "Clementine Settings" // hidden, but used by Mission Control and VoiceOver
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .preferredContentSize
            window.contentViewController = host
            window.center()
            self.window = window
        }
        window?.present()
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.enabledKey) private var enabled = true
    @AppStorage(Prefs.revealKey) private var reveal = true
    @AppStorage(Prefs.qualityKey) private var quality = 0.85
    @AppStorage(Prefs.toolsDirectoryKey) private var toolsDirectory = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()
                .padding(.horizontal, 22)
                .padding(.top, 6)
            form
        }
        .frame(width: 480)
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
