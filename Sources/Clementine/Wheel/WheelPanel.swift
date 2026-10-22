import AppKit
import SwiftUI

/// A borderless, non-activating window that pops up under the pointer mid-drag and accepts the drop.
///
/// It also has a click mode, for files that arrive without a drag (Services menu, Open Files…): the pointer
/// highlights slices, a click runs one, and Esc, the hub or a click elsewhere dismisses it.
@MainActor
final class WheelPanel {
    var onDrop: ((Action, [URL]) -> Void)?

    private let model = WheelModel()
    private let panel: WheelWindow
    private let catcher: DropCatcher
    private var center = NSPoint.zero
    private var generation = 0
    private var outsideMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    init() {
        panel = WheelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = NSView()
        let host = NSHostingView(rootView: WheelView(model: model))
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        // Drop target sits on top of the SwiftUI view so it always wins the drag hit-test (and, in click mode, the clicks).
        catcher = DropCatcher(model: model)
        catcher.autoresizingMask = [.width, .height]
        container.addSubview(catcher)
        panel.contentView = container

        catcher.onDrop = { [weak self] action, urls in self?.onDrop?(action, urls) }
        catcher.onDismiss = { [weak self] in self?.hide() }
        catcher.onToggleMode = { [weak self] in
            guard let self else { return }
            self.setMode(self.model.mode.next)
        }
    }

    /// Drag mode: follows a drag in progress and takes the drop.
    func show(urls: [URL], mode: WheelMode, at point: NSPoint) {
        endClickMode()
        present(urls: urls, mode: mode, at: point)
    }

    /// Click mode: hover to highlight, click a slice to run it.
    func showClickable(urls: [URL], mode: WheelMode, at point: NSPoint) {
        present(urls: urls, mode: mode, at: point)
        guard !model.actions.isEmpty || [mode.next, mode.next.next].contains(where: { !ActionRegistry.actions(for: urls, mode: $0).isEmpty }) else {
            // Nothing to offer on any wheel: show the notice briefly instead of waiting for a click.
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.hide(generation: current) }
            return
        }
        beginClickMode()
    }

    private func present(urls: [URL], mode: WheelMode, at point: NSPoint) {
        generation += 1
        center = point
        model.visible = false
        model.load(urls: urls, mode: mode)
        layout()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { self.model.visible = true }
    }

    func setMode(_ mode: WheelMode) {
        guard panel.isVisible else { return }
        model.setMode(mode)
        layout()
        catcher.refreshHover()
    }

    /// Hides the wheel. Pass the generation from `currentGeneration` to avoid hiding a newer wheel.
    func hide(generation expected: Int? = nil) {
        guard expected == nil || expected == generation else { return }
        endClickMode()
        model.visible = false
        model.hovered = nil
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if self.generation == current && !self.model.visible { self.panel.orderOut(nil) }
        }
    }

    var currentGeneration: Int { generation }

    func highlight(_ index: Int?) {
        model.hovered = index
    }

    // MARK: Click mode

    private func beginClickMode() {
        model.interactive = true
        catcher.clickMode = true
        panel.acceptsKey = true
        panel.makeKey()
        panel.makeFirstResponder(catcher)
        catcher.refreshHover()

        // Clicks anywhere else close the wheel, like a menu.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { outsideMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { if event.window !== self?.panel { self?.hide() } }
            return event
        }) { outsideMonitors.append(local) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.catcher.clickMode == true { self?.hide() } }
        }
    }

    private func endClickMode() {
        outsideMonitors.forEach(NSEvent.removeMonitor)
        outsideMonitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard catcher.clickMode else { return }
        catcher.clickMode = false
        model.interactive = false
        model.chipHovered = false
        panel.acceptsKey = false
        if panel.isKeyWindow { panel.resignKey() }
    }

    private func layout() {
        let side = model.canvasSize
        var frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            let bounds = screen.frame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - side)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - side)
        }
        panel.setFrame(frame, display: true)
    }
}

/// Borderless panels can't take key status by default; click mode needs it for Esc, Tab and the arrow keys.
private final class WheelWindow: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
}

