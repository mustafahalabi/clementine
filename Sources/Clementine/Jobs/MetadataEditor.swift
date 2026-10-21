import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Edits the common metadata of one image, audio/video file or PDF. Save hands the changed fields to the
/// action as JSON (`fields`), so the copy is written by the same code the CLI uses.
/// Several files at once just show their metadata, as before.
@MainActor
enum MetadataEditor {
    private static var windows: [NSWindow] = []

    static func present(urls: [URL], defaults: ParamValues, apply: @escaping (ParamValues) -> Void) {
        guard urls.count == 1, MetadataEngine.Kind(urls[0]) != nil else { return apply(defaults) }
        let model = MetadataEditorModel(url: urls[0])
        let window = FocusablePanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700), resizable: true)
        window.title = "Metadata"
        window.minSize = NSSize(width: 460, height: 460)
        let view = MetadataEditorView(model: model,
                                      onSave: { [weak window] json in
                                          window?.close()
                                          var values = defaults
                                          values.storage["fields"] = .text(json)
                                          apply(values)
                                      },
                                      onCancel: { [weak window] in window?.close() },
                                      onFailure: { [weak window] in
                                          // Unreadable: the plain metadata job reports why on its progress card.
                                          window?.close()
                                          apply(defaults)
                                      })
        window.contentView = NSHostingView(rootView: view)
        window.center()
        windows.append(window)
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window) { break }
            windows.removeAll { $0 === window }
        }
        window.present()
    }
}

@MainActor
final class MetadataEditorModel: ObservableObject {
    let url: URL
    let kind: MetadataEngine.Kind
    let fields: [MetadataEngine.Field]
    /// False for image formats that can't be rewritten losslessly: the editor then only shows what's there.
    let writable: Bool
    @Published private(set) var snapshot: MetadataEngine.Snapshot?
    @Published var values: [String: String] = [:]
    @Published var removeLocation = false
    @Published private(set) var preview: NSImage?

    init(url: URL) {
        self.url = url
        kind = MetadataEngine.Kind(url) ?? .image
        fields = MetadataEngine.fields(for: kind)
        writable = MetadataEngine.canWrite(url)
    }

    convenience init(url: URL, snapshot: MetadataEngine.Snapshot, preview: NSImage? = nil) {
        self.init(url: url)
        self.snapshot = snapshot
        values = snapshot.values
        self.preview = preview
    }

