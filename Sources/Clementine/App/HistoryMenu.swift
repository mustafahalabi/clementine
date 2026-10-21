import AppKit
import SwiftUI

/// Menu bar items for opening files without a drag, and for the history of finished jobs.
struct HistoryMenu: View {
    @ObservedObject private var history = HistoryStore.shared
    static let recentCount = 8

    var body: some View {
        Button("Open Files…") { WheelController.shared.openFiles() }
            .keyboardShortcut("o")
        Menu("Recent") {
            if history.entries.isEmpty {
                Text("No conversions yet")
            } else {
                ForEach(history.entries.prefix(Self.recentCount)) { entry in
                    Button { history.reveal(entry) } label: {
                        Label("\(entry.title) · \(entry.subject) · \(history.relativeTime(entry.date))", systemImage: entry.symbol)
                    }
                }
                Divider()
                Button("Clear History") { history.clear() }
            }
        }
        Button("Undo Last Conversion") { undoLast() }
            .keyboardShortcut("z")
            .disabled(history.undoable == nil)
    }

    private func undoLast() {
        guard let entry = history.undoable else { return }
        do {
            try history.undo(entry)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't move the files to the Trash"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }
}
