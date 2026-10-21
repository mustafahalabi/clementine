import AppKit
import Sparkle

/// Sparkle 2 auto-updates. Created lazily from the app delegate, so the headless CLI never touches it.
///
/// The updater only starts when it can work safely: running from a real .app bundle (not `.build/debug`) and with
/// a real `SUPublicEDKey` in Info.plist. Until the release key is filled in (see RELEASING.md) nothing checks in the
/// background, and "Check for Updates…" explains why instead of failing.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    nonisolated static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    /// Why updates are off, or nil when they're on.
    let disabledReason: String?

    private init() {
        disabledReason = Self.disabledReason(for: .main)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        guard disabledReason == nil else { return }
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    /// Starts the updater (and its scheduled background checks) if this build is set up for it.
    static func start() {
        _ = shared
    }

    func checkForUpdates() {
        if let disabledReason {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up for this build"
            alert.informativeText = disabledReason
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    nonisolated static func disabledReason(for bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app" else {
            return "Clementine is running outside an app bundle, so there's nothing to update."
        }
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !key.isEmpty, key != placeholderKey else {
            return "This copy was built without a release signing key. Download the latest version from github.com/mustafahalabi/clementine/releases."
        }
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            return "No update feed is configured."
        }
        return nil
    }
}
