import Foundation

/// UserDefaults keys shared by the Settings window (`@AppStorage`) and the engines.
enum Prefs {
    static let enabledKey = "enabled"
    static let revealKey = "revealInFinder"
    static let qualityKey = "imageQuality"
    static let toolsDirectoryKey = "toolsDirectory"
    static let controlWheelKey = "controlWheel"

    /// The bundled app reads `app.clementine.Clementine`; the unbundled debug binary falls back to a domain named
    /// after the executable (`~/Library/Preferences/Clementine.plist`). Debug builds can point at a scratch suite
    /// with `CLEMENTINE_DEFAULTS_SUITE` so tests never touch real settings.
    static let defaults: UserDefaults = {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["CLEMENTINE_DEFAULTS_SUITE"], let scratch = UserDefaults(suiteName: suite) {
            return scratch
        }
        #endif
        return .standard
    }()

    /// `~/Library/Application Support/Clementine`, or `CLEMENTINE_SUPPORT_DIR` in debug builds (for tests).
    static var supportDirectory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["CLEMENTINE_SUPPORT_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clementine", isDirectory: true)
    }

    static var enabled: Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static var revealInFinder: Bool { defaults.object(forKey: revealKey) as? Bool ?? true }
    static var imageQuality: Double { defaults.object(forKey: qualityKey) as? Double ?? 0.85 }
    static var toolsDirectory: String? { defaults.string(forKey: toolsDirectoryKey) }
    /// Whether ⌃ while dragging opens the file actions wheel (Settings › General).
    static var controlWheel: Bool { defaults.object(forKey: controlWheelKey) as? Bool ?? true }
}
