import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The wheels as Settings shows them: one group per kind of file, with every action that can appear for it.
enum WheelCatalog {
    struct Group: Identifiable, Hashable {
        /// Matches `FileKind` names, which are also the usage buckets.
        let kind: String
        let title: String
        let symbol: String
        /// Representative extensions: an action belongs to the group if it accepts any of them.
        let samples: [String]

        var id: String { kind }

        /// Includes the user's presets, each after the action it's based on.
        func actions(_ mode: WheelMode) -> [Action] {
            if samples.isEmpty && mode == .convert { return ConvertActions.archiveCreate }
            // Folders: any real folder will do (FileItem looks at the disk to tell).
            let items = samples.isEmpty
                ? [FileItem(url: FileManager.default.temporaryDirectory)]
                : samples.map { FileItem(url: URL(fileURLWithPath: "/clementine-sample/file.\($0)")) }
            return ActionRegistry.catalog(mode).filter { action in items.contains(where: action.accepts) }
        }

        var icon: NSImage {
            let type = samples.first.flatMap { UTType(filenameExtension: $0) } ?? .folder
            return NSWorkspace.shared.icon(for: type)
        }
    }

    static let groups: [Group] = [
        Group(kind: "image", title: "Images", symbol: "photo", samples: ["png", "jpg", "heic", "gif"]),
        Group(kind: "video", title: "Video", symbol: "film", samples: ["mp4", "mov"]),
        Group(kind: "audio", title: "Audio", symbol: "waveform", samples: ["wav", "mp3"]),
        Group(kind: "pdf", title: "PDF", symbol: "doc.richtext", samples: ["pdf"]),
        Group(kind: "document", title: "Docs", symbol: "doc.text", samples: ["txt", "docx"]),
        Group(kind: "subtitle", title: "Subtitles", symbol: "captions.bubble", samples: ["srt", "vtt"]),
        Group(kind: "archive", title: "Archives", symbol: "archivebox", samples: ["zip", "tar", "gz"]),
        Group(kind: "folder", title: "Folders", symbol: "folder", samples: []),
    ]
}

/// Hidden slices and usage ordering, observable for Settings and saved straight to UserDefaults.
@MainActor
final class WheelPrefs: ObservableObject {
    @Published var hidden = HiddenActions.ids {
        didSet { HiddenActions.ids = hidden }
    }
    @Published var ordersByUsage = ActionUsage.ordersByUsage {
        didSet { ActionUsage.ordersByUsage = ordersByUsage }
    }

    var isDefault: Bool { hidden.isEmpty && ordersByUsage }

    func setShown(_ shown: Bool, _ id: String) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
    }

    func reset() {
        hidden = []
        ordersByUsage = true
        ActionUsage.reset()
    }
}

/// Settings › Wheel: pick a kind of file, switch slices on and off, and watch the wheel change beside them.
struct WheelSettingsView: View {
    @StateObject private var prefs = WheelPrefs()
    @StateObject private var preview = WheelModel()
    @State private var group: WheelCatalog.Group
    @State private var mode: WheelMode
    @StateObject private var presets = PresetsModel()
    @Environment(\.colorScheme) private var scheme

    init(kind: String = "image", mode: WheelMode = .convert) {
        _group = State(initialValue: WheelCatalog.groups.first { $0.kind == kind } ?? WheelCatalog.groups[0])
        _mode = State(initialValue: mode)
    }

    private var actions: [Action] { group.actions(mode) }

