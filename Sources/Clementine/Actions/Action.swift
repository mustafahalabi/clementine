import AppKit

enum WheelMode {
    /// ⇧ while dragging: change the file's format.
    case convert
    /// ⌥⇧ while dragging: tools for that kind of file.
    case tools
    /// ⌃ while dragging: things to do with the file itself (copy its path, hash it, AirDrop it…).
    case files

    /// Usage buckets and `--list` use this ("convert", "tools", "files").
    var name: String { "\(self)" }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .files: "File actions"
        }
    }

    /// The modifier keys that bring this wheel up mid-drag.
    var keys: [String] {
        switch self {
        case .convert: ["⇧"]
        case .tools: ["⌥", "⇧"]
        case .files: ["⌃"]
        }
    }

    /// The wheel the click-mode chip (and Tab) switches to.
    var next: WheelMode {
        switch self {
        case .convert: .tools
        case .tools: .files
        case .files: .convert
        }
    }
}

enum ParamValue: Hashable {
    case number(Double)
    case choice(Int)
    case text(String)
}

struct ParamValues: Hashable {
    var storage: [String: ParamValue] = [:]
    /// How many options each choice parameter has (filled in by `Action.defaults`), so `choice` can clamp.
    var choiceCounts: [String: Int] = [:]

    func number(_ key: String) -> Double {
        if case .number(let value)? = storage[key] { return value }
        return 0
    }

    /// Clamped to the parameter's options: actions index arrays with it, so a bad value must not crash a job.
    /// (The CLI rejects out-of-range values before this; it's a backstop.)
    func choice(_ key: String) -> Int {
        guard case .choice(let value)? = storage[key] else { return 0 }
        let upper = (choiceCounts[key] ?? Int.max) - 1
        return min(max(value, 0), max(upper, 0))
    }

    func text(_ key: String) -> String {
        if case .text(let value)? = storage[key] { return value }
        return ""
    }
}

/// A setting shown in the sheet before an action runs.
struct Parameter: Identifiable {
    enum Kind {
        case slider(ClosedRange<Double>)
        case number(ClosedRange<Double>, unit: String)
        case choice([String])
        case text(placeholder: String)
    }

    let key: String
    let label: String
    let kind: Kind
    let initial: ParamValue

    var id: String { key }

    static func slider(_ key: String, _ label: String, _ range: ClosedRange<Double>, default value: Double) -> Parameter {
        Parameter(key: key, label: label, kind: .slider(range), initial: .number(value))
    }

    static func number(_ key: String, _ label: String, _ range: ClosedRange<Double>, unit: String, default value: Double) -> Parameter {
        Parameter(key: key, label: label, kind: .number(range, unit: unit), initial: .number(value))
    }

    static func choice(_ key: String, _ label: String, _ options: [String], default index: Int = 0) -> Parameter {
        Parameter(key: key, label: label, kind: .choice(options), initial: .choice(index))
    }

    static func text(_ key: String, _ label: String, placeholder: String, default value: String = "") -> Parameter {
        Parameter(key: key, label: label, kind: .text(placeholder: placeholder), initial: .text(value))
    }
}

struct JobContext {
    let inputs: [URL]
    let params: ParamValues
    /// 0…1 for the current unit of work. Safe to call from any thread.
    let progress: (Double) -> Void

    var input: URL { inputs[0] }
}

enum JobOutput {
    case files([URL])
    case text(title: String, body: String)
    /// A short result with no file behind it (a path, a hash). The app copies it to the clipboard and shows it on
    /// the job card; the CLI prints it.
    case value(String)
    /// Something that happened outside Clementine (Terminal opened, AirDrop sent). The message is for the card / CLI.
    case done(String)
    /// Nothing written on purpose; the note says why (shown on the job card, printed by the CLI).
    case unchanged(String)

    static let keptOriginal = "Already as small as it gets — kept the original."

