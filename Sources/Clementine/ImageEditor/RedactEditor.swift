import AppKit
import SwiftUI

/// Redact: draw boxes (or detect faces and text) to black out, pixelate or blur. Produces `boxes` JSON and a `style`
/// for `ImageEdits.redact`; the canvas shows the real effect, rendered by the same code on the preview.
@MainActor
enum RedactEditor {
    static func present(_ urls: [URL], _ defaults: ParamValues, _ apply: @escaping (ParamValues) -> Void) {
        ImageEditorWindow.present(urls[0], title: "Redact", apply: apply) { image, finish in
            RedactEditorView(model: RedactModel(source: image), onApply: { finish($0) }, onCancel: { finish(nil) })
        }
    }
}

@MainActor
final class RedactModel: ObservableObject {
    struct Box: Identifiable, Equatable {
        enum Kind { case drawn, face, text }
        var id = UUID()
        /// Image pixels.
        var rect: CGRect
        var kind = Kind.drawn
        /// Seconds before it pops in, so detected boxes arrive one after another.
        var delay = 0.0
    }

    struct Hover: Equatable {
        let id: UUID
        let handle: RectHandle
    }

    enum Drag: Equatable {
        case handle(RectHandle, id: UUID, from: CGRect)
        case new(id: UUID, anchor: CGPoint)
        case nothing
    }

    let source: EditorImage
    @Published var boxes: [Box] = []
    @Published var selection: UUID?
    @Published var style = ImageEdits.RedactStyle.pixelate
    @Published var hover: Hover?
    @Published var drag: Drag?
    /// The preview with the redaction applied.
    @Published private(set) var rendered: NSImage
    @Published private(set) var detecting = false
    @Published var notice: String?
    private let original: NSImage
    private let seed = UInt64.random(in: .min ... .max)

    init(source: EditorImage) {
        self.source = source
        original = ImageEngine.nsImage(source.preview)
        rendered = original
    }

    var bounds: CGRect { CGRect(origin: .zero, size: source.pixelSize) }

    var values: ParamValues {
        ParamValues(storage: ["boxes": .text(ImageEdits.encode(boxes.map { ImageEdits.PixelRect($0.rect) })),
                              "style": .choice(style.rawValue)])
    }

    var selectedBox: Box? { boxes.first { $0.id == selection } }

    var activeHandle: (id: UUID, handle: RectHandle)? {
        if case .handle(let handle, let id, _) = drag { return (id, handle) }
        if case .new(let id, _) = drag { return (id, .bottomRight) }
        return nil
    }

    // MARK: Rendering

    struct RenderKey: Equatable {
        let rects: [CGRect]
        let style: ImageEdits.RedactStyle
    }

    var renderKey: RenderKey { RenderKey(rects: boxes.map(\.rect), style: style) }

    /// Re-renders the preview with the current boxes, off the main thread.
    func render() async {
        let key = renderKey
        guard !key.rects.isEmpty else { rendered = original; return }
        let preview = source.preview, scale = source.previewScale, seed = seed
        let scaled = key.rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        let image = await Task.detached(priority: .userInitiated) {
            try? ImageEdits.redacted(preview, boxes: scaled, style: key.style, seed: seed, minBlock: 12 * scale)
        }.value
        if !Task.isCancelled, let image { rendered = ImageEngine.nsImage(image) }
    }

    // MARK: Editing

    func delete() {
        guard let selection else { return }
        boxes.removeAll { $0.id == selection }
        self.selection = nil
    }

