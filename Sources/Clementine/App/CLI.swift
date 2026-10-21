import AppKit
import SwiftUI

/// Headless entry points, mainly for testing actions without dragging:
///
///     Clementine --list photo.heic
///     Clementine --run convert.image.png photo.heic
///     Clementine --run tool.fit --set megabytes=1.5 photo.heic
///     Clementine --history
enum CLI {
    static let commands: Set = ["--list", "--run", "--render-wheel", "--history", "--undo", "--clear-history", "--help"]

    static func run(_ arguments: [String]) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task {
            let status = await execute(arguments)
            exit(status)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static let usage = """
        usage: Clementine --list <file>...
               Clementine --run <action-id> [--set key=value]... [--record] <file>...
               Clementine --history | --undo | --clear-history

        --list shows each wheel as it would appear (most used first, hidden slices marked).
        --run processes several files in parallel, like the app. --record also logs usage and history.
        --undo moves the newest history entry's outputs to the Trash.
        """

    private static func execute(_ arguments: [String]) async -> Int32 {
        var arguments = arguments
        switch arguments.removeFirst() {
        case "--list":
            let urls = arguments.map(fileURL)
            guard !urls.isEmpty else { print(usage); return 2 }
            for (mode, name) in [(WheelMode.convert, "Convert (⇧)"), (.tools, "Tools (⌥⇧)")] {
                print(name)
                let shown = ActionRegistry.actions(for: urls, mode: mode)
                let hidden = HiddenActions.ids
                for action in shown {
                    print("  \(action.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(action.title)")
                }
                for action in ActionRegistry.candidates(for: urls, mode: mode) where hidden.contains(action.id) {
                    print("  \(action.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(action.title)  (hidden)")
                }
            }
            return 0

        case "--run":
            guard !arguments.isEmpty, let action = ActionRegistry.find(arguments.removeFirst()) else {
                print(usage)
                return 2
            }
            var params = action.defaults
            var files: [URL] = []
            var record = false
            while !arguments.isEmpty {
                let argument = arguments.removeFirst()
                if argument == "--record" {
                    record = true
                } else if argument == "--set", !arguments.isEmpty {
                    let pair = arguments.removeFirst().split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2, let parameter = action.parameters.first(where: { $0.key == pair[0] }) else {
                        fputs("unknown parameter \(pair[0]) for \(action.id)\n", stderr)
                        return 2
                    }
                    switch parameter.kind {
                    case .slider, .number: params.storage[pair[0]] = .number(Double(pair[1]) ?? 0)
                    case .choice(let options):
                        let index = Int(pair[1]) ?? options.firstIndex { $0.lowercased() == pair[1].lowercased() } ?? 0
                        params.storage[pair[0]] = .choice(index)
                    case .text: params.storage[pair[0]] = .text(pair[1])
                    }
                } else {
                    files.append(fileURL(argument))
                }
            }
            guard files.count >= action.minInputs else {
                fputs("\(action.id) needs at least \(action.minInputs) files\n", stderr)
                return 2
            }

            // Same parallel path as the app; results are printed in input order once everything has finished.
            let report = await BatchRunner.run(action, urls: files, params: params)
            for (unit, result) in report.outcomes {
                switch result {
                case .success(.files(let outputs)): outputs.forEach { print($0.path) }
                case .success(.text(let title, let body)): print("== \(title) ==\n\(body)")
                case .failure(let error):
                    fflush(stdout)
                    fputs("error: \(unit[0].lastPathComponent): \(error.localizedDescription)\n", stderr)
                }
            }
            if record {
                let files = files
                await MainActor.run {
                    ActionUsage.record(action, urls: files)
                    if !report.files.isEmpty { HistoryStore.shared.record(action, inputs: files, outputs: report.files) }
                }
            }
            return report.failures.isEmpty ? 0 : 1

        case "--history":
            let entries = await MainActor.run { HistoryStore.shared.entries }
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                print("\(formatter.string(from: entry.date))\t\(entry.actionID)\t\(entry.title)\t\(entry.inputs.joined(separator: "|"))\t\(entry.outputs.joined(separator: "|"))")
            }
            return 0

        case "--undo":
            return await MainActor.run {
                guard let entry = HistoryStore.shared.undoable else {
                    fputs("nothing to undo\n", stderr)
                    return 1
                }
                do {
                    for location in try HistoryStore.shared.undo(entry) { print(location.path) }
                    return 0
                } catch {
                    fputs("error: \(error.localizedDescription)\n", stderr)
                    return 1
                }
            }

        case "--clear-history":
            await MainActor.run { HistoryStore.shared.clear() }
            return 0

        case "--render-wheel":
            // Dev aid: draws the wheel to a PNG (materials render flat).
            // --render-wheel out.png [--tools] [--hover N] [--light] [--click [--chip]] file…
            guard arguments.count >= 2 else { print(usage); return 2 }
            let output = fileURL(arguments.removeFirst())
            let mode: WheelMode = arguments.contains("--tools") ? .tools : .convert
            let appearance = NSAppearance(named: arguments.contains("--light") ? .aqua : .darkAqua)
            let hovered = arguments.firstIndex(of: "--hover").flatMap { Int(arguments[$0 + 1]) }
            let files = arguments.enumerated().filter { index, argument in
                !argument.hasPrefix("--") && (index == 0 || arguments[index - 1] != "--hover")
            }.map { fileURL($0.element) }
            let click = arguments.contains("--click") ? (chip: arguments.contains("--chip"), on: true) : (chip: false, on: false)
            return await renderWheel(files, mode: mode, hovered: hovered, click: click.on, chipHovered: click.chip,
                                     appearance: appearance, to: output)

        default:
            print(usage)
            return 0
        }
    }

    @MainActor
    private static func renderWheel(_ files: [URL], mode: WheelMode, hovered: Int?, click: Bool, chipHovered: Bool,
                                    appearance: NSAppearance?, to output: URL) async -> Int32 {
        let model = WheelModel()
        model.load(urls: files, mode: mode)
        model.hovered = hovered
        model.interactive = click
        model.chipHovered = chipHovered
        model.visible = true
        try? await Task.sleep(nanoseconds: 800_000_000) // let the Quick Look thumbnail arrive
        let side = model.canvasSize
        let backdrop = appearance?.name == .aqua ? Color(hex: 0xE9E4DE) : Color(hex: 0x1E1E22)
        let view = NSHostingView(rootView: WheelView(model: model).background(backdrop))
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: side, height: side)
        // Let the open and fan-in animations settle before taking the picture.
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output)
        print(output.path)
        return 0
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}
