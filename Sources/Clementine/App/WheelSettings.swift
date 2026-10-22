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

        func actions(_ mode: WheelMode) -> [Action] {
            guard !samples.isEmpty else { return mode == .convert ? ConvertActions.archiveCreate : [] }
            let items = samples.map { FileItem(url: URL(fileURLWithPath: "/clementine-sample/file.\($0)")) }
            return (mode == .convert ? ConvertActions.all : ToolActions.all).filter { action in
                items.contains(where: action.accepts)
            }
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
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refresh(replay: true) }
        .onChange(of: group) { refresh(replay: true) }
        .onChange(of: mode) { refresh(replay: true) }
        .onChange(of: prefs.hidden) { refresh(replay: false) }
        .onChange(of: prefs.ordersByUsage) { refresh(replay: false) }
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
            Label("No \(mode == .convert ? "conversions" : "tools") for \(group.title.lowercased())", systemImage: "nosign")
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
                if mode == .tools, let symbol = action.symbol {
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