    func update(start: CGPoint, location: CGPoint, map: CanvasMapping) {
        let minSize = 10 / map.scale
        if drag == nil {
            if let box = selectedBox, let handle = RectHandle.hit(start, in: map.view(box.rect), reach: 9) {
                drag = .handle(handle, id: box.id, from: box.rect)
            } else if let box = boxes.last(where: { map.view($0.rect).contains(start) }) {
                selection = box.id
                drag = .handle(.move, id: box.id, from: box.rect)
            } else if map.frame.contains(start) {
                drag = .new(id: UUID(), anchor: map.clampedImage(start))
            } else {
                drag = .nothing
            }
        }
        let translation = CGSize(width: (location.x - start.x) / map.scale, height: (location.y - start.y) / map.scale)
        switch drag {
        case .handle(let handle, let id, let from):
            guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
            boxes[index].rect = handle.drag(from, by: translation, in: bounds, minSize: minSize, ratio: nil)
        case .new(let id, let anchor):
            guard hypot(location.x - start.x, location.y - start.y) >= 4 else { return }
            let rect = RectHandle.span(from: anchor, to: map.clampedImage(location), in: bounds, minSize: minSize, ratio: nil)
            if let index = boxes.firstIndex(where: { $0.id == id }) {
                boxes[index].rect = rect
            } else {
                boxes.append(Box(id: id, rect: rect))
                selection = id
            }
        default:
            break
        }
    }

    func endDrag() {
        // A click on empty canvas clears the selection.
        if case .new(let id, _) = drag, !boxes.contains(where: { $0.id == id }) { selection = nil }
        if drag == .nothing { selection = nil }
        drag = nil
    }

    func clear() {
        boxes.removeAll()
        selection = nil
        notice = nil
    }

    /// Finds faces and text lines in the preview and adds boxes for any not already covered.
    func autoDetect(animation: Animation?) async {
        detecting = true
        notice = nil
        let preview = source.preview, scale = source.previewScale
        let found = await Task.detached(priority: .userInitiated) { try? ImageEdits.detectSensitive(in: preview) }.value ?? []
        detecting = false
        let fresh = found.map { detection in
            Box(rect: CGRect(x: detection.rect.minX / scale, y: detection.rect.minY / scale,
                             width: detection.rect.width / scale, height: detection.rect.height / scale),
                kind: detection.kind == .face ? .face : .text)
        }
        .filter { candidate in !boxes.contains { Self.overlap($0.rect, candidate.rect) > 0.5 } }
        withAnimation(animation) {
            boxes += fresh.enumerated().map { index, box in
                var box = box
                box.delay = Double(index) * 0.04
                return box
            }
        }
        let faces = fresh.filter { $0.kind == .face }.count, lines = fresh.count - faces
        var parts: [String] = []
        if faces > 0 { parts.append(faces == 1 ? "1 face" : "\(faces) faces") }
        if lines > 0 { parts.append(lines == 1 ? "1 line of text" : "\(lines) lines of text") }
        notice = parts.isEmpty ? (found.isEmpty ? "No faces or text found" : "Everything found is already covered")
                               : "Found " + parts.joined(separator: " and ")
    }

    /// Intersection over the smaller area.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        return shared.width * shared.height / max(min(a.width * a.height, b.width * b.height), 1)
    }
}

