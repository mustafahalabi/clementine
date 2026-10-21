import AppKit
import PDFKit
import SwiftUI

/// The page grid behind Pages and Merge: thumbnails to drag into a new order, rotate, duplicate and delete.
/// Apply turns the arrangement into a page spec (`3r90, 1-2`, or `2:1-3, 1:2` when merging) for the action's
/// `pages` value, so the job itself runs exactly as it would from the CLI.
@MainActor
enum PageOrganizer {
    private static var windows: [NSWindow] = []

    /// The editor for the action `pdfID` (Pages or Merge).
    nonisolated static func editor(for pdfID: String) -> Editor {
        { @MainActor urls, defaults, apply in
            guard let action = ActionRegistry.find(pdfID) else { return }
            // Pages on several files at once can't share one arrangement, so those keep the typed page list.
            if !action.batch && urls.count > 1 {
                ParameterWindow.present(action: action, urls: urls, apply: apply)
                return
            }
            let model: PageOrganizerModel
            do {
                model = try PageOrganizerModel(urls: urls, merging: action.batch)
            } catch {
                // Let the job open the file again and report why it can't (locked, damaged…) on its progress card.
                var values = defaults
                values.storage["pages"] = .text(action.batch ? "" : "-")
                apply(values)
                return
            }
            show(model, title: action.title, symbol: action.symbol ?? "doc.on.doc") { spec in
                var values = defaults
                values.storage["pages"] = .text(spec)
                apply(values)
            }
        }
    }

    private static func show(_ model: PageOrganizerModel, title: String, symbol: String, apply: @escaping (String) -> Void) {
        let window = FocusablePanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640), resizable: true)
        window.title = title
        window.minSize = NSSize(width: 560, height: 460)
        window.isMovableByWindowBackground = false // dragging belongs to the pages
        let view = PageOrganizerView(model: model, title: title, symbol: symbol,
                                     onApply: { [weak window] spec in
                                         window?.close()
                                         apply(spec)
                                     },
                                     onCancel: { [weak window] in window?.close() })
        window.host(view, sizing: [.minSize])
        window.center()
        windows.append(window)
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window) { break }
            windows.removeAll { $0 === window }
        }
        window.present()
    }
}

// MARK: Model

@MainActor
final class PageOrganizerModel: ObservableObject {
    struct Source {
        let url: URL
        /// Each page's size as displayed (crop box, with the page's own rotation applied).
        let sizes: [CGSize]
    }

    struct Tile: Identifiable, Hashable {
        let id = UUID()
        let file: Int
        let page: Int
        /// Extra clockwise quarter turns. Not wrapped, so rotating keeps spinning the same way.
        var turns = 0

        var rotation: Int { ((turns % 4) + 4) % 4 * 90 }
    }

    struct PageKey: Hashable {
        let file: Int
        let page: Int
    }

    let sources: [Source]
    let merging: Bool
    @Published private(set) var tiles: [Tile]
    @Published var selection: Set<Tile.ID> = []
    @Published private(set) var thumbnails: [PageKey: NSImage] = [:]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private let original: [Tile]
    private var anchor: Tile.ID?
    private var undoStack: [[Tile]] = []
    private var redoStack: [[Tile]] = []

    init(urls: [URL], merging: Bool) throws {
        sources = try urls.map { url in
            let document = try PDFEngine.open(url)
            let sizes = (0..<document.pageCount).map { index -> CGSize in
                guard let page = document.page(at: index) else { return CGSize(width: 612, height: 792) }
                let box = page.bounds(for: .cropBox)
                return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
            }
            return Source(url: url, sizes: sizes)
        }
        self.merging = merging
        original = sources.enumerated().flatMap { file, source in source.sizes.indices.map { Tile(file: file, page: $0) } }
        tiles = original
    }

    var spec: String {
        PDFEngine.spec(for: tiles.map { PDFEngine.PageRef(file: $0.file, page: $0.page, rotation: $0.rotation) }, qualified: merging)
    }

    var isUnchanged: Bool { tiles == original }

