import AppKit

/// A finished job that produced files, as kept in history.json.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var actionID: String
    var title: String
    var symbol: String
    var inputs: [String]
    var outputs: [String]
    var date: Date

    var inputURLs: [URL] { inputs.map { URL(fileURLWithPath: $0) } }
    var outputURLs: [URL] { outputs.map { URL(fileURLWithPath: $0) } }

    /// Outputs that are still where the job left them.
    var existingOutputs: [URL] { outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }

    /// "photo.heic" or "photo.heic + 3 more", for menus.
    var subject: String {
        guard let first = inputURLs.first?.lastPathComponent else { return "" }
        return inputs.count > 1 ? "\(first) + \(inputs.count - 1) more" : first
    }
}

/// The last 50 jobs that made files, newest first, persisted in Application Support/Clementine/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 50

    @Published private(set) var entries: [HistoryEntry] = []
    /// Ticks every half minute while the menu bar app runs, so "2 min ago" stays true.
    @Published private(set) var now = Date()

    private let file: URL
    private var clock: Timer?

    init(file: URL = Prefs.supportDirectory.appendingPathComponent("history.json")) {
        self.file = file
        entries = Self.load(file)
    }

    func startClock() {
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    @discardableResult
    func record(_ action: Action, inputs: [URL], outputs: [URL], date: Date = Date()) -> HistoryEntry {
        let entry = HistoryEntry(actionID: action.id, title: JobRunner.title(for: action),
                                 symbol: action.symbol ?? "arrow.triangle.2.circlepath",
                                 inputs: inputs.map(\.path), outputs: outputs.map(\.path), date: date)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        now = date
        save()
        return entry
    }

    /// The most recent job whose outputs are still around, i.e. what "Undo Last Conversion" would trash.
    var undoable: HistoryEntry? {
        entries.first { !$0.existingOutputs.isEmpty }
    }

    /// Moves the entry's outputs to the Trash and forgets it. Returns where each file went.
    @discardableResult
    func undo(_ entry: HistoryEntry) throws -> [URL] {
        var trashed: [URL] = []
        for output in entry.existingOutputs {
            var location: NSURL?
            try FileManager.default.trashItem(at: output, resultingItemURL: &location)
            if let location = location as URL? { trashed.append(location) }
        }
        entries.removeAll { $0.id == entry.id }
        save()
        return trashed
    }

    func reveal(_ entry: HistoryEntry) {
        let existing = entry.existingOutputs
        NSWorkspace.shared.activateFileViewerSelecting(existing.isEmpty ? entry.inputURLs : existing)
    }

    func clear() {
        entries = []
        save()
    }

    func relativeTime(_ date: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch {
            NSLog("Clementine: couldn't save history: \(error.localizedDescription)")
        }
    }

    private static func load(_ file: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)).map { Array($0.prefix(limit)) } ?? []
    }
}
