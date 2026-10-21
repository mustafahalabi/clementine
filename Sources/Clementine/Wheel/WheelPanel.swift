import AppKit
import SwiftUI

/// A borderless, non-activating window that pops up under the pointer mid-drag and accepts the drop.
@MainActor
final class WheelPanel {
    var onDrop: ((Action, [URL]) -> Void)?

    private let model = WheelModel()
    private let panel: NSPanel
    private var center = NSPoint.zero
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        // Drop target sits on top of the SwiftUI view so it always wins the drag hit-test.
        let catcher = DropCatcher(model: model)
        catcher.autoresizingMask = [.width, .height]
        catcher.onDrop = { [weak self] action, urls in self?.onDrop?(action, urls) }
        container.addSubview(catcher)
        panel.contentView = container
    }

    func show(urls: [URL], mode: WheelMode, at point: NSPoint) {
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
    }

    /// Hides the wheel. Pass the generation from `currentGeneration` to avoid hiding a newer wheel.
    func hide(generation expected: Int? = nil) {
        guard expected == nil || expected == generation else { return }
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

private final class DropCatcher: NSView {
    var onDrop: ((Action, [URL]) -> Void)?
    private let model: WheelModel

    init(model: WheelModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
}