    func load() async throws {
        let snapshot = try await MetadataEngine.read(url)
        self.snapshot = snapshot
        values = snapshot.values
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2,
                                                   representationTypes: .thumbnail)
        preview = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.values[key] ?? "" }, set: { self.values[key] = $0 })
    }

    private func clean(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func isChanged(_ key: String) -> Bool {
        guard let snapshot else { return false }
        let new = clean(values[key]), old = clean(snapshot.values[key])
        if fields.first(where: { $0.key == key })?.style == .date, let a = MetadataEngine.exifDate(new), let b = MetadataEngine.exifDate(old) {
            return a != b
        }
        return new != old
    }

    var changedKeys: [String] { fields.map(\.key).filter(isChanged) }

    var changeCount: Int { changedKeys.count + (removeLocation ? 1 : 0) }

    func problem(_ field: MetadataEngine.Field) -> String? {
        isChanged(field.key) ? MetadataEngine.problem(with: values[field.key] ?? "", for: field) : nil
    }

    var firstProblem: String? { fields.lazy.compactMap(problem).first }

    /// The edits for the action: changed fields only, plus the location switch.
    var json: String {
        var edits: [String: Any] = [:]
        for key in changedKeys { edits[key] = clean(values[key]) }
        if removeLocation { edits[MetadataEngine.removeLocationKey] = true }
        let data = (try? JSONSerialization.data(withJSONObject: edits, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func revert() {
        values = snapshot?.values ?? [:]
        removeLocation = false
    }
}

// MARK: Views

struct MetadataEditorView: View {
    @ObservedObject var model: MetadataEditorModel
    let onSave: (String) -> Void
    let onCancel: () -> Void
    var onFailure: () -> Void = {}
    /// Starts with the raw dump open (for previews).
    @State var showsAll = false
    @Environment(\.colorScheme) private var scheme

    private var symbol: String {
        switch model.kind {
        case .image: "photo"
        case .media: FileItem(url: model.url).kind == .video ? "film" : "music.note"
        case .pdf: "doc.richtext"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: symbol, title: "Metadata", subtitle: model.url.lastPathComponent)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            if let snapshot = model.snapshot {
                form(snapshot)
                    .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText(scheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            footer
                .padding([.horizontal, .bottom], 20)
                .padding(.top, 4)
        }
        .frame(minWidth: 440, minHeight: 420)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .animation(Theme.spring, value: model.snapshot == nil)
        .task {
            guard model.snapshot == nil else { return }
            do { try await model.load() } catch { onFailure() }
        }
    }

    private func form(_ snapshot: MetadataEngine.Snapshot) -> some View {
        Form {
            if !snapshot.facts.isEmpty || model.preview != nil {
                Section { summary(snapshot) }
            }
            if !model.writable {
                Section {
                    Label(MetadataEngine.readOnlyReason(model.url), systemImage: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
            }
            Group {
                Section("Details") {
                    ForEach(model.fields) { field in
                        row(field)
                    }
                }
                if let location = snapshot.location {
                    Section("Location") { locationRow(location, coordinate: snapshot.coordinate) }
                }
            }
            .disabled(!model.writable)
            Section {
                DisclosureGroup(isExpanded: $showsAll.animation(Theme.spring)) {
                    ScrollView {
                        Text(snapshot.dump.isEmpty ? "No other metadata." : snapshot.dump)
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .frame(height: 200)
                } label: {
                    Label("All metadata", systemImage: "list.bullet.rectangle")
                        .labelStyle(TintedIconLabelStyle())
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Thumbnail and read-only facts (camera, lens, size, length…).
    private func summary(_ snapshot: MetadataEngine.Snapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(snapshot.facts, id: \.label) { fact in
                    GridRow {
                        Text(fact.label)
                            .foregroundStyle(Theme.secondaryText(scheme))
                        Text(fact.value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText(scheme).opacity(0.6))
                .help("Read-only")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(_ field: MetadataEngine.Field) -> some View {
        let changed = model.isChanged(field.key)
        let problem = model.problem(field)
        let label = FieldLabel(text: field.label, changed: changed)
        VStack(alignment: .leading, spacing: 4) {
            switch field.style {
            case .rating:
                LabeledContent { StarRating(value: ratingBinding(field.key)) } label: { label }
            case .keywords:
                LabeledContent { KeywordsField(text: model.binding(field.key), placeholder: field.placeholder) } label: { label }
            case .multiline:
                TextField(text: model.binding(field.key), prompt: Text(field.placeholder), axis: .vertical) { label }
                    .lineLimit(1...4)
            case .date, .year, .track:
                TextField(text: model.binding(field.key), prompt: Text(field.placeholder)) { label }
                    .monospacedDigit()
            case .text:
                TextField(text: model.binding(field.key), prompt: Text(field.placeholder)) { label }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.cherry)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.snappy, value: problem)
    }

    private func ratingBinding(_ key: String) -> Binding<Int> {
        Binding(get: { Int(model.values[key] ?? "") ?? 0 },
                set: { model.values[key] = $0 == 0 ? "" : "\($0)" })
    }

    private func locationRow(_ location: String, coordinate: (latitude: Double, longitude: Double)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.removeLocation ? "location.slash.fill" : "mappin.and.ellipse")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.removeLocation ? AnyShapeStyle(Theme.secondaryText(scheme)) : AnyShapeStyle(Theme.accent))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
                Text(location)
                    .font(.system(size: 12.5, design: .monospaced))
                    .strikethrough(model.removeLocation, color: Theme.cherry)
                    .opacity(model.removeLocation ? 0.5 : 1)
                    .textSelection(.enabled)
                Spacer()
                if let coordinate, !model.removeLocation,
                   let maps = URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)") {
                    Button { NSWorkspace.shared.open(maps) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help("Show in Maps")
                        .transition(.opacity)
                }
            }
            Toggle(isOn: $model.removeLocation.animation(Theme.snappy)) {
                FieldLabel(text: "Remove location", changed: model.removeLocation)
            }
            .toggleStyle(.switch)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.snappy) { model.revert() }
            } label: {
                Label("Revert", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(model.changeCount == 0)

            Group {
                if model.firstProblem != nil {
                    Label("Fix the highlighted field", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.cherry)
                } else if model.changeCount > 0 {
                    Text(model.changeCount == 1 ? "1 change" : "\(model.changeCount) changes")
                        .foregroundStyle(Theme.tangerine)
                        .contentTransition(.numericText(value: Double(model.changeCount)))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .transition(.opacity.combined(with: .move(edge: .leading)))

            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SoftButtonStyle())
            Button("Save Copy") { onSave(model.json) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(AccentButtonStyle())
                .disabled(model.changeCount == 0 || model.firstProblem != nil)
                .help("Saves an “(edited)” copy next to the original")
        }
        .animation(Theme.snappy, value: model.changeCount)
        .animation(Theme.snappy, value: model.firstProblem)
    }
}

/// A field name with a citrus dot once it's been changed.
private struct FieldLabel: View {
    let text: String
    let changed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .scaleEffect(changed ? 1 : 0.2)
                .opacity(changed ? 1 : 0)
                .animation(Theme.snappy, value: changed)
        }
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.tangerine)
            configuration.title
        }
    }
}

/// Five stars; hovering previews, clicking sets, clicking the current rating clears it.
private struct StarRating: View {
    @Binding var value: Int
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = hovered ?? value
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= shown ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(star <= shown ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.secondaryText(scheme).opacity(0.45)))
                    .scaleEffect(hovered == star && !reduceMotion ? 1.18 : 1)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? star : (hovered == star ? nil : hovered) }
                    .onTapGesture { value = value == star ? 0 : star }
            }
        }
        .animation(Theme.snappy, value: shown)
        .animation(Theme.snappy, value: hovered)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(value == 0 ? "None" : "\(value) of 5 stars")
        .accessibilityAdjustableAction { direction in
            value = direction == .increment ? min(value + 1, 5) : max(value - 1, 0)
        }
    }
}

/// Keywords as removable chips, typed into a trailing field (Return or comma adds one).
/// Backed by the comma-separated text the engine expects.
private struct KeywordsField: View {
    @Binding var text: String
    let placeholder: String
    @State private var draft = ""

    private var words: [String] { MetadataEngine.keywords(text) }

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(words, id: \.self) { word in
                KeywordChip(word: word) {
                    withAnimation(Theme.snappy) { text = words.filter { $0 != word }.joined(separator: ", ") }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            TextField("", text: $draft, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 90, minHeight: 20)
                .fixedSize()
                .onSubmit(commit)
                .onChange(of: draft) { _, new in if new.contains(",") { commit() } }
        }
        .frame(maxWidth: 280, alignment: .trailing)
    }

    private func commit() {
        let added = MetadataEngine.keywords(draft).filter { !words.contains($0) }
        draft = ""
        guard !added.isEmpty else { return }
        withAnimation(Theme.snappy) { text = (words + added).joined(separator: ", ") }
    }
}

private struct KeywordChip: View {
    let word: String
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            Text(word).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0)))
            }
            .buttonStyle(.plain)
            .help("Remove “\(word)”")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 20)
        .background(Capsule().fill(Theme.tangerine.opacity(scheme == .dark ? 0.22 : 0.14)))
        .overlay(Capsule().strokeBorder(Theme.tangerine.opacity(0.35), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(Theme.ease, value: hovering)
    }
}

/// Lays children out left to right, wrapping onto new lines; lines hug the trailing edge.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
