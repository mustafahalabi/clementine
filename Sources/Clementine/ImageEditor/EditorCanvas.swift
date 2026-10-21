import AppKit
import ImageIO
import SwiftUI

/// The picture an editor works on: a screen-sized preview, plus the full-resolution size of the upright image
/// that all editor coordinates refer to.
struct EditorImage {
    let url: URL
    let preview: CGImage
    /// Full-resolution pixels of the upright image.
    let pixelSize: CGSize

    /// Preview pixels per image pixel.
    var previewScale: CGFloat { CGFloat(preview.width) / pixelSize.width }

    static func load(_ url: URL, maxPixel: Int = 2048) throws -> EditorImage {
        let preview = try ImageEngine.load(url, maxPixel: maxPixel).image
        var size = CGSize(width: preview.width, height: preview.height)
        if url.pathExtension.lowercased() != "svg", let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        return EditorImage(url: url, preview: preview, pixelSize: size)
    }
}

/// Maps between canvas view points and image pixels (top-left origin) for an image fitted into the canvas.
struct CanvasMapping {
    let imageSize: CGSize
    /// Where the image sits in the canvas.
    let frame: CGRect

    var scale: CGFloat { frame.width / max(imageSize.width, 1) }

    static func fit(_ imageSize: CGSize, in bounds: CGSize, padding: CGFloat) -> CanvasMapping {
        let available = CGSize(width: max(bounds.width - padding * 2, 1), height: max(bounds.height - padding * 2, 1))
        let scale = min(available.width / max(imageSize.width, 1), available.height / max(imageSize.height, 1))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CanvasMapping(imageSize: imageSize, frame: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                                 width: size.width, height: size.height))
    }

    func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    func image(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
    }

    func view(_ rect: CGRect) -> CGRect {
        CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    /// An image point clamped to the image.
    func clampedImage(_ point: CGPoint) -> CGPoint {
        let p = image(point)
        return CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
}

/// The editing surface: the image fitted into a recessed well on a checkerboard, with an overlay laid out in the
/// same coordinate space as the mapping it's given.
struct EditorCanvas<Overlay: View>: View {
    let image: NSImage
    let imageSize: CGSize
    var padding: CGFloat = 22
    /// Degrees the picture is turned by (quarter-turn animations).
    var spin: Double = 0
    @ViewBuilder let overlay: (CanvasMapping) -> Overlay
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let well = RoundedRectangle(cornerRadius: 14, style: .continuous)
        GeometryReader { geo in
            let map = CanvasMapping.fit(imageSize, in: geo.size, padding: padding)
            ZStack(alignment: .topLeading) {
                Checkerboard(cell: 10)
                    .frame(width: map.frame.width, height: map.frame.height)
                    .overlay(Image(nsImage: image).resizable().interpolation(.high))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.2), radius: 10, y: 4)
                    .offset(x: map.frame.minX, y: map.frame.minY)
                overlay(map)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .modifier(TurnEffect(angle: spin, compensation: spin == 0 ? 1 : turnCompensation(map, in: geo.size)))
        }
        .background(well.fill(scheme == .dark ? Color.black.opacity(0.35) : Color(hex: 0xF1E9E0)))
        .clipShape(well)
        .overlay(well.strokeBorder(Theme.edge(scheme), lineWidth: 1))
    }

    /// How much to scale the turned picture so that, spun back a quarter, it matches the size it had before.
    private func turnCompensation(_ map: CanvasMapping, in size: CGSize) -> CGFloat {
        let before = CanvasMapping.fit(CGSize(width: imageSize.height, height: imageSize.width), in: size, padding: padding)
        return before.scale / max(map.scale, 0.0001)
    }
}

/// Rotates the picture by `angle` while easing its scale between the old and new fit, so a quarter turn
/// reads as the same picture swinging round.
private struct TurnEffect: ViewModifier, Animatable {
    var angle: Double
    let compensation: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + (compensation - 1) * min(abs(angle) / 90, 1))
            .rotationEffect(.degrees(angle))
    }
}

