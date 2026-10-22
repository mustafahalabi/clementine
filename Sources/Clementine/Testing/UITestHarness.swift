#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI

/// Debug-only interaction tests: real windows opened off-screen and driven with synthetic mouse and keyboard
/// events, so editors can be exercised without touching the user's mouse.
///
///     Clementine --ui-test               # every suite
///     Clementine --ui-test crop redact   # suites whose name contains any of the words
///
/// Suites register in `UITest.all` (one file per area). Find controls with `frame(id:)` after tagging them with
/// `.uiTestID("…")` (no permissions needed); `frame(of:)` looks up by visible label through the Accessibility API
/// and only works when the process is trusted, so prefer IDs.
@MainActor
enum UITest {
    struct Suite {
        let name: String
        let run: (UITestContext) -> Void
    }

    static func handle(_ arguments: [String]) -> Bool {
        guard arguments.first == "--ui-test" else { return false }
        setvbuf(stdout, nil, _IONBF, 0)
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            let filters = arguments.dropFirst().map { $0.lowercased() }
            let selected = all.filter { suite in filters.isEmpty || filters.contains { suite.name.lowercased().contains($0) } }
            let context = UITestContext()
            for suite in selected {
                print(suite.name)
                suite.run(context)
                context.closeWindows()
            }
            print("\n\(context.passed) passed, \(context.failed) failed")
            exit(context.failed == 0 ? 0 : 1)
        }
        return true
    }

    /// Every suite. Areas add theirs here (keep the list sorted by area).
    static var all: [Suite] {
        harnessSelfTest + midline
    }

    /// Proves the harness itself: a button press, a drag and typing all reach SwiftUI.
    private static var harnessSelfTest: [Suite] {
        [Suite(name: "harness") { t in
            final class Box: ObservableObject { @Published var taps = 0; @Published var dragged = false; @Published var text = "" }
            let box = Box()
            struct Probe: View {
                @ObservedObject var box: Box
                var body: some View {
                    VStack(spacing: 20) {
                        Button("Tap me") { box.taps += 1 }.uiTestID("harness.tap")
                        Color.orange.frame(width: 200, height: 120)
                            .gesture(DragGesture().onEnded { _ in box.dragged = true })
                        TextField("Type here", text: $box.text).frame(width: 200).uiTestID("harness.field")
                    }
                    .padding(30)
                }
            }
            let window = t.open(Probe(box: box), size: NSSize(width: 400, height: 360))
            if let button = t.frame(id: "harness.tap", in: window) {
                t.click(button.center, in: window)
                t.check(box.taps == 1, "button press reaches SwiftUI (found by uiTestID)")
            } else {
                t.check(false, "button tagged with uiTestID is found")
            }
            t.drag(from: t.point(200, 180, in: window), to: t.point(280, 200, in: window), in: window)
            t.check(box.dragged, "drag reaches a DragGesture")
            if let field = t.frame(id: "harness.field", in: window) {
                t.click(field.center, in: window)
                t.type("abc", in: window)
                t.check(box.text == "abc", "typing reaches a focused TextField")
            }
        }]
    }
}

