import AppKit

/// Notices file drags in other apps (Finder, Desktop…) and whether ⇧ / ⌥⇧ / ⌃ is held.
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
    /// When ⌃ (without ⇧) went down during this drag.
    private var controlSince: Date?

    /// ⌃←/⌃→ switch Spaces mid-drag, so ⌃ has to be held a moment before the file actions wheel opens; a quick
    /// ⌃-arrow to carry a file to another desktop then doesn't flash a wheel.
    static let controlHold: TimeInterval = 0.25

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        draggedURLs = nil
        mode = nil
        controlSince = nil
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
        guard let wanted = wheel(for: flags) else { return } // letting go of the keys keeps the wheel that's up
        if mode == nil {
            mode = wanted
            handler(.began(urls, wanted))
        } else if mode != wanted {
            mode = wanted
            handler(.modeChanged(wanted))
        }
    }

    /// ⇧ (with ⌥ for tools) wins over ⌃, so ⌃⇧ is still the convert wheel. ⌘ means "move" in Finder; ⌃ is ignored
    /// alongside it.
    /// Internal (not private) so the UI tests can check the rules with made-up flags and times.
    func wheel(for flags: NSEvent.ModifierFlags, now: Date = Date()) -> WheelMode? {
        if flags.contains(.shift) {
            controlSince = nil
            return flags.contains(.option) ? .tools : .convert
        }
        guard flags.contains(.control), !flags.contains(.command), Prefs.controlWheel else {
            controlSince = nil
            return nil
        }
        let since = controlSince ?? now
        controlSince = since
        return now.timeIntervalSince(since) >= Self.controlHold ? .files : nil
    }
}
