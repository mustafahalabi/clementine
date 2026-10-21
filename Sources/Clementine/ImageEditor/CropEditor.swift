import AppKit
import SwiftUI

/// Crop: a draggable frame with aspect presets and quarter turns. Produces `crop` JSON for `ImageEdits.crop`.
@MainActor
enum CropEditor {
    static func present(_ urls: [URL], _ defaults: ParamValues, _ apply: @escaping (ParamValues) -> Void) {
        guard urls.count == 1 else {
            // One frame can't fit several pictures; crop them all centered to a preset instead.
            let presets = Action(id: "tool.image.crop", title: "Crop", symbol: "crop", mode: .tools,
                                 parameters: [.choice("aspect", "Aspect ratio", ImageTools.cropOptions)],
                                 accepts: { _ in true }, run: { _ in .files([]) })
            ParameterWindow.present(action: presets, urls: urls, apply: apply)
            return
        }
        ImageEditorWindow.present(urls[0], title: "Crop", apply: apply) { image, finish in
            CropEditorView(model: CropModel(source: image), onApply: { finish($0) }, onCancel: { finish(nil) })
        }
    }
}

@MainActor
final class CropModel: ObservableObject {
    enum Aspect: CaseIterable {
        case free, original, square, portrait, standard, classic, wide, tall

        var label: String {
            ["Free", "Original", "1:1", "4:5", "4:3", "3:2", "16:9", "9:16"][Self.allCases.firstIndex(of: self)!]
        }

        /// Width over height; nil for free. Original follows the (possibly turned) picture.
        func ratio(for size: CGSize) -> CGFloat? {
            switch self {
            case .free: return nil
            case .original: return size.width / max(size.height, 1)
            case .square: return 1
            case .portrait: return 4.0 / 5
            case .standard: return 4.0 / 3
            case .classic: return 3.0 / 2
            case .wide: return 16.0 / 9
            case .tall: return 9.0 / 16
            }
        }
    }

    /// What a drag started on.
    enum Drag: Equatable {
        case handle(RectHandle, from: CGRect)
        case new(anchor: CGPoint, previous: CGRect)
    }

    let source: EditorImage
    /// Clockwise degrees.
    @Published private(set) var rotation = 0
    @Published private(set) var preview: NSImage
    /// The crop in pixels of the turned image.
    @Published var rect: CGRect
    @Published private(set) var aspect = Aspect.free
    @Published var hover: RectHandle?
    @Published var drag: Drag?
    /// The canvas starts a turn rotated back by this much and springs to 0.
    @Published var spin: Double = 0

    init(source: EditorImage) {
        self.source = source
        preview = ImageEngine.nsImage(source.preview)
        rect = CGRect(origin: .zero, size: source.pixelSize)
    }

