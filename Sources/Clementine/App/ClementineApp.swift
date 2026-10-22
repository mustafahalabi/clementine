import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        #if DEBUG
        if UIPreview.handle(arguments) || UITest.handle(arguments) || ShortcutRunner.handle(arguments) { exit(0) }
        #endif
        if let command = arguments.first, CLI.commands.contains(command) {
            Output.sweepStale()
            CLI.run(arguments)
        }
        // Off the main thread: a recorded folder may be on a slow or unmounted network volume.
        DispatchQueue.global(qos: .utility).async { Output.sweepStale() }
        ClementineApp.main()
    }
}

struct ClementineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarIcon()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WheelController.shared.start()
        Updater.start()
        ServiceProvider.register()
        HistoryStore.shared.startClock()
        LaunchAtLogin.applyDefaultIfNeeded(isFreshInstall: !OnboardingWindow.completed)
        OnboardingWindow.showIfFirstLaunch()
    }

    /// Opening the app again from Finder, Spotlight or Launchpad: there's no Dock icon, so show something.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingWindow.completed { SettingsWindow.show() } else { OnboardingWindow.show() }
        return false
    }

    /// Running jobs' tools would outlive the app (they're in their own process group) and leave half-written
    /// files, so stop them and let them clean up before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !JobRunner.shared.running.isEmpty || ProcessRunner.runningCount > 0 else { return .terminateNow }
        Task { @MainActor in
            await JobRunner.shared.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuContent: View {
    @AppStorage(Prefs.enabledKey) private var enabled = true
    @ObservedObject private var reminder = UpdateReminder.shared

    var body: some View {
        if let version = reminder.availableVersion {
            Button("Update Available: Clementine \(version) — Install…") { Updater.shared.showPendingUpdate() }
            Divider()
        }
        Toggle("Wheel Enabled", isOn: $enabled)
        Divider()
        Text("Hold ⇧ while dragging to convert")
        Text("Hold ⌥⇧ while dragging for tools")
        Text("Hold ⌃ while dragging for file actions")
        Divider()
        HistoryMenu()
        Divider()
        Button("Settings…") { SettingsWindow.show() }
            .keyboardShortcut(",")
        Button("Show Welcome…") { OnboardingWindow.show() }
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Button("Quit Clementine") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