    /// What the wheel will show: visible slices, ordered by usage, capped like the real thing.
    private var shown: [Action] {
        let visible = actions.filter { !prefs.hidden.contains($0.id) }
        return Array(ActionUsage.arrange(visible, bucket: ActionUsage.bucket(kind: group.kind, mode: mode)).prefix(ActionRegistry.maxSlices))
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    KindPicker(selection: $group)
                    HStack(alignment: .top, spacing: 10) {
                        miniWheel
                        VStack(alignment: .leading, spacing: 10) {
                        Picker("Wheel", selection: $mode) {
                            Text("Convert ⇧").tag(WheelMode.convert)
                            Text("Tools ⌥⇧").tag(WheelMode.tools)
                            Text("Files ⌃").tag(WheelMode.files)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        toggles
                        }
                    }
                    .frame(height: 226, alignment: .top)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Slices")
            } footer: {
                Text("Hidden slices stay off the wheel but can still run from the command line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PresetsSection(model: presets, prefs: prefs)

            Section {
                Toggle(isOn: $prefs.ordersByUsage) {
                    Text("Most used first")
                    Text("Order each wheel by how often and how recently you use its slices")
                }
                LabeledContent {
                    Button("Reset to Defaults") { withAnimation(Theme.spring) { prefs.reset() } }
                        .buttonStyle(SoftButtonStyle())
                        .controlSize(.small)
                        .disabled(prefs.isDefault && ActionUsage.scores(bucket: ActionUsage.bucket(kind: group.kind, mode: mode)).isEmpty)
                } label: {
                    Text("Reset")
                    Text("Show every slice and forget usage")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { refresh(replay: true) }
        .onChange(of: group) { refresh(replay: true) }
        .onChange(of: mode) { refresh(replay: true) }
        .onChange(of: prefs.hidden) { refresh(replay: false) }
        .onChange(of: prefs.ordersByUsage) { refresh(replay: false) }
        .onChange(of: presets.version) { refresh(replay: false) }
    }

    /// The real wheel, scaled down so the ring and its mode chip fill the space.
    private var miniWheel: some View {
        let side: CGFloat = 188
        let span = preview.outerRadius * 2 + 58
        return WheelView(model: preview)
            .scaleEffect(side / span)
            .frame(width: side, height: side)
            .offset(y: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var toggles: some View {
        if actions.isEmpty {
            Label("No \(Self.noun(mode)) for \(group.title.lowercased())", systemImage: "nosign")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText(scheme))
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            let onWheel = self.shown
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(actions) { action in
                    let shownIndex = onWheel.firstIndex { $0.id == action.id }
                    SliceToggle(action: action, mode: mode, isOn: Binding(
                        get: { !prefs.hidden.contains(action.id) },
                        set: { on in withAnimation(Theme.snappy) { prefs.setShown(on, action.id) } }))
                    .onHover { inside in
                        // Point at the slice in the preview.
                        withAnimation(Theme.snappy) { preview.hovered = inside ? shownIndex : nil }
                    }
                }
            }
        }
    }

    private static func noun(_ mode: WheelMode) -> String {
        switch mode {
        case .convert: "conversions"
        case .tools: "tools"
        case .files: "file actions"
        }
    }

    private func refresh(replay: Bool) {
        withAnimation(Theme.spring) {
            preview.preview(actions: shown, mode: mode, icon: group.icon, summary: group.title, replay: replay)
        }
    }
}

/// A row of kinds of file, the selected one lit with the accent.
private struct KindPicker: View {
    @Binding var selection: WheelCatalog.Group
    @Namespace private var lens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WheelCatalog.groups) { group in
                let selected = group == selection
                Button { withAnimation(Theme.spring) { selection = group } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: group.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(height: 16)
                        Text(group.title)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Color.white : Theme.secondaryText(scheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.accent)
                                .shadow(color: Theme.glow, radius: 5, y: 2)
                                .matchedGeometryEffect(id: "lens", in: lens)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// One slice as a switchable chip: lit when it's on the wheel, dimmed with a hollow dot when hidden.
private struct SliceToggle: View {
    let action: Action
    let mode: WheelMode
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 5) {
                if mode != .convert || action.isPreset, let symbol = action.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 14)
                }
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.7)
            }
        }
        .toggleStyle(Chip(hovering: hovering))
        .onHover { hovering = $0 }
        .help(isOn ? "Hide \(action.title) from the wheel" : "Show \(action.title) on the wheel")
    }

    private struct Chip: ToggleStyle {
        let hovering: Bool
        @Environment(\.colorScheme) private var scheme

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            return Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().strokeBorder(configuration.isOn ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.2)
                        Circle().fill(Theme.accent).opacity(configuration.isOn ? 1 : 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .opacity(configuration.isOn ? 1 : 0)
                    }
                    .frame(width: 14, height: 14)
                    configuration.label
                        .foregroundStyle(configuration.isOn ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(shape.fill(configuration.isOn ? Theme.card(scheme) : Color.primary.opacity(hovering ? 0.06 : 0.03)))
                .overlay(shape.strokeBorder(configuration.isOn ? Theme.tangerine.opacity(hovering ? 0.6 : 0.3) : Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
                .opacity(configuration.isOn ? 1 : 0.75)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .animation(Theme.ease, value: hovering)
            .accessibilityValue(configuration.isOn ? "Shown" : "Hidden")
        }
    }
}

// MARK: - Presets

/// The presets as Settings shows them, refreshed whenever they change (here, in a sheet, or from the CLI).
@MainActor
final class PresetsModel: ObservableObject {
    @Published private(set) var snapshot = PresetStore.shared.snapshot
    /// Bumped on every reload so the preview wheel can follow.
    @Published private(set) var version = 0
    @Published var error: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: PresetStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Picks up `--save-preset` from a terminal when Settings comes back to the front.
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func reload() {
        snapshot = PresetStore.shared.snapshot
        version += 1
    }

