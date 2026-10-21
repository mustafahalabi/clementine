import AppKit
import SwiftUI

/// Annotate: arrows, shapes, pen, highlighter and text, with undo. Produces `shapes` JSON for `ImageEdits.annotate`;
/// the canvas draws the marks with the same code that renders the final image.
@MainActor
enum AnnotateEditor {
    static func present(_ urls: [URL], _ defaults: ParamValues, _ apply: @escaping (ParamValues) -> Void) {
        ImageEditorWindow.present(urls[0], title: "Annotate", apply: apply) { image, finish in
            AnnotateEditorView(model: AnnotateModel(source: image), onApply: { finish($0) }, onCancel: { finish(nil) })
        }
    }
}

@MainActor
final class AnnotateModel: ObservableObject {
    typealias Annotation = ImageEdits.Annotation

    enum Tool: CaseIterable {
        case select, arrow, rectangle, ellipse, pen, highlighter, text

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .pen: return "scribble"
            case .highlighter: return "highlighter"
            case .text: return "textformat"
            }
        }

        var name: String {
            switch self {
            case .select: return "Select"
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .text: return "Text"
            }
        }

        var hint: String {
            switch self {
            case .select: return "Click a mark to select it, drag to move it"
            case .text: return "Click where the text should go"
            case .pen, .highlighter: return "Drag to draw"
            default: return "Drag to draw \(self == .arrow ? "an arrow" : "a shape")"
            }
        }

        var kind: Annotation.Kind? {
            switch self {
            case .select: return nil
            case .arrow: return .arrow
            case .rectangle: return .rectangle
            case .ellipse: return .ellipse
            case .pen: return .pen
            case .highlighter: return .highlighter
            case .text: return .text
            }
        }
    }

    /// The citrus palette, then the classics.
    static let swatches: [(name: String, hex: String)] = [
        ("Tangerine", "#FF9A3C"), ("Blood orange", "#FF5E3A"), ("Lemon", "#FFD43B"), ("Peach", "#FFD3A8"),
        ("Red", "#E5484D"), ("Blue", "#0A84FF"), ("Green", "#34C77B"), ("Black", "#141414"), ("White", "#FFFFFF"),
    ]
    /// Stroke widths as a fraction of the image's long edge.
    static let weights: [Double] = [0.0028, 0.0055, 0.011]

    /// Text being typed at `origin` (image pixels); `editing` is the text mark being changed, hidden meanwhile.
    struct Typing: Equatable {
        var origin: CGPoint
        var text = ""
        var editing: UUID?
    }

    let source: EditorImage
    let preview: NSImage
    @Published var items: [Annotation] = []
    @Published private(set) var draft: Annotation?
    @Published var selection: UUID?
    @Published var hover: UUID?
    @Published var tool = Tool.arrow
    @Published private(set) var color = "#FF5E3A"
    @Published private(set) var weight = 1
    @Published var typing: Typing?
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []
    private var move: (id: UUID, from: Annotation, before: [Annotation])?
    private var gestureHandled = false
    /// The current click only finished typing, so it shouldn't start anything else.
    private var gestureCommitted = false

    init(source: EditorImage) {
        self.source = source
        preview = ImageEngine.nsImage(source.preview)
    }

    var values: ParamValues { ParamValues(storage: ["shapes": .text(ImageEdits.encode(items))]) }

    var strokeWidth: Double {
        (max(source.pixelSize.width, source.pixelSize.height) * Self.weights[weight]).rounded().clamped(2, 400)
    }

    var fontSize: Double { (strokeWidth * 5.5).rounded().clamped(12, 2000) }

    /// What the canvas draws: the marks (minus one being retyped) plus the one being drawn.
    var visible: [Annotation] {
        items.filter { $0.id != typing?.editing } + (draft.map { [$0] } ?? [])
    }

    var selected: Annotation? { items.first { $0.id == selection } }

    // MARK: Undoable changes

    private func change(_ body: () -> Void) {
        undoStack.append(items)
        redoStack.removeAll()
        body()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        if selected == nil { selection = nil }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        if selected == nil { selection = nil }
    }

    func delete() {
        guard let selection else { return }
        change { items.removeAll { $0.id == selection } }
        self.selection = nil
    }

    func setColor(_ hex: String) {
        color = hex
        if let index = items.firstIndex(where: { $0.id == selection }), items[index].color != hex {
            change { items[index].color = hex }
        }
    }

    func setWeight(_ weight: Int) {
        self.weight = weight
        if let index = items.firstIndex(where: { $0.id == selection }) {
            let width = items[index].kind == .text ? fontSize : strokeWidth
            if items[index].width != width { change { items[index].width = width } }
        }
    }

    func setTool(_ tool: Tool) {
        commitTyping()
        self.tool = tool
        if tool != .select { selection = nil }
    }

    // MARK: Text

    func commitTyping() {
        guard let typing else { return }
        self.typing = nil
        let text = typing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = typing.editing, let index = items.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                change { items.remove(at: index) }
            } else if items[index].text != text {
                change { items[index].text = text }
            }
        } else if !text.isEmpty {
            change { items.append(Annotation(kind: .text, points: [typing.origin], color: color, width: fontSize, text: text)) }
        }
    }

    // MARK: Pointer

    /// The topmost mark under a view point.
    func hit(_ point: CGPoint, map: CanvasMapping) -> Annotation? {
        let target = map.image(point)
        return items.last { ImageEdits.hitTest($0, target, tolerance: 6 / map.scale) }
    }

    func update(start: CGPoint, location: CGPoint, map: CanvasMapping) {
        let startPoint = map.image(start), point = map.clampedImage(location)
        if draft == nil && move == nil && !gestureHandled {
            gestureHandled = true
            if typing != nil {
                commitTyping()
                gestureCommitted = true
                return
            }
            switch tool {
            case .select:
                selection = hit(start, map: map)?.id
                if let selected { move = (selected.id, selected, items) }
            case .text:
                break // placed when the click ends
            default:
                guard map.frame.contains(start), let kind = tool.kind else { return }
                draft = Annotation(kind: kind, points: [startPoint], color: color, width: strokeWidth)
            }
        }
        if let move, let index = items.firstIndex(where: { $0.id == move.id }) {
            items[index] = move.from.moved(by: CGSize(width: (location.x - start.x) / map.scale, height: (location.y - start.y) / map.scale))
        } else if var draft {
            switch draft.kind {
            case .pen, .highlighter:
                if let last = draft.points.last, hypot(point.x - last.x, point.y - last.y) * map.scale >= 1.5 { draft.points.append(point) }
            default:
                draft.points = [draft.points[0], point]
            }
            self.draft = draft
        }
    }

    func endDrag(start: CGPoint, location: CGPoint, map: CanvasMapping) {
        defer {
            gestureHandled = false
            gestureCommitted = false
        }
        let moved = hypot(location.x - start.x, location.y - start.y)
        if let move {
            self.move = nil
            if moved >= 1 {
                // Record the move as one undo step from where it started.
                undoStack.append(move.before)
                redoStack.removeAll()
            }
            return
        }
        if let draft {
            self.draft = nil
            let small = [.arrow, .rectangle, .ellipse].contains(draft.kind) && moved < 4
            if !small { change { items.append(draft) } }
            return
        }
        if tool == .text, !gestureCommitted, typing == nil, map.frame.contains(start), moved < 4 {
            if let mark = hit(start, map: map), mark.kind == .text {
                typing = Typing(origin: mark.points[0], text: mark.text ?? "", editing: mark.id)
            } else {
                // Center the first line's height on the click.
                typing = Typing(origin: CGPoint(x: map.image(start).x, y: map.image(start).y - fontSize * 0.6))
            }
        }
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

struct AnnotateEditorView: View {
    @StateObject var model: AnnotateModel
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AnnotateModel, onApply: @escaping (ParamValues) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        let typing = model.typing != nil
        EditorShell(symbol: "pencil.tip.crop.circle", title: "Annotate", subtitle: model.source.url.lastPathComponent,
                    applyTitle: "Save", canApply: !model.items.isEmpty || typing, capturesKeys: !typing,
                    onApply: {
                        model.commitTyping()
                        onApply(model.values)
                    },
                    onCancel: onCancel,
                    onDelete: { withAnimation(reduceMotion ? nil : Theme.snappy) { model.delete() } }) {
            ChipPicker(items: AnnotateModel.Tool.allCases.map { .init(value: $0, symbol: $0.symbol, help: $0.name) },
                       selection: Binding(get: { model.tool }, set: { model.setTool($0) }))
            SwatchPicker(selection: Binding(get: { model.color }, set: { model.setColor($0) }))
            ChipPicker(items: [CGFloat(4), 7, 11].enumerated().map { .init(value: $0.offset, dot: $0.element,
                                                                            help: ["Thin", "Medium", "Thick"][$0.offset]) },
                       selection: Binding(get: { model.weight }, set: { model.setWeight($0) }))
            Spacer(minLength: 0)
            ToolTray {
                ToolIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                    .keyboardShortcut(typing ? nil : KeyboardShortcut("z", modifiers: .command))
                    .disabled(model.undoStack.isEmpty)
                ToolIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }
                    .keyboardShortcut(typing ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))
                    .disabled(model.redoStack.isEmpty)
            }
        } canvas: {
            EditorCanvas(image: model.preview, imageSize: model.source.pixelSize) { map in
                AnnotateOverlay(model: model, map: map)
            }
        } status: {
            EditorStatus(symbol: model.tool.symbol, text: model.tool.hint,
                         detail: model.items.isEmpty ? nil : (model.items.count == 1 ? "· 1 mark" : "· \(model.items.count) marks"))
        }
    }
}

