import Foundation

/// UserDefaults keys shared by the Settings window (`@AppStorage`) and the engines.
enum Prefs {
    static let enabledKey = "enabled"
    static let revealKey = "revealInFinder"
    static let qualityKey = "imageQuality"
    static let toolsDirectoryKey = "toolsDirectory"

    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static var revealInFinder: Bool { defaults.object(forKey: revealKey) as? Bool ?? true }
    static var imageQuality: Double { defaults.object(forKey: qualityKey) as? Double ?? 0.85 }
    static var toolsDirectory: String? { defaults.string(forKey: toolsDirectoryKey) }
}