// MARK: Rectangles with handles

/// The parts of a rectangle that can be dragged, shared by the crop frame and redaction boxes.
enum RectHandle: Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    static let corners: [RectHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    static let edges: [RectHandle] = [.top, .right, .bottom, .left]

    /// Which sides move: -1 for the left/top, 1 for the right/bottom, 0 for neither.
    var sides: (x: Int, y: Int) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .right: return (1, 0)
        case .bottomRight: return (1, 1)
        case .bottom: return (0, 1)
        case .bottomLeft: return (-1, 1)
        case .left: return (-1, 0)
        case .move: return (0, 0)
        }
    }

    var isCorner: Bool { sides.x != 0 && sides.y != 0 }

    /// Where the handle sits on `rect`, as a unit point.
    var anchor: UnitPoint {
        UnitPoint(x: CGFloat(sides.x + 1) / 2, y: CGFloat(sides.y + 1) / 2)
    }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
    }

    /// The handle under `point` for a rectangle in view coordinates; corners win, then edges, then the inside.
    static func hit(_ point: CGPoint, in rect: CGRect, reach: CGFloat = 12) -> RectHandle? {
        // Small boxes keep a usable middle for moving.
        let corner = min(reach + 4, max(rect.width, rect.height) / 3)
        if let match = corners.first(where: { hypot($0.point(in: rect).x - point.x, $0.point(in: rect).y - point.y) <= corner }) {
            return match
        }
        let grown = rect.insetBy(dx: -reach, dy: -reach)
        guard grown.contains(point) else { return nil }
        let edge = min(reach, min(rect.width, rect.height) / 4)
        if abs(point.y - rect.minY) <= edge { return .top }
        if abs(point.y - rect.maxY) <= edge { return .bottom }
        if abs(point.x - rect.minX) <= edge { return .left }
        if abs(point.x - rect.maxX) <= edge { return .right }
        return rect.contains(point) ? .move : nil
    }

    var cursor: NSCursor {
        if self == .move { return .openHand }
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            default: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        return isCorner ? .crosshair : sides.x != 0 ? .resizeLeftRight : .resizeUpDown
    }

    /// `start` after dragging this handle by `translation` (image pixels), kept inside `bounds`, at least `minSize`,
    /// and at `ratio` (width / height) when one is given.
    func drag(_ start: CGRect, by translation: CGSize, in bounds: CGRect, minSize: CGFloat, ratio: CGFloat?) -> CGRect {
        let (sx, sy) = sides
        if self == .move {
            let x = min(max(start.minX + translation.width, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + translation.height, bounds.minY), bounds.maxY - start.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: start.size)
        }
        if isCorner {
            let anchor = RectHandle.corners.first { $0.sides == (-sx, -sy) }!.point(in: start)
            let moved = point(in: start)
            return RectHandle.span(from: anchor, to: CGPoint(x: moved.x + translation.width, y: moved.y + translation.height),
                                   in: bounds, minSize: minSize, ratio: ratio)
        }
        guard let ratio else {
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            if sx < 0 { minX = min(max(start.minX + translation.width, bounds.minX), maxX - minSize) }
            if sx > 0 { maxX = max(min(start.maxX + translation.width, bounds.maxX), minX + minSize) }
            if sy < 0 { minY = min(max(start.minY + translation.height, bounds.minY), maxY - minSize) }
            if sy > 0 { maxY = max(min(start.maxY + translation.height, bounds.maxY), minY + minSize) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // An edge with a fixed ratio grows the other dimension evenly about the middle.
        if sx != 0 {
            let room = sx > 0 ? bounds.maxX - start.minX : start.maxX - bounds.minX
            let tall = 2 * min(start.midY - bounds.minY, bounds.maxY - start.midY)
            let width = min(max(start.width + translation.width * CGFloat(sx), minSize * max(ratio, 1)), room, tall * ratio)
            let height = width / ratio
            return CGRect(x: sx > 0 ? start.minX : start.maxX - width, y: start.midY - height / 2, width: width, height: height)
        }
        let room = sy > 0 ? bounds.maxY - start.minY : start.maxY - bounds.minY
        let wide = 2 * min(start.midX - bounds.minX, bounds.maxX - start.midX)
        let height = min(max(start.height + translation.height * CGFloat(sy), minSize * max(1 / ratio, 1)), room, wide / ratio)
        let width = height * ratio
        return CGRect(x: start.midX - width / 2, y: sy > 0 ? start.minY : start.maxY - height, width: width, height: height)
    }

    /// The rectangle from `anchor` towards `point`, inside `bounds`, at `ratio` if given.
    static func span(from anchor: CGPoint, to point: CGPoint, in bounds: CGRect, minSize: CGFloat, ratio: CGFloat?) -> CGRect {
        let dx: CGFloat = point.x >= anchor.x ? 1 : -1, dy: CGFloat = point.y >= anchor.y ? 1 : -1
        let roomX = dx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let roomY = dy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        var width = min(abs(point.x - anchor.x), roomX), height = min(abs(point.y - anchor.y), roomY)
        if let ratio {
            width = max(width, height * ratio)
            width = min(width, roomX, roomY * ratio)
            width = max(width, min(minSize * max(ratio, 1), roomX, roomY * ratio))
            height = width / ratio
        } else {
            width = max(width, min(minSize, roomX))
            height = max(height, min(minSize, roomY))
        }
        return CGRect(x: dx > 0 ? anchor.x : anchor.x - width, y: dy > 0 ? anchor.y : anchor.y - height, width: width, height: height)
    }
}

/// A round handle dot that swells on hover and fills with citrus while dragged.
struct HandleDot: View {
    var hovered = false
    var active = false
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white))
            .overlay(Circle().strokeBorder(active ? Color.white : Theme.tangerine, lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .scaleEffect(active ? 1.3 : hovered ? 1.22 : 1)
            .animation(Theme.snappy, value: hovered)
            .animation(Theme.snappy, value: active)
    }
}

