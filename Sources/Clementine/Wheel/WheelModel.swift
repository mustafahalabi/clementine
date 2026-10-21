import AppKit
import SwiftUI
import QuickLookThumbnailing

@MainActor
final class WheelModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var actions: [Action] = []
    @Published private(set) var mode: WheelMode = .convert
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var summary = ""
    @Published var hovered: Int?
    @Published var visible = false
    /// Bumped on every show so the slices re-run their fan-in animation (the window is reused).
    @Published private(set) var session = 0
    /// Click mode (Services menu, Open Files…): hover and click instead of drag and drop. The mode chip becomes a switch.
    @Published var interactive = false
    @Published var chipHovered = false

    let innerRadius: CGFloat = 60

    var outerRadius: CGFloat {
        actions.count <= 8 ? 150 : 150 + CGFloat(actions.count - 8) * 10
    }

    /// Window size: the wheel plus room for its shadow, the hovered slice popping out, and the mode chip.
    var canvasSize: CGFloat { outerRadius * 2 + 84 }

    var segmentAngle: Double { 2 * .pi / Double(max(actions.count, 1)) }

    func load(urls: [URL], mode: WheelMode) {
        self.urls = urls
        self.mode = mode
        session += 1
        hovered = nil
        actions = ActionRegistry.actions(for: urls, mode: mode)
        summary = Self.summary(for: urls)
        thumbnail = NSWorkspace.shared.icon(forFile: urls[0].path)
        requestThumbnail(for: urls[0])
    }

    func setMode(_ mode: WheelMode) {
        guard mode != self.mode else { return }
        withAnimation(Theme.spring) {
            self.mode = mode
            hovered = nil
            actions = ActionRegistry.actions(for: urls, mode: mode)
        }
    }

    /// Shows a fixed set of slices around a file-type icon, for the live preview in Settings.
    /// A new `session` replays the fan-in; otherwise slices that appear simply join the ring.
    func preview(actions: [Action], mode: WheelMode, icon: NSImage, summary: String, replay: Bool) {
        if replay { session += 1 }
        self.mode = mode
        self.actions = actions
        self.summary = summary
        thumbnail = icon
        hovered = nil
        visible = true
    }

    /// Whether `point` (view coordinates, y up) is on the mode chip under the ring.
    func chipContains(_ point: CGPoint, in size: CGSize) -> Bool {
        let chip = CGPoint(x: size.width / 2, y: size.height / 2 - (outerRadius + 24))
        return abs(point.x - chip.x) <= 56 && abs(point.y - chip.y) <= 13
    }

    /// The slice under `point` (view coordinates, y up), or nil for the center and outside.
    func segment(at point: CGPoint, in size: CGSize) -> Int? {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radius = hypot(dx, dy)
        guard !actions.isEmpty, radius >= innerRadius, radius <= outerRadius + 40 else { return nil }
        var angle = atan2(dx, dy) // 0 at 12 o'clock, clockwise
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + segmentAngle / 2) / segmentAngle) % actions.count
    }

    private func requestThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                if self.urls.first == url { self.thumbnail = image }
            }
        }
    }

    private static func summary(for urls: [URL]) -> String {
        let bytes = urls.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let size = bytes > 0 ? Double(bytes).megabytes : ""
        if urls.count > 1 { return size.isEmpty ? "\(urls.count) files" : "\(urls.count) files · \(size)" }
        return size.isEmpty ? urls[0].lastPathComponent : size
    }
}