/// What a suite works with: off-screen windows, synthetic events, lookups and checks.
@MainActor
final class UITestContext {
    private(set) var passed = 0
    private(set) var failed = 0
    private var windows: [NSWindow] = []
    /// A scratch folder for fixtures and outputs, removed at exit.
    let scratch: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Checks

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name)") }
    }

    func skip(_ name: String) { print("  – skipped: \(name)") }

    /// Spins the run loop until `condition` holds or `timeout` passes.
    @discardableResult
    func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            settle(0.02)
        }
        return true
    }

    /// Lets time pass, dispatching queued events (there's no NSApplication.run loop in test mode).
    func settle(_ seconds: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        } while Date() < deadline
    }

    // MARK: Windows

    /// Shows `view` in a Clementine panel parked off every screen.
    func open<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = FocusablePanel(resizable: true)
        window.host(view, sizing: [])
        adopt(window, size: size)
        return window
    }

    /// Moves an already-built window off-screen at `size` and makes it key (for windows the app creates itself).
    func adopt(_ window: NSWindow, size: NSSize? = nil) {
        let frameSize = size ?? window.frame.size
        window.setFrame(NSRect(x: -8000, y: 200, width: frameSize.width, height: frameSize.height), display: true)
        window.orderFrontRegardless()
        window.makeKey()
        windows.append(window)
        settle(0.6)
    }

    /// Windows of this app titled `title` (e.g. the ones `present` functions open), parked off-screen.
    func appWindow(titled title: String, timeout: TimeInterval = 5) -> NSWindow? {
        var found: NSWindow?
        wait(timeout) {
            found = NSApp.windows.first { $0.isVisible && $0.title.contains(title) }
            return found != nil
        }
        if let found, !windows.contains(where: { $0 === found }) { adopt(found) }
        return found
    }

    func closeWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
        settle(0.3)
    }

    /// Writes what `window` shows to scratch/<name>.png and returns the path.
    @discardableResult
    func snapshot(_ window: NSWindow, _ name: String) -> URL? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = scratch.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url
    }

    // MARK: Coordinates

    /// A point given from the window's top-left corner, as layouts read.
    func point(_ x: CGFloat, _ yFromTop: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - yFromTop)
    }

    struct Frame {
        /// In window coordinates (origin bottom-left).
        let rect: NSRect
        /// Nudged off the exact center: SwiftUI hit-testing can miss on an exact integral midline.
        var center: NSPoint { NSPoint(x: rect.midX + 0.3, y: rect.midY + 0.3) }
    }

    /// The frame of a view tagged `.uiTestID(id)`, in window coordinates.
    func frame(id: String, in window: NSWindow) -> Frame? {
        guard let global = UITestRegistry.frames[id], let content = window.contentView else { return nil }
        return Frame(rect: NSRect(x: global.minX, y: content.bounds.height - global.maxY, width: global.width, height: global.height))
    }

    /// Clicks the view tagged `id`; false (and a failed check) if it isn't on screen.
    @discardableResult
    func click(id: String, in window: NSWindow) -> Bool {
        guard let frame = frame(id: id, in: window) else {
            check(false, "\(id) is on screen")
            return false
        }
        click(frame.center, in: window)
        return true
    }

    /// Finds an element whose title, label, value or description equals `label`, via the Accessibility API
    /// (queried off the main thread while the run loop keeps serving it). Nil without permission.
    func frame(of label: String, in window: NSWindow) -> Frame? {
        guard AXIsProcessTrusted() else { return nil }
        var result: CGRect?
        var done = false
        let pid = getpid()
        let windowTitle = window.title
        DispatchQueue.global().async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 3)
            func find(_ element: AXUIElement, depth: Int) -> CGRect? {
                guard depth < 40 else { return nil }
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, (value as? String) == label {
                        var position: CFTypeRef?, size: CFTypeRef?
                        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
                        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
                        var origin = CGPoint.zero, extent = CGSize.zero
                        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
                        if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
                        if extent.width > 0 { return CGRect(origin: origin, size: extent) }
                    }
                }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in (children as? [AXUIElement]) ?? [] {
                    if let found = find(child, depth: depth + 1) { return found }
                }
                return nil
            }
            var axWindows: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &axWindows)
            for axWindow in (axWindows as? [AXUIElement]) ?? [] {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
                if windowTitle.isEmpty || (title as? String) == windowTitle, let found = find(axWindow, depth: 0) {
                    result = found
                    break
                }
            }
            DispatchQueue.main.async { done = true }
        }
        wait(8) { done }
        guard let screenRect = result else { return nil }
        // Accessibility uses top-left screen coordinates; convert to the window's bottom-left ones.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - screenRect.maxY
        return Frame(rect: NSRect(x: screenRect.minX - window.frame.minX, y: cocoaY - window.frame.minY,
                                  width: screenRect.width, height: screenRect.height))
    }

    // MARK: Events

    // AppKit controls (text fields, sliders…) run their own tracking loop inside mouseDown and pull the rest of
    // the gesture from the event queue, so the follow-up events are queued before the mouse-down is sent.
    // SwiftUI views simply receive the queued events afterwards.

    func click(_ point: NSPoint, in window: NSWindow, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        for clickCount in 1...count {
            enqueue(.leftMouseUp, at: point, in: window, clickCount: clickCount, modifiers: modifiers)
            post(.leftMouseDown, at: point, in: window, clickCount: clickCount, modifiers: modifiers)
            settle(0.05)
        }
        settle(0.3)
    }

    func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int = 20, modifiers: NSEvent.ModifierFlags = []) {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            enqueue(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                    in: window, modifiers: modifiers)
        }
        enqueue(.leftMouseUp, at: end, in: window, modifiers: modifiers)
        post(.leftMouseDown, at: start, in: window, modifiers: modifiers)
        settle(0.4)
    }

    func hover(_ point: NSPoint, in window: NSWindow) {
        post(.mouseMoved, at: point, in: window)
        settle(0.2)
    }

    /// Types text into whatever has keyboard focus in `window`.
    /// Synthetic key events into an off-screen text field can stall text input, so the text goes straight into
    /// the focused field editor, which is what the keys would do.
    func type(_ text: String, in window: NSWindow) {
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            check(false, "a text field has focus before typing")
        }
        settle(0.2)
    }

    /// Common keys: return 36, escape 53, delete 51, forwardDelete 117, tab 48, left 123, right 124, down 125, up 126.
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode)
            else { continue }
            // Key equivalents (⌘Z, Return/Esc shortcuts) go through the window's key-equivalent path first.
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
        settle(0.1)
    }

    func pressReturn(in window: NSWindow) { key("\r", keyCode: 36, in: window) }
    func pressEscape(in window: NSWindow) { key("\u{1b}", keyCode: 53, in: window) }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int,
                            modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Delivers an event to the window right away.
    private func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1,
                      modifiers: NSEvent.ModifierFlags = []) {
        guard let event = mouseEvent(type, at: point, in: window, clickCount: clickCount, modifiers: modifiers) else { return }
        window.sendEvent(event)
        settle(0.02)
    }

    /// Puts an event on the app's queue, where tracking loops and the run loop pick it up in order.
    private func enqueue(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1,
                         modifiers: NSEvent.ModifierFlags = []) {
        guard let event = mouseEvent(type, at: point, in: window, clickCount: clickCount, modifiers: modifiers) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    // MARK: Fixtures

    /// A test image (gradient with shapes) of the given size, written as PNG into scratch.
    func makeImage(_ name: String = "fixture.png", width: Int = 1200, height: Int = 800) -> URL {
        let url = scratch.appendingPathComponent(name)
        if let image = try? ImageEngine.render(width: width, height: height, { context in
            let colors = [CGColor(srgbRed: 1, green: 0.6, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            context.setFillColor(.white)
            context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 3, height: height / 3))
        }), let data = try? ImageEngine.encode(image, format: .png, quality: 1) {
            try? data.write(to: url)
        }
        return url
    }

    /// Runs a shell command (e.g. ffmpeg to make media fixtures); returns its exit status.
    @discardableResult
    func shell(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = scratch
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
