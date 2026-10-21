import AppKit

/// Notices file drags in other apps (Finder, Desktop…) and whether ⇧ / ⌥⇧ is held.
///
/// Global mouse-down monitoring needs no special permission. While the button is held we poll
/// the shared drag pasteboard: its change count bumps when a drag session starts.
@MainActor
final class DragMonitor {
    enum Event {
        case began([URL], WheelMode)
        case modeChanged(WheelMode)
        case ended
    }

    var handler: (Event) -> Void = { _ in }

    private var monitor: Any?
    private var timer: Timer?
    private var baseline = 0
    private var draggedURLs: [URL]?
    private var mode: WheelMode?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        draggedURLs = nil
        mode = nil
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer?.invalidate()
            timer = nil
            if mode != nil { handler(.ended) }
            mode = nil
            return
        }

        if draggedURLs == nil {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != baseline else { return }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            draggedURLs = urls
            if urls.isEmpty {
                // Text or some other non-file drag: nothing for us to do until the next click.
                timer?.invalidate()
                timer = nil
                return
            }
        }
        guard let urls = draggedURLs, Prefs.enabled else { return }

        let flags = NSEvent.modifierFlags
        guard flags.contains(.shift) else { return } // releasing ⇧ keeps the wheel that's already up
        let wanted: WheelMode = flags.contains(.option) ? .tools : .convert
        if mode == nil {
            mode = wanted
            handler(.began(urls, wanted))
        } else if mode != wanted {
            mode = wanted
            handler(.modeChanged(wanted))
        }
    }
}
