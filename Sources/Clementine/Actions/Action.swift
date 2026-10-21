import AppKit

enum WheelMode {
    /// ⇧ while dragging: change the file's format.
    case convert
    /// ⌥⇧ while dragging: tools for that kind of file.
    case tools
}

enum ParamValue: Hashable {
    case number(Double)
    case choice(Int)
    case text(String)
}

struct ParamValues: Hashable {
    var storage: [String: ParamValue] = [:]

    func number(_ key: String) -> Double {
        if case .number(let value)? = storage[key] { return value }
        return 0
    }

    func choice(_ key: String) -> Int {
        if case .choice(let value)? = storage[key] { return value }
        return 0
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
    var parameters: [Parameter] = []
    /// Live preview for the parameter sheet (single image inputs).
    var preview: ((URL, ParamValues) async -> NSImage?)? = nil
    /// A custom editor window (crop canvas, waveform, page grid…) shown instead of the generic parameter sheet.
    /// It calls `apply` with the chosen values (complex data goes in `.text` values, e.g. JSON); the job then
    /// runs through `run` like any other, so the same action also works from the CLI with `--set`.
    var editor: Editor? = nil
    let accepts: (FileItem) -> Bool
    let run: (JobContext) async throws -> JobOutput

    var defaults: ParamValues {
        ParamValues(storage: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.initial) }))
    }
}

func kinds(_ kinds: FileKind...) -> (FileItem) -> Bool {
    { kinds.contains($0.kind) }
}

enum ActionRegistry {
    static let all: [Action] = ConvertActions.all + ToolActions.all + ConvertActions.archiveCreate

    static func find(_ id: String) -> Action? {
        all.first { $0.id == id }
    }

    /// The slices to show for these files, at most 12 so labels stay readable.
    static func actions(for urls: [URL], mode: WheelMode) -> [Action] {
        let items = urls.map(FileItem.init)
        guard !items.isEmpty else { return [] }
        let candidates = mode == .convert ? ConvertActions.all : ToolActions.all
        var result = candidates.filter { action in
            (action.minInputs...action.maxInputs).contains(items.count) && items.allSatisfy(action.accepts)
        }
        // Archiving is the fallback for files we can't otherwise convert (folders, mixed selections, unknown types).
        if mode == .convert && (result.isEmpty || items.allSatisfy({ $0.kind == .folder || $0.kind == .other })) {
            result += ConvertActions.archiveCreate
        }
        return Array(result.prefix(12))
    }
}
