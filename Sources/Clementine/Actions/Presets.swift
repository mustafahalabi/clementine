import Foundation

/// A saved set of settings for one action, shown on the wheel as its own slice ("Under 10 MB") that runs without
/// asking. Stored in `presets.json` in the support folder.
struct Preset: Codable, Hashable, Identifiable {
    /// `preset.` plus random hex: stays put when the preset is renamed, so hiding and usage follow it.
    var id: String
    var name: String
    /// The action it runs.
    var action: String
    /// Values as `--set` takes them (choices by label), so the file stays readable and survives reordered options.
    var values: [String: String]
}

/// A preset that passed validation, as a wheel slice.
struct PresetSlice {
    let preset: Preset
    let action: Action
    var basedOn: String { preset.action }
}

/// Reads, validates and edits the presets. Safe from any thread; the file is re-read when it changes on disk
/// (say, after `--save-preset` in a terminal while the app runs).
final class PresetStore: @unchecked Sendable {
    static let shared = PresetStore()
    /// Posted on the main queue after the app changes the presets.
    static let didChange = Notification.Name("ClementinePresetsDidChange")
    static let maxNameLength = 60
    /// Where problems found on load are reported, once per change of the file. The CLI prints them instead.
    nonisolated(unsafe) static var warn: (String) -> Void = { NSLog("Clementine: %@", $0) }

    struct Problem {
        let preset: Preset
        let reason: String
    }

    struct Snapshot {
        var presets: [Preset] = []
        var valid: [PresetSlice] = []
        var problems: [Problem] = []
        /// The file exists but isn't valid JSON. Saving moves it aside first rather than losing it.
        var readError: String?
    }

    /// Computed each time so `CLEMENTINE_SUPPORT_DIR` (tests) is honoured even if set after launch.
    var file: URL { Prefs.supportDirectory.appendingPathComponent("presets.json") }

    private let lock = NSLock()
    private var cache: (path: String, stamp: Date?, snapshot: Snapshot)?

    var snapshot: Snapshot {
        let file = file
        let stamp = Self.stamp(of: file)
        return lock.withLock {
            if let cache, cache.path == file.path, cache.stamp == stamp { return cache.snapshot }
            let snapshot = Self.read(file)
            cache = (file.path, stamp, snapshot)
            for problem in snapshot.problems { Self.warn("skipped preset “\(problem.preset.name)”: \(problem.reason)") }
            if let error = snapshot.readError { Self.warn(error) }
            return snapshot
        }
    }

    var presets: [Preset] { snapshot.presets }

    /// Valid presets in the user's order.
    func actions() -> [PresetSlice] { snapshot.valid }

    func action(id: String) -> Action? {
        snapshot.valid.first { $0.preset.id == id }?.action
    }

    /// By name (any case) or id.
    func find(_ nameOrID: String) -> Preset? {
        let key = nameOrID.trimmingCharacters(in: .whitespaces).lowercased()
        return presets.first { $0.id.lowercased() == key || $0.name.lowercased() == key }
    }

    // MARK: Validation

    /// Rebuilds the preset's action: the base action's run, with the saved values checked against its parameters.
    static func validate(_ preset: Preset) -> Result<Action, ClementineError> {
        guard preset.id.hasPrefix("preset."), preset.id.count > 7 else {
            return .failure(.message("its id \"\(preset.id)\" doesn't start with \"preset.\""))
        }
        if let problem = nameProblem(preset.name) { return .failure(.message(problem)) }
        guard let base = ActionRegistry.all.first(where: { $0.id == preset.action }) else {
            return .failure(.message("there's no action \(preset.action)"))
        }
        guard !base.parameters.isEmpty else {
            return .failure(.message("\(base.id) has no settings to save"))
        }
        var values = base.defaults
        for key in preset.values.keys.sorted() {
            let raw = preset.values[key]!
            guard let parameter = base.parameters.first(where: { $0.key == key }) else {
                return .failure(.message("\(base.id) has no setting \"\(key)\""))
            }
            switch checked(raw, for: parameter) {
            case .success(let value): values.storage[key] = value
            case .failure(let problem): return .failure(.message("\(key)=\(raw): \(problem.message)"))
            }
        }
        let saved = values
        return .success(Action(
            id: preset.id, title: preset.name, symbol: base.symbol ?? "bookmark.fill", mode: base.mode,
            minInputs: base.minInputs, maxInputs: base.maxInputs, batch: base.batch, maxConcurrent: base.maxConcurrent,
            isPreset: true, accepts: base.accepts,
            run: { ctx in try await base.run(JobContext(inputs: ctx.inputs, params: saved, progress: ctx.progress)) }))
    }

    /// Like `--set`, and stricter: typed numbers must be inside their range too (a preset is checked once, when
    /// it's saved or loaded, rather than failing each time it runs).
    static func checked(_ raw: String, for parameter: Parameter) -> Result<ParamValue, CLI.InvalidValue> {
        let parsed = CLI.parse(raw, for: parameter)
        if case .success(.number(let value)) = parsed, case .number(let range, let unit) = parameter.kind, !range.contains(value) {
            return .failure(CLI.InvalidValue(message: "must be between \(format(range.lowerBound)) and \(format(range.upperBound)) \(unit)"))
        }
        return parsed
    }