struct RedactEditorView: View {
    @StateObject var model: RedactModel
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: RedactModel, onApply: @escaping (ParamValues) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        EditorShell(symbol: "eye.slash", title: "Redact", subtitle: model.source.url.lastPathComponent,
                    applyTitle: "Redact", canApply: !model.boxes.isEmpty,
                    onApply: { onApply(model.values) }, onCancel: onCancel,
                    onDelete: { withAnimation(reduceMotion ? nil : Theme.snappy) { model.delete() } }) {
            ChipPicker(items: [.init(value: .pixelate, label: "Pixelate", symbol: "square.grid.3x3.fill"),
                               .init(value: .blur, label: "Blur", symbol: "drop.fill"),
                               .init(value: .black, label: "Black", symbol: "rectangle.fill")],
                       selection: $model.style)
            Spacer(minLength: 0)
            Button {
                Task { await model.autoDetect(animation: reduceMotion ? Theme.ease : Theme.spring) }
            } label: {
                HStack(spacing: 6) {
                    if model.detecting {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(model.detecting ? "Detecting…" : "Auto-detect")
                }
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(model.detecting)
            .help("Find faces and text")
            ToolTray {
                ToolIconButton(symbol: "trash", help: "Remove all areas") {
                    withAnimation(reduceMotion ? nil : Theme.snappy) { model.clear() }
                }
                .disabled(model.boxes.isEmpty)
            }
        } canvas: {
            EditorCanvas(image: model.rendered, imageSize: model.source.pixelSize) { map in
                RedactOverlay(model: model, map: map)
            }
            .task(id: model.renderKey) { await model.render() }
        } status: {
            if let notice = model.notice {
                EditorStatus(symbol: "wand.and.stars", text: notice)
                    .transition(.opacity)
            } else if model.boxes.isEmpty {
                EditorStatus(symbol: "hand.draw", text: "Drag over anything you want hidden")
            } else {
                EditorStatus(symbol: "eye.slash", text: model.boxes.count == 1 ? "1 area" : "\(model.boxes.count) areas",
                             detail: model.selection == nil ? "Click an area to adjust it" : "Delete removes the selected area")
            }
        }
        .onChange(of: model.boxes.count) { if model.notice != nil, !model.detecting { model.notice = nil } }
    }
}

private struct RedactOverlay: View {
    @ObservedObject var model: RedactModel
    let map: CanvasMapping

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.boxes) { box in
                let frame = map.view(box.rect)
                RedactBoxView(kind: box.kind, delay: box.delay, selected: box.id == model.selection,
                              hover: model.hover?.id == box.id ? model.hover?.handle : nil,
                              active: model.activeHandle?.id == box.id ? model.activeHandle?.handle : nil)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.update(start: value.startLocation, location: value.location, map: map)
                    if let active = model.activeHandle { (active.handle == .move ? NSCursor.closedHand : active.handle.cursor).set() }
                }
                .onEnded { _ in
                    model.endDrag()
                    NSCursor.arrow.set()
                }
        )
        .onContinuousHover { phase in
            guard model.drag == nil else { return }
            switch phase {
            case .active(let point):
                var hover: RedactModel.Hover?
                if let box = model.selectedBox, let handle = RectHandle.hit(point, in: map.view(box.rect), reach: 9) {
                    hover = .init(id: box.id, handle: handle)
                } else if let box = model.boxes.last(where: { map.view($0.rect).contains(point) }) {
                    hover = .init(id: box.id, handle: .move)
                }
                if model.hover != hover { model.hover = hover }
                (hover.map { $0.handle.cursor } ?? (map.frame.contains(point) ? NSCursor.crosshair : NSCursor.arrow)).set()
            case .ended:
                model.hover = nil
                NSCursor.arrow.set()
            }
        }
    }
}

/// One redaction area: a fine outline, citrus with handles when selected, and a badge for detected faces and text.
private struct RedactBoxView: View {
    let kind: RedactModel.Box.Kind
    let delay: Double
    let selected: Bool
    let hover: RectHandle?
    let active: RectHandle?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(hover != nil ? 1 : 0.75)),
                                  style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 3]))
                    .shadow(color: .black.opacity(0.45), radius: 1)
                if kind != .drawn {
                    Image(systemName: kind == .face ? "face.smiling" : "textformat")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.accent))
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .position(x: 0, y: 0)
                }
                if selected {
                    let handles = min(rect.width, rect.height) > 44 ? RectHandle.corners + RectHandle.edges : RectHandle.corners
                    ForEach(handles, id: \.self) { handle in
                        HandleDot(hovered: hover == handle, active: active == handle, size: handle.isCorner ? 11 : 9)
                            .position(handle.point(in: rect))
                    }
                    .transition(.opacity)
                }
            }
        }
        // Detected boxes pop in; drawn ones are already under the pointer.
        .scaleEffect(appeared || reduceMotion || kind == .drawn ? 1 : 0.82)
        .opacity(appeared || kind == .drawn ? 1 : 0)
        .animation(Theme.ease, value: selected)
        .onAppear {
            withAnimation((reduceMotion ? Theme.ease : Theme.spring).delay(delay)) { appeared = true }
        }
    }
}