// MARK: Toolbar pieces

/// A capsule tray holding a group of toolbar controls.
struct ToolTray<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background(Capsule().fill(Theme.card(scheme)))
            .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.05), radius: 3, y: 1)
    }
}

/// A segmented control in a tray: the chosen item sits on a citrus capsule that slides between options.
struct ChipPicker<Value: Hashable>: View {
    struct Item {
        let value: Value
        var label: String? = nil
        var symbol: String? = nil
        /// A plain dot of this diameter (stroke widths).
        var dot: CGFloat? = nil
        var help: String? = nil
    }

    let items: [Item]
    @Binding var selection: Value
    @Namespace private var namespace
    @State private var hovered: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ToolTray {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = item.value == selection
                Button {
                    withAnimation(reduceMotion ? Theme.ease : Theme.spring) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                        if let dot = item.dot { Circle().frame(width: dot, height: dot) }
                        if let label = item.label { Text(label).font(.system(size: 12, weight: .semibold)) }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                    .padding(.horizontal, item.label == nil ? 0 : 10)
                    .frame(minWidth: 28, minHeight: 26)
                    .background {
                        if selected {
                            Capsule().fill(Theme.accent)
                                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                                .shadow(color: Theme.glow.opacity(0.5), radius: 4, y: 1)
                                .matchedGeometryEffect(id: "chip", in: namespace)
                        } else if hovered == item.value {
                            Capsule().fill(Color.primary.opacity(0.07))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .onHover { inside in withAnimation(Theme.ease) { hovered = inside ? item.value : (hovered == item.value ? nil : hovered) } }
                .help(item.help ?? item.label ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A round icon button for toolbars (rotate, undo…).
struct ToolIconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(enabled ? 0.8 : 0.3))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.ease, value: hovering)
        .help(help)
    }
}

/// Dips slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// A small dark capsule label floating over the canvas (pixel sizes, hints).
struct CanvasPill: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
    }
}
