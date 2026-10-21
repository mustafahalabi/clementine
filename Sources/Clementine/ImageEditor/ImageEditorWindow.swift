import AppKit
import SwiftUI

/// Opens the Crop, Redact and Annotate editors in a resizable panel sized to the picture.
@MainActor
enum ImageEditorWindow {
    private static var windows: [NSWindow] = []

    /// Loads `url` and shows the editor `content` builds; `finish(values)` closes the window and runs the job,
    /// `finish(nil)` just closes it.
    static func present<Content: View>(_ url: URL, title: String, apply: @escaping (ParamValues) -> Void,
                                       content: (EditorImage, @escaping (ParamValues?) -> Void) -> Content) {
        let image: EditorImage
        do {
            image = try EditorImage.load(url)
        } catch {
            ResultWindow.show(title: title, body: error.localizedDescription)
            return
        }
        let window = FocusablePanel(resizable: true)
        window.title = "\(title) – \(url.lastPathComponent)"
        window.isMovableByWindowBackground = false // drags on the canvas edit, they don't move the window
        let finish: (ParamValues?) -> Void = { [weak window] values in
            window?.close()
            if let values { apply(values) }
        }
        let host = NSHostingController(rootView: content(image, finish))
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = NSSize(width: 820, height: 540)
        window.setContentSize(initialSize(for: image.pixelSize))
        window.center()
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === window } }
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
        window.present()
    }

    /// Room for the picture at a comfortable size, within the screen.
    static func initialSize(for image: CGSize) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let chrome = NSSize(width: 40, height: 210)
        let maxCanvas = NSSize(width: min(screen.width * 0.8, 1180) - chrome.width, height: min(screen.height * 0.85, 860) - chrome.height)
        let scale = min(maxCanvas.width / max(image.width, 1), maxCanvas.height / max(image.height, 1), 1.6)
        return NSSize(width: max(image.width * scale + chrome.width, 860), height: max(image.height * scale + chrome.height, 580))
    }
}

/// The frame every image editor shares: header, a toolbar row, the canvas, and a footer with a status line and
/// Cancel / Apply. Return applies, Esc cancels, Delete removes the selection; `capturesKeys` turns these off while
/// the user types into a text annotation.
struct EditorShell<Toolbar: View, Canvas: View, Status: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    var applyTitle = "Apply"
    var canApply = true
    var capturesKeys = true
    let onApply: () -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)? = nil
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let canvas: Canvas
    @ViewBuilder let status: Status

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: symbol, title: title, subtitle: subtitle)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            HStack(spacing: 10) { toolbar }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            HStack(spacing: 10) {
                status
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(capturesKeys ? .cancelAction : nil)
                    .buttonStyle(SoftButtonStyle())
                Button(applyTitle, action: onApply)
                    .keyboardShortcut(capturesKeys ? .defaultAction : nil)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canApply)
            }
            .padding(20)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(WindowBackdrop())
        .background {
            // Delete and forward-delete remove the selection.
            if capturesKeys, let onDelete {
                Group {
                    Button("Delete", action: onDelete).keyboardShortcut(.delete, modifiers: [])
                    Button("Delete", action: onDelete).keyboardShortcut(.deleteForward, modifiers: [])
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .tint(Theme.tangerine)
    }
}

/// A secondary line in the footer: an icon and some text that crossfades as it changes.
struct EditorStatus: View {
    let symbol: String
    let text: String
    var detail: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.tangerine)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let detail {
                Text(detail).foregroundStyle(Theme.secondaryText(scheme))
            }
        }
        .animation(Theme.snappy, value: text)
    }
}
