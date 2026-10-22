import AppKit
import SwiftUI

/// Asks for an action's settings (with a live preview for image edits) before running it.
@MainActor
enum ParameterWindow {
    private static var windows: [NSWindow] = []

    static func present(action: Action, urls: [URL], apply: @escaping (ParamValues) -> Void) {
        let window = FocusablePanel()
        window.title = action.title // hidden, but used by Mission Control and VoiceOver
        let form = ParameterForm(action: action, urls: urls, values: action.defaults,
                                 onApply: { [weak window] values in
                                     window?.close()
                                     apply(values)
                                 },
                                 onCancel: { [weak window] in window?.close() })
        window.host(form)
        window.center()
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === window } }
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
        window.present()
    }
}

struct ParameterForm: View {
    let action: Action
    let urls: [URL]
    @State var values: ParamValues
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @State var preview: NSImage?
    /// Bumped per render so the preview crossfades instead of snapping.
    @State private var previewVersion = 0
    /// What's typed in number fields, so values apply on every keystroke (a formatted TextField only commits on Return).
    @State private var numberText: [String: String] = [:]
    @FocusState private var focusedField: String?
    /// The preset name being typed; nil while the naming row is closed.
    @State var presetName: String?
    /// What happened to the last Save Preset (true: saved).
    @State private var presetNote: (text: String, saved: Bool)?

    private var showsPreview: Bool { action.preview != nil && urls.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: action.symbol ?? "slider.horizontal.3",
                        title: action.mode == .convert ? "Convert to \(action.title)" : action.title,
                        subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                .padding(.horizontal, 20)
                .padding(.top, 4)

            if showsPreview {
                PreviewPane(image: preview, version: previewVersion)
                    .frame(height: 260)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

            Form {
                Section {
                    ForEach(action.parameters) { parameter in
                        row(parameter)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)

            presetRow

            HStack(spacing: 10) {
                if presetName == nil {
                    Button {
                        presetName = PresetStore.suggestedName(for: action, values: values)
                        presetNote = nil
                        DispatchQueue.main.async { focusedField = Self.presetField }
                    } label: {
                        Label("Save as Preset…", systemImage: "bookmark")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(invalidNumber != nil)
                    .help("Keep these settings as a slice of their own on the wheel")
                    .uiTestID("param.savePreset")
                }
                if action.preview != nil {
                    Button {
                        values = action.defaults
                        numberText = [:]
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(values == action.defaults)
                }
                if let invalid = invalidNumber {
                    Label("\(invalid.label): enter \(invalid.range.lowerBound.formatted())–\(invalid.range.upperBound.formatted())",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cherry)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
                // While a preset is being named, Return and Esc belong to that row.
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(presetName == nil ? .cancelAction : nil)
                    .buttonStyle(SoftButtonStyle())
                Button("Apply") { onApply(values) }
                    .keyboardShortcut(presetName == nil ? .defaultAction : nil)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(invalidNumber != nil)
            }
            .animation(Theme.snappy, value: invalidNumber?.label)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .onAppear {
            // Put the cursor in the first typed field so the value can be entered straight after the drop.
            let typed = action.parameters.first { parameter in
                switch parameter.kind {
                case .number, .text: return true
                case .slider, .choice: return false
                }
            }
            DispatchQueue.main.async { focusedField = typed?.key }
        }
        .task(id: values) {
            guard showsPreview, let render = action.preview else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let image = await render(urls[0], values)
            if !Task.isCancelled {
                preview = image
                previewVersion += 1
            }
        }
    }

    static let presetField = "preset.name"

    /// Naming a new preset, or how saving the last one went.
    @ViewBuilder
    private var presetRow: some View {
        if presetName != nil {
            HStack(spacing: 8) {
                TextField("Preset name", text: Binding(get: { presetName ?? "" }, set: { presetName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: Self.presetField)
                    .uiTestID("param.presetName")
                Button("Cancel") { presetName = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SoftButtonStyle())
                    .uiTestID("param.presetCancel")
                Button("Save Preset", action: savePreset)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
                    .uiTestID("param.presetSave")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        if let note = presetNote {
            Label(note.text, systemImage: note.saved ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(note.saved ? Theme.leafText : Theme.cherryText)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .uiTestID("param.presetNote")
        }
    }

    private func savePreset() {
        guard let name = presetName else { return }
        do {
            let preset = try PresetStore.shared.add(name: name, action: action.id, values: PresetStore.encode(values, for: action))
            presetName = nil
            presetNote = ("Saved “\(preset.name)”. It's a slice on the \(action.mode.title.lowercased()) wheel now.", true)
        } catch {
            presetNote = (error.localizedDescription, false)
        }
    }

    @ViewBuilder
    private func row(_ parameter: Parameter) -> some View {
        switch parameter.kind {
        case .slider(let range):
            LabeledContent(parameter.label) {
                HStack {
                    Slider(value: number(parameter.key), in: range)
                    Text(values.number(parameter.key), format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: values.number(parameter.key)))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        case .number(let range, let unit):
            LabeledContent(parameter.label) {
                HStack(spacing: 6) {
                    TextField("", text: numberField(parameter.key, range: range))
                        .focused($focusedField, equals: parameter.key)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text(unit).foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { values.number(parameter.key) },
                                               set: { values.storage[parameter.key] = .number($0); numberText[parameter.key] = nil }),
                            in: range)
                        .labelsHidden()
                }
            }
        case .choice(let options):
            Picker(parameter.label, selection: choice(parameter.key)) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
        case .text(let placeholder):
            TextField(parameter.label, text: text(parameter.key), prompt: Text(placeholder))
                .focused($focusedField, equals: parameter.key)
        }
    }

    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { values.number(key) }, set: { values.storage[key] = .number($0) })
    }

    /// A number field whose typed text doesn't parse or is out of range (Apply would silently use the old value).
    private var invalidNumber: (label: String, range: ClosedRange<Double>)? {
        for parameter in action.parameters {
            guard case .number(let range, _) = parameter.kind, let typed = numberText[parameter.key] else { continue }
            if parseNumber(typed).map({ !range.contains($0) }) ?? true { return (parameter.label, range) }
        }
        return nil
    }

    private func parseNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func numberField(_ key: String, range: ClosedRange<Double>) -> Binding<String> {
        Binding(
            get: { numberText[key] ?? values.number(key).formatted(.number.grouping(.never)) },
            set: { typed in
                numberText[key] = typed
                if let value = parseNumber(typed), range.contains(value) { values.storage[key] = .number(value) }
            })
    }

    private func choice(_ key: String) -> Binding<Int> {
        Binding(get: { values.choice(key) }, set: { values.storage[key] = .choice($0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { values.text(key) }, set: { values.storage[key] = .text($0) })
    }
}

/// Icon, title and file name at the top of a sheet.
struct SheetHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            GradientBadge(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The live preview: the image on a checkerboard (so transparency shows) in a recessed rounded well,
/// crossfading between renders.
private struct PreviewPane: View {
    let image: NSImage?
    let version: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(scheme == .dark ? Color.black.opacity(0.35) : Color(hex: 0xF1E9E0))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Checkerboard())
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .padding(14)
                    .id(version)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(shape.strokeBorder(Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
        .animation(.easeInOut(duration: 0.18), value: version)
    }
}