private struct AnnotateOverlay: View {
    @ObservedObject var model: AnnotateModel
    let map: CanvasMapping

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let marks = model.visible
                context.withCGContext { cg in
                    cg.translateBy(x: map.frame.minX, y: map.frame.minY)
                    cg.scaleBy(x: map.scale, y: map.scale)
                    cg.clip(to: map.imageBounds)
                    ImageEdits.draw(marks, in: cg)
                }
            }
            .allowsHitTesting(false)

            if model.tool == .select, let id = model.hover, id != model.selection, let mark = model.items.first(where: { $0.id == id }) {
                outline(mark, selected: false)
            }
            if let mark = model.selected {
                outline(mark, selected: true)
                    .transition(.opacity)
            }
            if let typing = model.typing {
                TypingField(model: model, typing: typing, map: map)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .animation(Theme.ease, value: model.selection)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.update(start: value.startLocation, location: value.location, map: map)
                }
                .onEnded { value in
                    model.endDrag(start: value.startLocation, location: value.location, map: map)
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let over = model.tool == .select ? model.hit(point, map: map)?.id : nil
                if model.hover != over { model.hover = over }
                let cursor: NSCursor = switch model.tool {
                case .select: over == nil ? .arrow : .openHand
                case .text: .iBeam
                default: map.frame.contains(point) ? .crosshair : .arrow
                }
                cursor.set()
            case .ended:
                model.hover = nil
                NSCursor.arrow.set()
            }
        }
    }

    /// A dashed citrus frame around the selected mark, a faint one around a hovered mark.
    private func outline(_ mark: ImageEdits.Annotation, selected: Bool) -> some View {
        let frame = map.view(ImageEdits.bounds(mark)).insetBy(dx: -6, dy: -6)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(selected ? AnyShapeStyle(Theme.tangerine) : AnyShapeStyle(Color.white.opacity(0.85)),
                    style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [5, 3]))
            .shadow(color: .black.opacity(0.4), radius: 1)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }
}

