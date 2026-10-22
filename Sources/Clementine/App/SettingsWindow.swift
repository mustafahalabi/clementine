import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: FocusablePanel?
    private static let anchor = TopAnchor()
    private static let fit = SettingsFit()

    static func show() {
        // Cap the content to the screen first, so the window is sized by it before center() places it.
        fit.limit(to: window?.screen ?? NSScreen.main)
        if window == nil {
            let window = FocusablePanel()
            window.title = "Clementine Settings" // hidden, but used by Mission Control and VoiceOver
            window.host(SettingsView(fit: fit))
            window.center()
            window.delegate = anchor
            self.window = window
        }
        if let window { TopAnchor.keepOnScreen(window) }
        window?.present()
    }
}

/// The tallest the Settings content may be: its screen's visible height, less the title bar. Taller tabs
/// scroll instead of running off the bottom of a short (1080p) screen.
@MainActor
final class SettingsFit: ObservableObject {
    @Published var maxHeight: CGFloat?

    init(maxHeight: CGFloat? = nil) {
        self.maxHeight = maxHeight
    }

    func limit(to screen: NSScreen?) {
        guard let screen else { return }
        let chrome = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .fullSizeContentView]).height
        let height = (screen.visibleFrame.height - max(chrome, 28)).rounded(.down)
        if maxHeight != height { maxHeight = height }
    }
}

/// Keeps the window's top edge still when switching tabs changes its height, as macOS settings windows do,
/// without letting the bottom go below the Dock.
private final class TopAnchor: NSObject, NSWindowDelegate {
    private var top: CGFloat?

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let top, window.isVisible, abs(window.frame.maxY - top) > 0.5 {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        }
        MainActor.assumeIsolated { Self.keepOnScreen(window) }
        top = window.frame.maxY
    }

    /// Slides the window up (or down) so all of it is inside its screen's visible frame.
    @MainActor
    static func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = window.frame.origin
        if window.frame.minY < visible.minY { origin.y = visible.minY }
        if origin.y + window.frame.height > visible.maxY { origin.y = max(visible.minY, visible.maxY - window.frame.height) }
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    func windowDidMove(_ notification: Notification) {
        top = (notification.object as? NSWindow)?.frame.maxY
    }
}

/// "Launch at login", shared by Settings and the welcome tour. On by default for new installs; once the user
/// flips either switch, their choice is remembered and never overridden.
@MainActor
enum LaunchAtLogin {
    /// Set once the default has been applied or the user has chosen, so the default never runs twice.
    static let decidedKey = "launchAtLoginDecided"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on for a fresh install. Existing installs (they've seen the welcome tour) keep what they had, and
    /// copies run from outside an Applications folder (a build folder, a translocated download) aren't registered.
    static func applyDefaultIfNeeded(isFreshInstall: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: decidedKey) else { return }
        guard isFreshInstall else { return defaults.set(true, forKey: decidedKey) }
        guard isInApplicationsFolder else { return } // try again once the app has been moved
        defaults.set(true, forKey: decidedKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register() // quietly: the Settings switch shows the real status
    }

    /// Applies the user's choice; returns a message to show if it didn't fully take.
    static func set(_ on: Bool) -> String? {
        UserDefaults.standard.set(true, forKey: decidedKey)
        guard on != isOn else { return nil }
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            return SMAppService.mainApp.status == .requiresApproval
                ? "Approve Clementine in System Settings › General › Login Items." : nil
        } catch {
            return error.localizedDescription
        }
    }

    private static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications") || path.hasPrefix(home)
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
    @ObservedObject private var fit: SettingsFit
    @AppStorage(Prefs.enabledKey) private var enabled = true
    @AppStorage(Prefs.revealKey) private var reveal = true
    @AppStorage(Prefs.controlWheelKey) private var controlWheel = true
    @AppStorage(Prefs.qualityKey) private var quality = 0.85
    @AppStorage(Prefs.toolsDirectoryKey) private var toolsDirectory = ""
    @AppStorage(Prefs.hardwareEncodingKey) private var hardwareEncoding = true
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var loginError: String?

    init(tab: SettingsTab = .general, fit: SettingsFit? = nil) {
        _tab = State(initialValue: tab)
        self.fit = fit ?? SettingsFit()
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()
                .padding(.horizontal, 22)
                .padding(.top, 6)
            SettingsTabs(selection: $tab)
                .padding(.top, 14)
            // Natural height when the tab fits under `fit.maxHeight`; otherwise the form fills what's left and
            // scrolls itself. (Not a ScrollView around it: the form's own scroll view would swallow the wheel.)
            ViewThatFits(in: .vertical) {
                tabContent
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                tabContent
            }
        }
        .frame(width: 520)
        .frame(maxHeight: fit.maxHeight)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .general: form
        case .wheel: WheelSettingsView()
        }
    }

    private var form: some View {
        Form {
            Section("How to use") {
                ShortcutRow(keys: ["⇧"], action: "Convert", detail: "Change a file's format")
                ShortcutRow(keys: ["⌥", "⇧"], action: "Tools", detail: "Compress, trim, resize and more")
                ShortcutRow(keys: ["⌃"], action: "File actions", detail: "Copy path, SHA-256, Terminal, AirDrop")
            }

            Section {
                Toggle("Show the wheel while dragging", isOn: $enabled)
                Toggle(isOn: $controlWheel) {
                    Text("⌃ opens the file actions wheel")
                    Text("Start the drag first: ⌃-click opens Finder's menu instead")
                }
                .disabled(!enabled)
                .uiTestID("settings.controlWheel")
                Toggle("Reveal finished files in Finder", isOn: $reveal)
                Toggle(isOn: $hardwareEncoding) {
                    Text("Use hardware encoding for video")
                    Text("Much faster, slightly larger files. Compress always uses software.")
                }
                .uiTestID("settings.hardwareEncoding")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        // Also fires when we snap the toggle back to the real status below.
                        loginError = LaunchAtLogin.set(on)
                        if launchAtLogin != LaunchAtLogin.isOn { launchAtLogin = LaunchAtLogin.isOn }
                    }
                    .uiTestID("settings.launchAtLogin")
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cherryText)
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
                TextField("Custom tools folder", text: $toolsDirectory, prompt: Text("/opt/homebrew/bin"))
                ToolStatus(name: "ffmpeg", purpose: "video & audio", directory: toolsDirectory)
                ToolStatus(name: "ffprobe", purpose: "media info", directory: toolsDirectory)
                ToolStatus(name: "cwebp", purpose: "WebP output", directory: toolsDirectory)
                ToolStatus(name: "img2webp", purpose: "animated WebP", directory: toolsDirectory)
            } header: {
                Text("Command-line tools")
            } footer: {
                Text(ClementineError.bundlesTools
                     ? "Clementine includes these tools. A folder set above is used first, for your own builds."
                     : "Install missing tools with `brew install ffmpeg webp`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .uiTestID("settings.toolsFooter")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
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
                    .foregroundStyle(path == nil ? Theme.cherryText : .secondary)
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
