import AppKit

/// Glue between the drag monitor, the wheel, and the job runner.
@MainActor
final class WheelController {
    static let shared = WheelController()

    private let monitor = DragMonitor()
    private let panel = WheelPanel()

    func start() {
        panel.onDrop = { [weak self] action, urls in
            self?.panel.hide()
            JobRunner.shared.start(action, urls: urls)
        }
        monitor.handler = { [weak self] event in self?.handle(event) }
        monitor.start()

        if let flag = CommandLine.arguments.firstIndex(of: "--demo-wheel") {
            demo(Array(CommandLine.arguments[(flag + 1)...]))
        }
    }

    /// Shows the wheel without a drag, for working on its looks:
    /// `Clementine.app/Contents/MacOS/Clementine --demo-wheel [--tools] [--hover N] file…`
    private func demo(_ arguments: [String]) {
        var mode = WheelMode.convert
        var hovered: Int?
        var urls: [URL] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--tools": mode = .tools
            case "--hover": hovered = rest.popFirst().flatMap { Int($0) }
            default: urls.append(URL(fileURLWithPath: argument).standardizedFileURL)
            }
        }
        guard !urls.isEmpty, let screen = NSScreen.main?.frame else { return }
        panel.show(urls: urls, mode: mode, at: NSPoint(x: screen.midX, y: screen.midY))
        panel.highlight(hovered)
    }

    private func handle(_ event: DragMonitor.Event) {
        switch event {
        case .began(let urls, let mode):
            panel.show(urls: urls, mode: mode, at: NSEvent.mouseLocation)
        case .modeChanged(let mode):
            panel.setMode(mode)
        case .ended:
            // The drop (if any) is delivered just after the button comes up, so give it a moment.
            let generation = panel.currentGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panel.hide(generation: generation)
            }
        }
    }
}