    static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "the name is empty" }
        if trimmed != name || name.contains(where: \.isNewline) { return "the name has extra spaces or line breaks" }
        if name.count > maxNameLength { return "the name is longer than \(maxNameLength) characters" }
        return nil
    }

    /// Values in the stored form: choices by label, numbers without a trailing ".0".
    static func encode(_ values: ParamValues, for action: Action) -> [String: String] {
        var result: [String: String] = [:]
        for parameter in action.parameters {
            switch parameter.kind {
            case .choice(let options): result[parameter.key] = options[values.choice(parameter.key)]
            case .slider, .number: result[parameter.key] = format(values.number(parameter.key))
            case .text: result[parameter.key] = values.text(parameter.key)
            }
        }
        return result
    }

    /// The name Save as Preset… offers: the action and what was picked (typed text left out), cut down until it
    /// fits a slice's two-line caption, e.g. "Compress · Smallest", or "10 MB" for Target Size.
    @MainActor
    static func suggestedName(for action: Action, values: ParamValues) -> String {
        let parts = action.parameters.compactMap { parameter -> String? in
            switch parameter.kind {
            case .choice(let options): return options[values.choice(parameter.key)]
            case .number(_, let unit): return "\(format(values.number(parameter.key))) \(unit)"
            case .slider: return "\(parameter.label) \(format(values.number(parameter.key)))"
            case .text: return nil
            }
        }
        let title = action.title
        func name(_ pieces: [String]) -> String { pieces.joined(separator: " · ") }
        let candidates = [name([title] + parts), name(parts), name([title] + parts.prefix(1)), name(Array(parts.prefix(1)))]
            .filter { !$0.isEmpty }
        let best = candidates.first(where: SliceCaption.fits) ?? candidates.first ?? title
        return String(best.prefix(maxNameLength))
    }

    /// Not localized: the file and the CLI use plain "0.05", whatever the Mac's region.
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: Editing

    /// Adds a preset after checking its name and values; returns it.
    @discardableResult
    func add(name: String, action: String, values: [String: String]) throws -> Preset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(id: "preset." + UUID().uuidString.lowercased().prefix(8), name: name, action: action, values: values)
        try update { presets in
            try Self.checkUnique(name, among: presets)
            if case .failure(let problem) = Self.validate(preset) { throw problem }
            presets.append(preset)
        }
        return preset
    }

    func rename(_ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.nameProblem(name) { throw ClementineError.message("Can't rename: \(problem).") }
        try update { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw Self.missing(id) }
            try Self.checkUnique(name, among: presets.filter { $0.id != id })
            presets[index].name = name
        }
    }

    func delete(_ id: String) throws {
        try update { presets in
            guard presets.contains(where: { $0.id == id }) else { throw Self.missing(id) }
            presets.removeAll { $0.id == id }
        }
        HiddenActions.ids.remove(id)
    }

    /// Moves a preset up (negative) or down among the others; the wheel shows presets in this order.
    func move(_ id: String, by offset: Int) throws {
        try update { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw Self.missing(id) }
            let target = min(max(index + offset, 0), presets.count - 1)
            presets.insert(presets.remove(at: index), at: target)
        }
    }

    private static func missing(_ id: String) -> ClementineError { .message("There's no preset \(id).") }

    private static func checkUnique(_ name: String, among presets: [Preset]) throws {
        if let problem = nameProblem(name) { throw ClementineError.message("Can't save the preset: \(problem).") }
        if presets.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw ClementineError.message("There's already a preset called “\(name)”.")
        }
    }

    private func update(_ change: (inout [Preset]) throws -> Void) throws {
        let file = file
        try lock.withLock {
            let current = Self.read(file)
            var presets = current.presets
            try change(&presets)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if current.readError != nil {
                // Keep the unreadable file for the user rather than writing over it.
                let aside = file.deletingLastPathComponent()
                    .appendingPathComponent("presets (unreadable \(Int(Date().timeIntervalSince1970))).json")
                try? FileManager.default.moveItem(at: file, to: aside)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Stored(presets: presets)).write(to: file, options: .atomic)
            cache = nil
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    // MARK: File

    private struct Stored: Codable {
        var version = 1
        var presets: [Preset]
    }

    private static func stamp(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func read(_ file: URL) -> Snapshot {
        var snapshot = Snapshot()
        guard let data = try? Data(contentsOf: file) else { return snapshot } // no file yet: no presets
        do {
            snapshot.presets = try JSONDecoder().decode(Stored.self, from: data).presets
        } catch {
            snapshot.readError = "\(file.lastPathComponent) can't be read, so no presets were loaded (\(error.localizedDescription))"
            return snapshot
        }
        var ids = Set<String>(), names = Set<String>()
        for preset in snapshot.presets {
            if !ids.insert(preset.id).inserted {
                snapshot.problems.append(Problem(preset: preset, reason: "another preset has the id \(preset.id)"))
            } else if !names.insert(preset.name.lowercased()).inserted {
                snapshot.problems.append(Problem(preset: preset, reason: "another preset has the same name"))
            } else {
                switch validate(preset) {
                case .success(let action): snapshot.valid.append(PresetSlice(preset: preset, action: action))
                case .failure(let problem): snapshot.problems.append(Problem(preset: preset, reason: problem.localizedDescription))
                }
            }
        }
        return snapshot
    }
}
