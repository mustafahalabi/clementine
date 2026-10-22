import Foundation

/// Which slices the user hid in Settings › Wheel. Hidden actions leave the wheel but still run from the CLI.
enum HiddenActions {
    static let key = "hiddenActions"

    static var ids: Set<String> {
        get { Set(Prefs.defaults.stringArray(forKey: key) ?? []) }
        set { Prefs.defaults.set(newValue.sorted(), forKey: key) }
    }
}

/// Frecency: how often and how recently each action was used, per (file kind, wheel mode).
///
/// Each use adds 1 to a score that halves every two weeks, so a habit from last month gives way to this week's.
/// Stored in UserDefaults as `[bucket: [actionID: [score, lastUsed]]]`.
enum ActionUsage {
    static let key = "actionUsage"
    static let orderKey = "orderByUsage"
    static let halfLife: TimeInterval = 14 * 24 * 3600

    /// Whether the wheel puts the most used actions first (Settings › Wheel). On by default.
    static var ordersByUsage: Bool {
        get { Prefs.defaults.object(forKey: orderKey) as? Bool ?? true }
        set { Prefs.defaults.set(newValue, forKey: orderKey) }
    }

    /// "image.convert", "video.tools", "pdf.files", or "mixed.convert" for selections of different kinds.
    static func bucket(for items: [FileItem], mode: WheelMode) -> String {
        let kinds = Set(items.map { "\($0.kind)" })
        return bucket(kind: kinds.count == 1 ? kinds.first! : "mixed", mode: mode)
    }

    static func bucket(kind: String, mode: WheelMode) -> String {
        "\(kind).\(mode.name)"
    }

    static func record(_ action: Action, urls: [URL], now: Date = Date()) {
        let bucket = bucket(for: urls.map(FileItem.init), mode: action.mode)
        var all = stored
        var entries = all[bucket] ?? [:]
        let previous = entries[action.id].flatMap { $0.count == 2 ? $0 : nil } ?? [0, now.timeIntervalSinceReferenceDate]
        entries[action.id] = [decay(previous[0], from: previous[1], to: now) + 1, now.timeIntervalSinceReferenceDate]
        all[bucket] = entries
        Prefs.defaults.set(all, forKey: key)
    }

    /// Current (decayed) scores for one bucket.
    static func scores(bucket: String, now: Date = Date()) -> [String: Double] {
        (stored[bucket] ?? [:]).compactMapValues { pair in
            pair.count == 2 ? decay(pair[0], from: pair[1], to: now) : nil
        }
    }

    static func reset() {
        Prefs.defaults.removeObject(forKey: key)
    }

    /// Most used first. Equal scores (including never used) keep catalog order, so a fresh install looks as designed.
    static func arrange(_ actions: [Action], bucket: String) -> [Action] {
        guard ordersByUsage else { return actions }
        let scores = scores(bucket: bucket)
        guard !scores.isEmpty else { return actions }
        return actions.enumerated()
            .sorted { lhs, rhs in
                let left = scores[lhs.element.id] ?? 0, right = scores[rhs.element.id] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static var stored: [String: [String: [Double]]] {
        Prefs.defaults.dictionary(forKey: key) as? [String: [String: [Double]]] ?? [:]
    }

    private static func decay(_ score: Double, from last: TimeInterval, to now: Date) -> Double {
        let age = max(0, now.timeIntervalSinceReferenceDate - last)
        return score * pow(0.5, age / halfLife)
    }
}
