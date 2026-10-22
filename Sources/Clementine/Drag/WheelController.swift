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
    /// `Clementine.app/Contents/MacOS/Clementine --demo-wheel [--tools | --files] [--click] [--hover N] file…`
    private func demo(_ arguments: [String]) {
        var mode = WheelMode.convert
        var hovered: Int?
        var clickable = false
        var urls: [URL] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--tools": mode = .tools
            case "--files": mode = .files
            case "--click": clickable = true
            case "--hover": hovered = rest.popFirst().flatMap { Int($0) }
            default: urls.append(URL(fileURLWithPath: argument).standardizedFileURL)
            }
        }
        guard !urls.isEmpty, let screen = NSScreen.main?.frame else { return }
        let center = NSPoint(x: screen.midX, y: screen.midY)
        if clickable { return panel.showClickable(urls: urls, mode: mode, at: center) }
        panel.show(urls: urls, mode: mode, at: center)
        panel.highlight(hovered)
    }

    /// The wheel in click mode, for files that didn't arrive by drag (Services, Open Files…). Defaults to the pointer.
    func showClickable(_ urls: [URL], mode: WheelMode, at point: NSPoint? = nil) {
        guard !urls.isEmpty else { return }
        panel.showClickable(urls: urls, mode: mode, at: point ?? NSEvent.mouseLocation)
    }

    /// Menu bar › Open Files…: pick files, then choose what to do with them on a click-mode wheel at screen center.
    func openFiles() {
        let open = NSOpenPanel()
        open.title = "Open Files"
        open.message = "Choose files to convert or edit"
        open.prompt = "Choose"
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.canChooseFiles = true
        NSApp.activate()
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        // Let the open panel finish closing so it doesn't take key status back from the wheel.
        DispatchQueue.main.async {
            self.showClickable(open.urls, mode: .convert, at: NSPoint(x: screen.midX, y: screen.midY))
        }
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