/// Sits over the whole wheel. Takes drops in drag mode; in click mode it tracks the pointer and handles clicks and keys.
private final class DropCatcher: NSView {
    var onDrop: ((Action, [URL]) -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var clickMode = false
    private let model: WheelModel
    /// Where the button went down, so a press that slides off its slice doesn't run anything.
    private var pressed: Int?

    init(model: WheelModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { model.hovered = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.hovered != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = model.hovered, index < model.actions.count else { return false }
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let action = model.actions[index]
        let urls = dropped?.isEmpty == false ? dropped! : model.urls
        // Let the drag session finish before any windows open.
        DispatchQueue.main.async { self.onDrop?(action, urls) }
        return true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let index = model.segment(at: point, in: bounds.size)
        if model.hovered != index { model.hovered = index }
        // Over the hub: refuse, so dropping there cancels and Finder animates the file back.
        return index == nil ? [] : .copy
    }

    // MARK: Click mode

    override var acceptsFirstResponder: Bool { clickMode }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Accessibility

    // The catcher covers the SwiftUI wheel, so VoiceOver lands here: describe the wheel, read the highlighted
    // slice as the value, and let VoiceOver's press run it.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        let wheel = "\(model.mode.title) wheel"
        let count = model.actions.count
        let choices = count == 1 ? "1 choice" : "\(count) choices"
        return model.summary.isEmpty ? "\(wheel), \(choices)" : "\(wheel) for \(model.summary), \(choices)"
    }

    override func accessibilityValue() -> Any? {
        guard let index = model.hovered, index < model.actions.count else { return "Nothing selected" }
        return model.actions[index].accessibilityName
    }

    override func accessibilityHelp() -> String? {
        clickMode
            ? "Arrow keys choose a slice, Return runs it, Tab switches to the \(model.mode.next.title.lowercased()) wheel, Escape closes."
            : "Drop the file on a slice to run it, or on the middle to cancel."
    }

    override func accessibilityPerformPress() -> Bool {
        guard clickMode, let index = model.hovered else { return false }
        run(index)
        return true
    }

    /// Lets VoiceOver follow keyboard selection in click mode.
    func announceSelection() {
        guard clickMode else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Re-reads the pointer, e.g. after the ring changes size under it.
    func refreshHover() {
        guard clickMode, let window else { return }
        hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func hover(at point: CGPoint) {
        let index = model.segment(at: point, in: bounds.size)
        if model.hovered != index { model.hovered = index }
        let chip = index == nil && model.chipContains(point, in: bounds.size)
        if model.chipHovered != chip { model.chipHovered = chip }
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return super.mouseMoved(with: event) }
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard clickMode else { return super.mouseDragged(with: event) }
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard clickMode else { return super.mouseExited(with: event) }
        model.hovered = nil
        model.chipHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard clickMode else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        hover(at: point)
        pressed = model.hovered
    }

    override func mouseUp(with event: NSEvent) {
        guard clickMode else { return super.mouseUp(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = model.segment(at: point, in: bounds.size)
        defer { pressed = nil }
        if let index, index == pressed {
            run(index)
        } else if index == nil && model.chipContains(point, in: bounds.size) {
            onToggleMode?()
        } else if index == nil {
            onDismiss?() // the hub, or the empty space around the ring
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard clickMode else { return super.rightMouseDown(with: event) }
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        guard clickMode else { return super.keyDown(with: event) }
        let count = model.actions.count
        switch event.keyCode {
        case 53: // Esc
            onDismiss?()
        case 36, 76, 49: // Return, Enter, Space
            if let index = model.hovered { run(index) }
        case 48: // Tab
            onToggleMode?()
        case 124, 125: // → ↓: clockwise
            guard count > 0 else { return }
            model.hovered = model.hovered.map { ($0 + 1) % count } ?? 0
            announceSelection()
        case 123, 126: // ← ↑: counterclockwise
            guard count > 0 else { return }
            model.hovered = model.hovered.map { ($0 + count - 1) % count } ?? count - 1
            announceSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if clickMode { onDismiss?() }
    }

    private func run(_ index: Int) {
        guard index < model.actions.count else { return }
        let action = model.actions[index]
        let urls = model.urls
        DispatchQueue.main.async { self.onDrop?(action, urls) }
    }
}