    /// Compress must never hand back a bigger file: if `output` isn't smaller than `input`, it's deleted.
    static func smaller(_ output: URL, than input: URL) -> JobOutput {
        func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        guard let new = size(output), let old = size(input), new >= old else { return .files([output]) }
        try? FileManager.default.removeItem(at: output)
        return .unchanged(keptOriginal)
    }
}

typealias Editor = @MainActor (_ urls: [URL], _ defaults: ParamValues, _ apply: @escaping (ParamValues) -> Void) -> Void

/// One slice of a wheel.
struct Action: Identifiable {
    let id: String
    let title: String
    var symbol: String? = nil
    let mode: WheelMode
    var minInputs = 1
    /// Hidden from the wheel for bigger selections (single-image editors).
    var maxInputs = Int.max
    /// Run once with every dropped file instead of once per file.
    var batch = false
    /// How many files of a multi-file drop may run at once. nil picks from the file kinds (see `BatchRunner.limit`).
    var maxConcurrent: Int? = nil
    var parameters: [Parameter] = []
    /// Live preview for the parameter sheet (single image inputs).
    var preview: ((URL, ParamValues) async -> NSImage?)? = nil
    /// A custom editor window (crop canvas, waveform, page grid…) shown instead of the generic parameter sheet.
    /// It calls `apply` with the chosen values (complex data goes in `.text` values, e.g. JSON); the job then
    /// runs through `run` like any other, so the same action also works from the CLI with `--set`.
    var editor: Editor? = nil
    /// A user's saved preset (see `Presets.swift`): the title is their name, and it runs without asking.
    var isPreset = false
    let accepts: (FileItem) -> Bool
    let run: (JobContext) async throws -> JobOutput

    var defaults: ParamValues {
        var values = ParamValues(storage: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.initial) }))
        for parameter in parameters {
            if case .choice(let options) = parameter.kind { values.choiceCounts[parameter.key] = options.count }
        }
        return values
    }
}

func kinds(_ kinds: FileKind...) -> (FileItem) -> Bool {
    { kinds.contains($0.kind) }
}

enum ActionRegistry {
    /// Slices per wheel. 13 is the most that keeps two-line labels readable (one image matches exactly 13 tools).
    static let maxSlices = 13

    static let all: [Action] = ConvertActions.all + ToolActions.all + ConvertActions.archiveCreate + FileActions.all

    static func find(_ id: String) -> Action? {
        all.first { $0.id == id } ?? PresetStore.shared.action(id: id)
    }

    /// One wheel's catalog in wheel order: each preset follows the action it's based on.
    static func catalog(_ mode: WheelMode) -> [Action] {
        let base: [Action] = switch mode {
        case .convert: ConvertActions.all
        case .tools: ToolActions.all
        case .files: FileActions.all
        }
        let presets = PresetStore.shared.actions()
        guard !presets.isEmpty else { return base }
        return base.flatMap { action in [action] + presets.filter { $0.basedOn == action.id }.map(\.action) }
    }

    /// The slices to show for these files: visible candidates, most used first, at most `maxSlices`.
    static func actions(for urls: [URL], mode: WheelMode) -> [Action] {
        let hidden = HiddenActions.ids
        let visible = candidates(for: urls, mode: mode).filter { !hidden.contains($0.id) }
        let arranged = ActionUsage.arrange(visible, bucket: ActionUsage.bucket(for: urls.map(FileItem.init), mode: mode))
        return Array(arranged.prefix(maxSlices))
    }

    /// Every action that applies to these files, in catalog order, hidden ones included.
    static func candidates(for urls: [URL], mode: WheelMode) -> [Action] {
        let items = urls.map(FileItem.init)
        guard !items.isEmpty else { return [] }
        var result = catalog(mode).filter { action in
            (action.minInputs...action.maxInputs).contains(items.count) && items.allSatisfy(action.accepts)
        }
        // Archiving is the fallback for files we can't otherwise convert (folders, mixed selections, unknown types).
        if mode == .convert && (result.isEmpty || items.allSatisfy({ $0.kind == .folder || $0.kind == .other })) {
            result += ConvertActions.archiveCreate
        }
        return result
    }
}