    func perform(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    /// "Resize · 25%": the action and its saved values, for the row under each name.
    static func summary(_ preset: Preset) -> String {
        let base = ActionRegistry.all.first { $0.id == preset.action }
        let title = base.map { $0.mode == .convert ? "Convert to \($0.title)" : $0.title } ?? preset.action
        let values = (base?.parameters ?? []).compactMap { parameter -> String? in
            guard let value = preset.values[parameter.key], !value.isEmpty else { return nil }
            if case .number(_, let unit) = parameter.kind { return "\(value) \(unit)" }
            if case .text = parameter.kind { return "\(parameter.label): \(value)" }
            return value
        }
        return ([title] + values).joined(separator: " · ")
    }
}

/// Settings › Wheel › Presets: rename, reorder, hide and delete. Presets are made from a tool's settings sheet
/// (Save as Preset…) or with `--save-preset`.
private struct PresetsSection: View {
    @ObservedObject var model: PresetsModel
    @ObservedObject var prefs: WheelPrefs
    @State private var drafts: [String: String] = [:]
    @FocusState private var focused: String?
    @Environment(\.colorScheme) private var scheme

    private var count: Int { model.snapshot.presets.count }

    var body: some View {
        Section {
            if count == 0 {
                Label("No presets yet. In a tool's settings, choose Save as Preset… and it becomes a slice of its own.",
                      systemImage: "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText(scheme))
            } else {
                rows
            }
            if let error = model.error ?? model.snapshot.readError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.cherryText)
            }
        } header: {
            Text("Presets")
        }
        .onChange(of: focused) { previous, _ in
            if let previous { commit(previous) } // leaving a name field saves it, like Return
        }
    }

    @ViewBuilder
    private var rows: some View {
        let list = VStack(spacing: 6) {
            ForEach(Array(model.snapshot.presets.enumerated()), id: \.element.id) { index, preset in
                row(preset, index: index)
            }
        }
        if count > 4 {
            ScrollView { list.padding(.vertical, 2) }.frame(height: 4 * 44)
        } else {
            list
        }
    }

    private func row(_ preset: Preset, index: Int) -> some View {
        let valid = model.snapshot.valid.first { $0.preset.id == preset.id }
        let problem = model.snapshot.problems.first { $0.preset.id == preset.id }
        let shown = !prefs.hidden.contains(preset.id)
        return HStack(spacing: 8) {
            Image(systemName: problem != nil ? "exclamationmark.triangle.fill" : valid?.action.symbol ?? "bookmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(problem != nil ? AnyShapeStyle(Theme.cherryText) : AnyShapeStyle(Theme.accent))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                // Only typing makes a draft: when the field loses focus, SwiftUI writes its pre-commit text back
                // through the binding after `commit` ran, which would bring the old name back as a draft.
                TextField("Name", text: Binding(get: { drafts[preset.id] ?? preset.name },
                                                set: { if focused == preset.id { drafts[preset.id] = $0 } }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.system(size: 12.5, weight: .medium))
                    .focused($focused, equals: preset.id)
                    .onSubmit { commit(preset.id) }
                    .uiTestID("presets.name.\(preset.id)")
                Text(problem.map { "Skipped: \($0.reason)" } ?? PresetsModel.summary(preset))
                    .font(.system(size: 10.5))
                    .foregroundStyle(problem != nil ? AnyShapeStyle(Theme.cherryText) : AnyShapeStyle(Theme.secondaryText(scheme)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if problem == nil {
                Button { withAnimation(Theme.snappy) { prefs.setShown(!shown, preset.id) } } label: {
                    Image(systemName: shown ? "eye" : "eye.slash")
                }
                .help(shown ? "Hide from the wheel" : "Show on the wheel")
                .accessibilityLabel(shown ? "Hide \(preset.name) from the wheel" : "Show \(preset.name) on the wheel")
                .uiTestID("presets.shown.\(preset.id)")
            }
            Button { move(preset.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move \(preset.name) up")
                .uiTestID("presets.up.\(preset.id)")
            Button { move(preset.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1)
                .help("Move down")
                .accessibilityLabel("Move \(preset.name) down")
                .uiTestID("presets.down.\(preset.id)")
            Button { withAnimation(Theme.snappy) { model.perform { try PresetStore.shared.delete(preset.id) } } } label: {
                Image(systemName: "trash")
            }
            .help("Delete preset")
            .accessibilityLabel("Delete \(preset.name)")
            .uiTestID("presets.delete.\(preset.id)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .opacity(shown || problem != nil ? 1 : 0.6)
        .frame(minHeight: 38)
    }

    private func move(_ id: String, by offset: Int) {
        withAnimation(Theme.snappy) { model.perform { try PresetStore.shared.move(id, by: offset) } }
    }

    /// Saves a changed name; a rejected one (empty, taken) snaps back and says why.
    private func commit(_ id: String) {
        guard let draft = drafts.removeValue(forKey: id),
              let preset = model.snapshot.presets.first(where: { $0.id == id }), draft != preset.name else { return }
        model.perform { try PresetStore.shared.rename(id, to: draft) }
    }
}
