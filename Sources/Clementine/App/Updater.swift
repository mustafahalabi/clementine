import AppKit
import Sparkle
import SwiftUI
@preconcurrency import UserNotifications

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
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                  userDriverDelegate: UpdateReminder.shared)
        guard disabledReason == nil else { return }
        UNUserNotificationCenter.current().delegate = UpdateReminder.shared
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

    /// Brings a found update's alert to the front (Sparkle resumes the session it's holding).
    func showPendingUpdate() {
        NSApp.activate()
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

/// Sparkle's "gentle reminders". Clementine is a menu bar app, so an update found by a background check would
/// otherwise open its alert behind whatever app is in front. Unless Sparkle is about to show it in full focus
/// (just after launch, or after the Mac sat idle), it's announced instead with a dot on the menu bar icon, an
/// "Update Available" menu item and a quiet notification; choosing either brings the alert to the front.
/// See https://sparkle-project.org/documentation/gentle-reminders
@MainActor
final class UpdateReminder: NSObject, ObservableObject, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    static let shared = UpdateReminder()

    /// The version waiting for the user, or nil.
    @Published private(set) var availableVersion: String?

    nonisolated static let notificationID = "app.clementine.update-available"

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            // Sparkle is showing it now (a manual check, or full focus): make sure it isn't behind Finder.
            if handleShowingUpdate { return NSApp.activate() }
            availableVersion = version
            notify(version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { withdrawNotification() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
            withdrawNotification()
        }
    }

    /// Provisional authorization: delivered quietly to Notification Center, with no permission prompt.
    private func notify(_ version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "Clementine \(version) is available"
            content.body = "Click to see what's new and install it."
            center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        }
    }

    private func withdrawNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.identifier == Self.notificationID
        DispatchQueue.main.async {
            if isUpdate { Updater.shared.showPendingUpdate() }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }

    #if DEBUG
    /// For `--render-ui`.
    func preview(version: String?) { availableVersion = version }
    #endif
}

/// The menu bar icon, with a dot while an update is waiting.
struct MenuBarIcon: View {
    @ObservedObject var reminder = UpdateReminder.shared

    var body: some View {
        // The plain icon stays exactly what MenuBarExtra draws for a system image.
        if reminder.availableVersion != nil {
            Image(nsImage: Self.image(badged: true))
        } else {
            Image(systemName: "camera.aperture")
        }
    }

    static func image(badged: Bool) -> NSImage {
        let description = badged ? "Clementine, update available" : "Clementine"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard badged else { return symbol }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6.5, height: 6.5)
            // A clear ring around the dot keeps it readable against the symbol's strokes.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true // tinted by the menu bar like the plain icon
        image.accessibilityDescription = description
        return image
    }
}
