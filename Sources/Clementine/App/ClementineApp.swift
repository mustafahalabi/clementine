import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        #if DEBUG
        if UIPreview.handle(arguments) { exit(0) }
        #endif
        if let command = arguments.first, CLI.commands.contains(command) {
            CLI.run(arguments)
        }
        ClementineApp.main()
    }
}

struct ClementineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Clementine", systemImage: "camera.aperture") {
            MenuContent()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WheelController.shared.start()
        Updater.start()
        ServiceProvider.register()
        HistoryStore.shared.startClock()
        OnboardingWindow.showIfFirstLaunch()
    }
}

private struct MenuContent: View {
    @AppStorage(Prefs.enabledKey) private var enabled = true

    var body: some View {
        Toggle("Wheel Enabled", isOn: $enabled)
        Divider()
        Text("Hold ⇧ while dragging to convert")
        Text("Hold ⌥⇧ while dragging for tools")
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