    var imageSize: CGSize {
        rotation % 180 == 0 ? source.pixelSize : CGSize(width: source.pixelSize.height, height: source.pixelSize.width)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    var ratio: CGFloat? { aspect.ratio(for: imageSize) }
    var pixelRect: ImageEdits.PixelRect { ImageEdits.PixelRect(rect) }
    var isDragging: Bool { drag != nil }

    var isUnchanged: Bool {
        rotation == 0 && pixelRect == ImageEdits.PixelRect(bounds)
    }

    var values: ParamValues {
        let crop = pixelRect
        let spec = ImageEdits.CropSpec(x: crop.x, y: crop.y, w: crop.w, h: crop.h, rotate: rotation)
        return ParamValues(storage: ["crop": .text(ImageEdits.encode(spec)), "aspect": .choice(0)])
    }

    /// The biggest rectangle at `ratio` centered in the picture.
    private func largest(_ ratio: CGFloat?) -> CGRect {
        guard let ratio else { return bounds }
        let size = imageSize.width / imageSize.height > ratio
            ? CGSize(width: imageSize.height * ratio, height: imageSize.height)
            : CGSize(width: imageSize.width, height: imageSize.width / ratio)
        return CGRect(x: (imageSize.width - size.width) / 2, y: (imageSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    func setAspect(_ aspect: Aspect) {
        self.aspect = aspect
        if aspect != .free { rect = largest(ratio) }
    }

    /// Turns the picture a quarter clockwise (1) or counterclockwise (-1), carrying a free crop along.
    func turn(_ direction: Int, animated: Bool) {
        let old = imageSize
        rotation = (rotation + direction * 90 + 360) % 360
        preview = (try? ImageEdits.rotated(source.preview, degrees: rotation)).map(ImageEngine.nsImage) ?? preview
        if aspect == .free {
            rect = direction > 0
                ? CGRect(x: old.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
                : CGRect(x: rect.minY, y: old.width - rect.maxX, width: rect.height, height: rect.width)
        } else {
            rect = largest(ratio)
        }
        guard animated else { return }
        // Show the turned picture spun back to where it was, then let it swing into place.
        spin = Double(-direction * 90)
        DispatchQueue.main.async { withAnimation(Theme.spring) { self.spin = 0 } }
    }

    func reset() {
        while rotation != 0 { turn(1, animated: false) }
        aspect = .free
        rect = bounds
    }

    // MARK: Dragging

    func update(start: CGPoint, location: CGPoint, map: CanvasMapping) {
        let minSize = min(28 / map.scale, imageSize.width, imageSize.height)
        if drag == nil {
            if let handle = RectHandle.hit(start, in: map.view(rect)) {
                drag = .handle(handle, from: rect)
            } else if map.frame.insetBy(dx: -12, dy: -12).contains(start) {
                drag = .new(anchor: map.clampedImage(start), previous: rect)
            } else {
                return
            }
        }
        let translation = CGSize(width: (location.x - start.x) / map.scale, height: (location.y - start.y) / map.scale)
        switch drag {
        case .handle(let handle, let from):
            rect = handle.drag(from, by: translation, in: bounds, minSize: minSize, ratio: ratio)
        case .new(let anchor, let previous):
            // A click without a drag keeps the current frame.
            rect = hypot(location.x - start.x, location.y - start.y) < 4 ? previous
                : RectHandle.span(from: anchor, to: map.clampedImage(location), in: bounds, minSize: minSize, ratio: ratio)
        case nil:
            break
        }
    }

    func endDrag() { drag = nil }

    var activeHandle: RectHandle? {
        if case .handle(let handle, _) = drag { return handle }
        return nil
    }
}

struct CropEditorView: View {
    @StateObject var model: CropModel
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: CropModel, onApply: @escaping (ParamValues) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        EditorShell(symbol: "crop", title: "Crop", subtitle: model.source.url.lastPathComponent,
                    applyTitle: "Crop", canApply: !model.isUnchanged,
                    onApply: { onApply(model.values) }, onCancel: onCancel) {
            ChipPicker(items: CropModel.Aspect.allCases.map { .init(value: $0, label: $0.label) },
                       selection: Binding(get: { model.aspect }, set: { model.setAspect($0) }))
            Spacer(minLength: 0)
            ToolTray {
                ToolIconButton(symbol: "rotate.left", help: "Rotate left") { turn(-1) }
                ToolIconButton(symbol: "rotate.right", help: "Rotate right") { turn(1) }
            }
            ToolTray {
                ToolIconButton(symbol: "arrow.counterclockwise", help: "Reset") {
                    withAnimation(reduceMotion ? Theme.ease : Theme.spring) { model.reset() }
                }
                .disabled(model.isUnchanged && model.aspect == .free)
            }
        } canvas: {
            EditorCanvas(image: model.preview, imageSize: model.imageSize, spin: model.spin) { map in
                CropOverlay(model: model, map: map)
            }
        } status: {
            EditorStatus(symbol: "aspectratio", text: "\(Int(model.pixelRect.w)) × \(Int(model.pixelRect.h)) px",
                         detail: model.rotation == 0 ? "Drag the corners or edges, or draw a new frame"
                                                     : "Turned \(model.rotation)° clockwise")
        }
    }

    private func turn(_ direction: Int) {
        model.turn(direction, animated: !reduceMotion)
    }
}

/// The dimmed surround, the frame with its handles, the thirds grid while dragging, and the size readout.
private struct CropOverlay: View {
    @ObservedObject var model: CropModel
    let map: CanvasMapping

    var body: some View {
        let frame = map.view(model.rect)
        let dragging = model.isDragging
        ZStack(alignment: .topLeading) {
            CropShade(hole: frame, outer: map.frame)
                .fill(Color.black.opacity(dragging ? 0.58 : 0.48), style: FillStyle(eoFill: true))
                .animation(Theme.ease, value: dragging)
                .allowsHitTesting(false)
            CropFrame(hover: model.hover, active: model.activeHandle, dragging: dragging)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            CanvasPill(text: "\(Int(model.pixelRect.w)) × \(Int(model.pixelRect.h))")
                .position(x: frame.midX, y: frame.height > 64 ? frame.maxY - 20 : frame.maxY + 16)
                .opacity(dragging ? 1 : 0)
                .scaleEffect(dragging ? 1 : 0.9)
                .animation(Theme.snappy, value: dragging)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.update(start: value.startLocation, location: value.location, map: map)
                    (model.activeHandle.map { $0 == .move ? NSCursor.closedHand : $0.cursor } ?? NSCursor.crosshair).set()
                }
                .onEnded { _ in
                    model.endDrag()
                    NSCursor.arrow.set()
                }
        )
        .onContinuousHover { phase in
            guard !model.isDragging else { return }
            switch phase {
            case .active(let point):
                let handle = RectHandle.hit(point, in: frame)
                if model.hover != handle { model.hover = handle }
                (handle?.cursor ?? (map.frame.contains(point) ? NSCursor.crosshair : NSCursor.arrow)).set()
            case .ended:
                model.hover = nil
                NSCursor.arrow.set()
            }
        }
    }
}

/// Everything outside the crop, with an animatable hole.
private struct CropShade: Shape {
    var hole: CGRect
    let outer: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(outer)
        path.addRect(hole)
        return path
    }
}

/// The crop border: thick corner brackets, edge grips, and a rule-of-thirds grid that fades in while dragging.
private struct CropFrame: View {
    let hover: RectHandle?
    let active: RectHandle?
    let dragging: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ThirdsGrid()
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
                    .shadow(color: .black.opacity(0.35), radius: 0.5)
                    .opacity(dragging ? 1 : 0)
                    .animation(Theme.ease, value: dragging)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
                    .shadow(color: .black.opacity(0.45), radius: 1.5)
                ForEach(RectHandle.corners, id: \.self) { corner in
                    bracket(corner, in: size)
                }
                if min(size.width, size.height) > 70 {
                    ForEach(RectHandle.edges, id: \.self) { edge in
                        grip(edge, in: size)
                    }
                }
            }
        }
    }

    private func color(_ handle: RectHandle) -> Color {
        active == handle || hover == handle ? Theme.tangerine : .white
    }

    private func bracket(_ corner: RectHandle, in size: CGSize) -> some View {
        let length: CGFloat = 24, outset: CGFloat = 2.5
        let point = corner.point(in: CGRect(origin: .zero, size: size))
        let shift = length / 2 - outset
        let degrees: Double = [.topLeft: 0, .topRight: 90, .bottomRight: 180, .bottomLeft: 270][corner] ?? 0
        let lit = active == corner || hover == corner
        return Bracket()
            .stroke(color(corner), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            .frame(width: length, height: length)
            .rotationEffect(.degrees(degrees))
            .shadow(color: .black.opacity(0.4), radius: 1.5)
            .scaleEffect(lit ? 1.2 : 1, anchor: corner.anchor) // grows from the corner, staying attached
            .position(x: point.x - CGFloat(corner.sides.x) * shift, y: point.y - CGFloat(corner.sides.y) * shift)
            .animation(Theme.snappy, value: lit)
    }

    private func grip(_ edge: RectHandle, in size: CGSize) -> some View {
        let point = edge.point(in: CGRect(origin: .zero, size: size))
        let horizontal = edge.sides.y != 0
        let lit = active == edge || hover == edge
        return Capsule()
            .fill(color(edge))
            .frame(width: horizontal ? 24 : 4, height: horizontal ? 4 : 24)
            .shadow(color: .black.opacity(0.4), radius: 1.5)
            .scaleEffect(lit ? 1.2 : 1)
            .position(x: point.x + CGFloat(edge.sides.x), y: point.y + CGFloat(edge.sides.y))
            .animation(Theme.snappy, value: lit)
    }
}

/// An L: down the left side and along the top.
private struct Bracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}