/// The text box shown while typing a text mark, styled like the result.
private struct TypingField: View {
    @ObservedObject var model: AnnotateModel
    let typing: AnnotateModel.Typing
    let map: CanvasMapping
    @FocusState private var focused: Bool

    var body: some View {
        let origin = map.view(typing.origin)
        let size = max((typing.editing.flatMap { id in model.items.first { $0.id == id }?.width } ?? model.fontSize) * map.scale, 9)
        TextField("Text", text: Binding(get: { model.typing?.text ?? "" }, set: { model.typing?.text = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(Color(cgColor: ImageEdits.color(hex: model.color) ?? .white))
            .fixedSize()
            .frame(minWidth: 60, alignment: .leading)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.tangerine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .offset(x: origin.x - 4, y: origin.y)
            .focused($focused)
            .onSubmit { model.commitTyping() }
            .onExitCommand { model.typing = nil }
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// Color dots in a tray; the chosen one gets a ring.
private struct SwatchPicker: View {
    @Binding var selection: String
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ToolTray {
            ForEach(AnnotateModel.swatches, id: \.hex) { swatch in
                let chosen = swatch.hex == selection
                Button {
                    withAnimation(Theme.snappy) { selection = swatch.hex }
                } label: {
                    Circle()
                        .fill(Color(cgColor: ImageEdits.color(hex: swatch.hex) ?? .white))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.25 : 0.15), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Theme.tangerine, lineWidth: 2).opacity(chosen ? 1 : 0))
                        .scaleEffect(hovered == swatch.hex && !chosen ? 1.12 : 1)
                        .frame(width: 24, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .onHover { inside in withAnimation(Theme.snappy) { hovered = inside ? swatch.hex : (hovered == swatch.hex ? nil : hovered) } }
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}