    func size(of tile: Tile) -> CGSize { sources[tile.file].sizes[tile.page] }

    /// Selected tiles in grid order.
    var selectedTiles: [Tile] { tiles.filter { selection.contains($0.id) } }

    // MARK: Selection

    /// Click selects one page, ⌘-click toggles, ⇧-click extends from the last clicked page.
    func select(_ id: Tile.ID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor, let from = tiles.firstIndex(where: { $0.id == anchor }),
           let to = tiles.firstIndex(where: { $0.id == id }) {
            let range = Set(tiles[min(from, to)...max(from, to)].map(\.id))
            selection = modifiers.contains(.command) ? selection.union(range) : range
            return
        }
        if modifiers.contains(.command) {
            if selection.remove(id) == nil { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchor = id
    }

    func selectAll() { selection = Set(tiles.map(\.id)) }

    // MARK: Editing

    func rotate(clockwise: Bool) {
        guard !selection.isEmpty else { return }
        record()
        for index in tiles.indices where selection.contains(tiles[index].id) { tiles[index].turns += clockwise ? 1 : -1 }
    }

    /// Puts a copy right after each selected page and selects the copies.
    func duplicate() {
        guard !selection.isEmpty else { return }
        record()
        var result: [Tile] = []
        var copies: Set<Tile.ID> = []
        for tile in tiles {
            result.append(tile)
            if selection.contains(tile.id) {
                let copy = Tile(file: tile.file, page: tile.page, turns: tile.turns)
                result.append(copy)
                copies.insert(copy.id)
            }
        }
        tiles = result
        selection = copies
    }

    func delete() {
        guard !selection.isEmpty else { return }
        record()
        tiles.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Moves `ids` together as a block so it starts at `index` (counted without them).
    func move(_ ids: [Tile.ID], to index: Int) {
        let moving = tiles.filter { ids.contains($0.id) }
        var rest = tiles.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: min(max(index, 0), rest.count))
        if rest != tiles { tiles = rest }
    }

    func revert() {
        guard !isUnchanged else { return }
        record()
        tiles = original
        selection = []
    }

    // MARK: Undo

    /// Saves the arrangement before a change (or `previous`, the one a finished drag started from).
    func record(_ previous: [Tile]? = nil) {
        undoStack.append(previous ?? tiles)
        redoStack = []
        syncUndo()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(tiles)
        tiles = previous
        selection = selection.filter { id in tiles.contains { $0.id == id } }
        syncUndo()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(tiles)
        tiles = next
        selection = selection.filter { id in tiles.contains { $0.id == id } }
        syncUndo()
    }

    private func syncUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Thumbnails

    /// Renders every page off the main thread, publishing them in small batches so the grid fills in smoothly.
    func loadThumbnails() async {
        let files = sources.map(\.url)
        let stream = AsyncStream<(PageKey, CGImage)> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                for (file, url) in files.enumerated() {
                    guard let document = PDFDocument(url: url) else { continue }
                    for index in 0..<document.pageCount {
                        guard !Task.isCancelled else { break }
                        if let page = document.page(at: index), let image = Self.thumbnail(page) {
                            continuation.yield((PageKey(file: file, page: index), image))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var pending: [PageKey: NSImage] = [:]
        var flushed = Date()
        for await (key, image) in stream {
            pending[key] = NSImage(cgImage: image, size: .zero)
            if pending.count >= 12 || Date().timeIntervalSince(flushed) > 0.08 {
                thumbnails.merge(pending) { $1 }
                pending = [:]
                flushed = Date()
            }
        }
        thumbnails.merge(pending) { $1 }
    }

    nonisolated private static func thumbnail(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let quarterTurn = page.rotation % 180 != 0
        let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = 360 / max(size.width, size.height)
        let image = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: Layout

/// Where each tile sits: a centered grid of fixed-size cells, so reflow is plain arithmetic.
private struct PageGridLayout {
    let width: CGFloat
    let tile: CGFloat
    let spacing: CGFloat = 22
    let inset: CGFloat = 22

    var pageHeight: CGFloat { (tile * 1.3).rounded() }
    var cellHeight: CGFloat { pageHeight + 30 }
    var columns: Int { max(1, Int((width - 2 * inset + spacing) / (tile + spacing))) }
    private var originX: CGFloat { max(inset, (width - CGFloat(columns) * (tile + spacing) + spacing) / 2) }

    func rows(_ count: Int) -> Int { (count + columns - 1) / columns }

    func height(_ count: Int) -> CGFloat {
        2 * inset + CGFloat(rows(count)) * (cellHeight + spacing) - spacing
    }

    func rowTop(_ row: Int) -> CGFloat { inset + CGFloat(row) * (cellHeight + spacing) }

    func center(_ index: Int) -> CGPoint {
        CGPoint(x: originX + CGFloat(index % columns) * (tile + spacing) + tile / 2,
                y: rowTop(index / columns) + cellHeight / 2)
    }

    /// The slot under `point`, for dropping.
    func slot(at point: CGPoint, count: Int) -> Int {
        let column = min(max(Int((point.x - originX + spacing / 2) / (tile + spacing)), 0), columns - 1)
        let row = max(Int((point.y - inset + spacing / 2) / (cellHeight + spacing)), 0)
        return min(row * columns + column, max(count - 1, 0))
    }
}

// MARK: Views

struct PageOrganizerView: View {
    @ObservedObject var model: PageOrganizerModel
    let title: String
    let symbol: String
    let onApply: (String) -> Void
    let onCancel: () -> Void
    /// Previews only: shows the selection mid-drag, grabbed at this point in the grid.
    var previewDrag: CGPoint?

    @AppStorage("pageOrganizerZoom") private var zoom = 128.0
    @State private var drag: DragState?
    @State private var scrollTop: CGFloat = 0
    @State private var autoScroll: Task<Void, Never>?
    /// -1 while a drag hovers the top edge, 1 the bottom edge.
    @State private var edge = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DragState {
        var ids: [PageOrganizerModel.Tile.ID]
        var primary: PageOrganizerModel.Tile.ID
        /// Pointer in grid coordinates, and where on the tile it grabbed.
        var location: CGPoint
        var grab: CGSize
        var viewportY: CGFloat
        /// The arrangement before the drag, for undo.
        var before: [PageOrganizerModel.Tile]
    }

    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.14) : Theme.spring }

    private var subtitle: String {
        let names = model.sources.map(\.url.lastPathComponent)
        return names.count == 1 ? names[0] : "\(names.count) PDFs"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                SheetHeader(symbol: symbol, title: title, subtitle: subtitle)
                PageCountPill(count: model.tiles.count)
            }
            .padding(.top, 4)

            if model.merging { legend }
            toolbar
            grid
            footer
        }
        .padding([.horizontal, .bottom], 20)
        .frame(minWidth: 520, minHeight: 420)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .background(shortcuts)
        .task { await model.loadThumbnails() }
        .onAppear {
            guard let point = previewDrag, let first = model.selectedTiles.first else { return }
            drag = DragState(ids: model.selectedTiles.map(\.id), primary: first.id, location: point, grab: .zero,
                             viewportY: point.y, before: model.tiles)
        }
    }

    // MARK: Parts

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sources.indices, id: \.self) { file in
                    HStack(spacing: 6) {
                        FileMark(file: file, size: 16)
                        Text(model.sources[file].url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Text("\(model.sources[file].sizes.count)p")
                            .foregroundStyle(Theme.secondaryText(scheme))
                            .monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.card(scheme)))
                    .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1))
                }
            }
        }
    }

    private var toolbar: some View {
        let none = model.selection.isEmpty
        return HStack(spacing: 4) {
            Button { withAnimation(motion) { model.rotate(clockwise: false) } } label: { Image(systemName: "rotate.left") }
                .help("Rotate left (⌘L)")
                .keyboardShortcut("l", modifiers: .command)
                .disabled(none)
            Button { withAnimation(motion) { model.rotate(clockwise: true) } } label: { Image(systemName: "rotate.right") }
                .help("Rotate right (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(none)
            Button { withAnimation(motion) { model.duplicate() } } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate (⌘D)")
                .keyboardShortcut("d", modifiers: .command)
                .disabled(none)
            Button { withAnimation(motion) { model.delete() } } label: { Image(systemName: "trash") }
                .buttonStyle(ToolIconButtonStyle(destructive: true))
                .help("Delete (⌫)")
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(none)

            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText(scheme))
                .contentTransition(.numericText())
                .animation(Theme.snappy, value: status)
                .padding(.leading, 8)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 10))
                Slider(value: $zoom, in: 84...220)
                    .controlSize(.small)
                    .frame(width: 110)
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 13))
            }
            .foregroundStyle(Theme.secondaryText(scheme))
            .help("Thumbnail size")
        }
        .buttonStyle(ToolIconButtonStyle())
        .padding(.horizontal, 6)
        .frame(height: 38)
        .card(radius: 11)
    }

    private var status: String {
        let count = model.selection.count
        if count == 0 { return model.tiles.isEmpty ? "No pages" : "Click to select, drag to reorder" }
        return count == 1 ? "1 page selected" : "\(count) pages selected"
    }

    private var grid: some View {
        let well = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return GeometryReader { viewport in
            let layout = PageGridLayout(width: viewport.size.width, tile: zoom.rounded())
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        // Clicking the gaps clears the selection.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(Theme.snappy) { model.selection = [] } }
                        ForEach(0..<layout.rows(model.tiles.count), id: \.self) { row in
                            Color.clear.frame(width: 1, height: 1).id(row).padding(.top, layout.rowTop(row))
                        }
                        ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
                            tileView(tile, index: index, layout: layout)
                        }
                    }
                    .frame(width: viewport.size.width, height: max(layout.height(model.tiles.count), viewport.size.height))
                    .coordinateSpace(name: "pages")
                    .background(GeometryReader { content in
                        Color.clear.preference(key: ScrollTopKey.self, value: content.frame(in: .named("viewport")).minY)
                    })
                }
                .coordinateSpace(name: "viewport")
                .onPreferenceChange(ScrollTopKey.self) { top in scrolled(to: top, layout: layout) }
                .onChange(of: drag?.viewportY) { _, y in
                    let zone = y.map { $0 < 44 ? -1 : $0 > viewport.size.height - 44 ? 1 : 0 } ?? 0
                    if zone != edge { edge = zone; edgeScroll(layout: layout, scroller: scroller) }
                }
            }
            .overlay { if model.tiles.isEmpty { emptyState } }
        }
        .background(well.fill(scheme == .dark ? Color.black.opacity(0.3) : Color(hex: 0xF1E9E0)))
        .clipShape(well)
        .overlay(well.strokeBorder(Theme.edge(scheme), lineWidth: 1))
        .frame(maxHeight: .infinity)
        .animation(motion, value: zoom)
    }

    private func tileView(_ tile: PageOrganizerModel.Tile, index: Int, layout: PageGridLayout) -> some View {
        let dragged = drag?.ids.firstIndex(of: tile.id)
        let primary = drag?.primary == tile.id
        var position = layout.center(index)
        var fan = 0.0
        if let drag, let dragged {
            // The grabbed page follows the pointer; the rest of the selection stacks up underneath it.
            let lead = CGPoint(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
            let rank = CGFloat(primary ? 0 : min(dragged + 1, 3))
            position = CGPoint(x: lead.x + rank * 4, y: lead.y + rank * 3)
            fan = reduceMotion ? 0 : Double(rank) * 3.5
        }
        return PageTileView(model: model, tile: tile, number: index + 1, size: CGSize(width: layout.tile, height: layout.pageHeight),
                            selected: model.selection.contains(tile.id) && (dragged == nil || primary), lifted: dragged != nil,
                            stackCount: primary ? drag?.ids.count ?? 1 : 1)
            .frame(width: layout.tile, height: layout.cellHeight)
            .rotationEffect(.degrees(fan))
            .position(position)
            .zIndex(primary ? 1000 : dragged != nil ? 999 - Double(dragged!) : 0)
            .animation(primary ? .interactiveSpring(response: 0.18, dampingFraction: 0.86) : motion, value: position)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            .onTapGesture {
                let modifiers = NSEvent.modifierFlags
                withAnimation(Theme.snappy) { model.select(tile.id, modifiers: modifiers) }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("pages"))
                    .onChanged { value in dragChanged(tile, value: value, layout: layout) }
                    .onEnded { _ in
                        autoScroll?.cancel()
                        edge = 0
                        if let before = drag?.before, before != model.tiles { model.record(before) }
                        withAnimation(motion) { drag = nil }
                    }
            )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("No pages left").font(.system(size: 14, weight: .semibold))
            Button("Undo") { withAnimation(motion) { model.undo() } }
                .buttonStyle(SoftButtonStyle())
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(motion) { model.revert() }
            } label: {
                Label("Revert", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(model.isUnchanged)

            if !model.tiles.isEmpty {
                Text(model.spec)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The page list this applies, as used by the command line")
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SoftButtonStyle())
            Button("Apply") { onApply(model.spec) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AccentButtonStyle())
                .disabled(model.tiles.isEmpty)
        }
    }

    /// Menu-less shortcuts: select all, undo, redo.
    private var shortcuts: some View {
        ZStack {
            Button("") { withAnimation(Theme.snappy) { model.selectAll() } }.keyboardShortcut("a", modifiers: .command)
            Button("") { withAnimation(motion) { model.undo() } }.keyboardShortcut("z", modifiers: .command)
            Button("") { withAnimation(motion) { model.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Dragging

    private func dragChanged(_ tile: PageOrganizerModel.Tile, value: DragGesture.Value, layout: PageGridLayout) {
        if drag == nil {
            guard let index = model.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
            if !model.selection.contains(tile.id) {
                withAnimation(Theme.snappy) { model.select(tile.id, modifiers: []) }
            }
            let start = layout.center(index)
            withAnimation(Theme.snappy) {
                drag = DragState(ids: model.selectedTiles.map(\.id), primary: tile.id, location: value.startLocation,
                                 grab: CGSize(width: value.startLocation.x - start.x, height: value.startLocation.y - start.y),
                                 viewportY: value.startLocation.y + scrollTop, before: model.tiles)
            }
        }
        drag?.location = value.location
        drag?.viewportY = value.location.y + scrollTop
        reflow(layout: layout)
    }

    /// Slides the dragged block to the slot under the pointer; everything else springs aside.
    private func reflow(layout: PageGridLayout) {
        guard let drag else { return }
        let lead = CGPoint(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
        let target = min(layout.slot(at: lead, count: model.tiles.count), model.tiles.count - drag.ids.count)
        withAnimation(motion) { model.move(drag.ids, to: target) }
    }

    /// Keeps the dragged page under the pointer while the grid scrolls beneath it.
    private func scrolled(to top: CGFloat, layout: PageGridLayout) {
        let delta = scrollTop - top
        scrollTop = top
        guard drag != nil, delta != 0 else { return }
        drag?.location.y += delta
        reflow(layout: layout)
    }

    /// Holding a page near the top or bottom edge scrolls a row at a time.
    private func edgeScroll(layout: PageGridLayout, scroller: ScrollViewProxy) {
        autoScroll?.cancel()
        guard edge != 0 else { return }
        let step = edge
        autoScroll = Task { @MainActor in
            while !Task.isCancelled {
                let current = Int((-scrollTop + layout.inset) / (layout.cellHeight + layout.spacing))
                let row = min(max(current + step, 0), max(layout.rows(model.tiles.count) - 1, 0))
                withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(row, anchor: .top) }
                try? await Task.sleep(nanoseconds: 380_000_000)
            }
        }
    }
}

private struct ScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One page: its thumbnail fitted and rotated in a fixed box, with the page number underneath.
private struct PageTileView: View {
    @ObservedObject var model: PageOrganizerModel
    let tile: PageOrganizerModel.Tile
    let number: Int
    /// The box the page fits into.
    let size: CGSize
    let selected: Bool
    let lifted: Bool
    /// Pages travelling together in a drag, shown on the grabbed one.
    let stackCount: Int
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let page = model.size(of: tile)
        let quarter = tile.turns % 2 != 0
        let shown = quarter ? CGSize(width: page.height, height: page.width) : page
        let scale = min(size.width / max(shown.width, 1), size.height / max(shown.height, 1))
        let drawn = CGSize(width: page.width * scale, height: page.height * scale)
        let outline = CGSize(width: shown.width * scale, height: shown.height * scale)
        let image = model.thumbnails[.init(file: tile.file, page: tile.page)]

        VStack(spacing: 8) {
            ZStack {
                sheet(image)
                    .frame(width: drawn.width, height: drawn.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .rotationEffect(.degrees(Double(tile.turns) * 90))
                    .frame(width: outline.width, height: outline.height)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.edge(scheme), lineWidth: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                            .padding(-5)
                            .opacity(selected ? 1 : 0)
                            .scaleEffect(selected ? 1 : 1.06)
                    }
                    .overlay(alignment: .topTrailing) { cornerMark }
                    .shadow(color: .black.opacity(lifted ? 0.28 : hovering ? 0.2 : 0.13),
                            radius: lifted ? 16 : hovering ? 8 : 4, y: lifted ? 10 : hovering ? 4 : 2)
                    .shadow(color: selected ? Theme.glow.opacity(0.5) : .clear, radius: 8)
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(reduceMotion ? 1 : lifted ? 1.05 : hovering ? 1.02 : 1)

            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : Theme.secondaryText(scheme))
                .padding(.horizontal, 8)
                .frame(minWidth: 22, minHeight: 18)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.07))))
                .contentTransition(.numericText(value: Double(number)))
                .opacity(lifted ? 0 : 1)
        }
        .overlay(alignment: .topLeading) {
            if stackCount > 1 {
                Text("\(stackCount)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.glow, radius: 4)
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: selected)
        .animation(Theme.snappy, value: hovering)
        .animation(reduceMotion ? Theme.ease : Theme.spring, value: lifted)
        .animation(reduceMotion ? Theme.ease : Theme.spring, value: number)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func sheet(_ image: NSImage?) -> some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .transition(.opacity)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: size.width * 0.18, weight: .ultraLight))
                    .foregroundStyle(Color(hex: 0xC9B8A6))
            }
        }
        .animation(Theme.ease, value: image != nil)
    }

    /// Merging: which file the page comes from. Pages: the original page number once a page has moved.
    @ViewBuilder
    private var cornerMark: some View {
        if model.merging {
            FileMark(file: tile.file, size: 18).offset(x: 6, y: -6)
        } else if tile.page + 1 != number {
            Text("p.\(tile.page + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Capsule().fill(Color(hex: 0x3A2E26).opacity(0.78)))
                .offset(x: 6, y: -6)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// A lettered citrus dot that tells merged files apart.
private struct FileMark: View {
    let file: Int
    var size: CGFloat = 16

    static let colors: [UInt32] = [0xFF9A3C, 0x34C77B, 0xF2607A, 0xE8B92E, 0x8E7CF0, 0x3FB6D9]

    var body: some View {
        Text(String(UnicodeScalar(UInt8(65 + file % 26))))
            .font(.system(size: size * 0.58, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: Self.colors[file % Self.colors.count])))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

/// The live page count beside the title.
private struct PageCountPill: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.on.doc.fill").font(.system(size: 10))
            Text("\(count)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
            Text(count == 1 ? "page" : "pages")
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.secondaryText(scheme))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .animation(Theme.snappy, value: count)
    }
}

/// Square icon buttons for the organizer toolbar.
private struct ToolIconButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, destructive: destructive)
    }

    private struct IconButton: View {
        let configuration: Configuration
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering && enabled && destructive ? AnyShapeStyle(Theme.cherry) : AnyShapeStyle(Color.primary.opacity(0.8)))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.32)
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: configuration.isPressed)
                .animation(Theme.ease, value: hovering)
                .animation(Theme.ease, value: enabled)
        }
    }
}
