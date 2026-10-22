import AppKit
import SwiftUI

/// Shows text results: metadata, QR code contents.
@MainActor
enum ResultWindow {
    private static var windows: [NSWindow] = []

    static func show(title: String, body: String) {
        let window = FocusablePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), resizable: true)
        window.title = title
        window.minSize = NSSize(width: 380, height: 280)
        window.host(ResultView(title: title, text: body), sizing: [.minSize])
        window.center()
        windows.append(window)
        window.onceClosed { [weak window] in windows.removeAll { $0 === window } }
        window.present()
    }
}

struct ResultView: View {
    let title: String
    let text: String
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?
    @Environment(\.colorScheme) private var scheme

    /// A web link that makes up a whole paragraph (how QR payloads are listed), offered as an Open button.
    private var link: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for paragraph in text.components(separatedBy: "\n\n") {
            let candidate = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            let whole = NSRange(candidate.startIndex..., in: candidate)
            if let match = detector.firstMatch(in: candidate, range: whole), match.range == whole,
               let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        return nil
    }

    private var summary: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        return link != nil ? "Contains a link" : lines == 1 ? "1 line" : "\(lines) lines"
    }

    var body: some View {
        VStack(spacing: 14) {
            SheetHeader(symbol: link != nil ? "qrcode" : "doc.text.magnifyingglass", title: title, subtitle: summary)
                .padding(.top, 4)

            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .card(radius: 12)

            HStack(spacing: 10) {
                Spacer()
                if let link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help(link.absoluteString)
                }
                Button(action: copy) {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "Copied" : "Copy")
                            .contentTransition(.interpolate)
                    }
                }
                .buttonStyle(AccentButtonStyle(fill: copied ? Theme.success : Theme.accent, glow: copied ? Theme.leaf : Theme.glow))
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding([.horizontal, .bottom], 20)
        .frame(minWidth: 360, minHeight: 240)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .animation(Theme.spring, value: copied)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}
