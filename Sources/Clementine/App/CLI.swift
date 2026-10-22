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
        let work = Task { await execute(arguments) }
        handleInterrupts(stopping: work)
        Task {
            let status = await work.value
            exit(interruption.withLock { $0 }.map { 128 + $0 } ?? status)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// The signal that interrupted the run, if any. The exit status becomes 128 + signal, as shells expect.
    private static let interruption = Locked<Int32?>(nil)
    private static var signalSources: [DispatchSourceSignal] = []

    /// Tools run in their own process group, so Ctrl-C or a `kill` reaches only us: stop them, let the engines
    /// delete their partial outputs, then exit. A second signal skips the wait.
    private static func handleInterrupts(stopping work: Task<Int32, Never>) {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN) // otherwise the default action kills us before the source fires
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                let first = interruption.withLock { current -> Bool in
                    defer { if current == nil { current = number } }
                    return current == nil
                }
                guard first else {
                    ProcessRunner.killAll()
                    Output.discardInFlight()
                    exit(128 + number)
                }
                Task.detached {
                    await Shutdown.stop(cancel: { work.cancel() }, waitingFor: { _ = await work.value })
                    exit(128 + number)
                }
            }
            source.resume()
            signalSources.append(source)
        }
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
                } else if argument == "--set" {
                    guard !arguments.isEmpty else { return usageError("--set needs key=value") }
                    let pair = arguments.removeFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard pair.count == 2 else { return usageError("--set needs key=value, got \"\(pair.joined())\"") }
                    guard let parameter = action.parameters.first(where: { $0.key == pair[0] }) else {
                        let known = action.parameters.map(\.key)
                        let hint = known.isEmpty ? "it takes no parameters" : "valid keys: \(known.joined(separator: ", "))"
                        return usageError("unknown parameter \(pair[0]) for \(action.id) (\(hint))")
                    }
                    switch parse(pair[1], for: parameter) {
                    case .success(let value): params.storage[parameter.key] = value
                    case .failure(let problem): return usageError("\(parameter.key)=\(pair[1]): \(problem.message)")
                    }
                } else if argument.hasPrefix("--") && !FileManager.default.fileExists(atPath: argument) {
                    return usageError("unknown option \(argument)")
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
                case .success(.unchanged(let message)):
                    // stderr, so stdout stays a list of output paths; not an error (exit status stays 0).
                    fflush(stdout)
                    fputs("kept: \(unit[0].lastPathComponent): \(message)\n", stderr)
                case .failure(is CancellationError) where report.cancelled:
                    fflush(stdout)
                    fputs("cancelled: \(unit[0].lastPathComponent)\n", stderr)
                case .failure(let error):
                    fflush(stdout)
                    let message = error is CancellationError ? "Stopped unexpectedly." : error.localizedDescription
                    fputs("error: \(unit[0].lastPathComponent): \(message)\n", stderr)
                }
            }
            if record {
                let files = files
                await MainActor.run {
                    ActionUsage.record(action, urls: files)
                    if !report.files.isEmpty { HistoryStore.shared.record(action, inputs: files, outputs: report.files) }
                }
            }
            // Interrupted runs exit 128 + signal (see `run`); a cancel without a signal still isn't a success.
            return report.failures.isEmpty && !report.cancelled ? 0 : 1

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
            var hovered: Int?
            if let flag = arguments.firstIndex(of: "--hover") {
                guard flag + 1 < arguments.count, let index = Int(arguments[flag + 1]), index >= 0 else {
                    return usageError("--hover needs a slice number (0, 1, 2…)")
                }
                hovered = index
            }
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

    private static func usageError(_ message: String) -> Int32 {
        fputs("\(message)\n", stderr)
        return 2
    }

    struct InvalidValue: Error {
        let message: String
    }

    /// Checks a `--set` value against the parameter's definition. Slider ranges are enforced (values outside
    /// them mean nothing); typed numbers only need to be finite, since engines check them with a specific
    /// message (Split's 1-second minimum, Target Size's "under …").
    static func parse(_ raw: String, for parameter: Parameter) -> Result<ParamValue, InvalidValue> {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch parameter.kind {
        case .slider(let range), .number(let range, _):
            guard let value = Double(text), value.isFinite else {
                return .failure(InvalidValue(message: "not a number"))
            }
            if case .slider = parameter.kind, !range.contains(value) {
                return .failure(InvalidValue(message: "must be between \(format(range.lowerBound)) and \(format(range.upperBound))"))
            }
            return .success(.number(value))
        case .choice(let options):
            if let index = Int(text) {
                if options.indices.contains(index) { return .success(.choice(index)) }
            } else if let index = options.firstIndex(where: { $0.lowercased() == text.lowercased() }) {
                return .success(.choice(index))
            }
            let listed = options.enumerated().map { "\($0.offset) = \($0.element)" }.joined(separator: ", ")
            return .failure(InvalidValue(message: "not a valid choice; use an index or label: \(listed)"))
        case .text:
            return .success(.text(raw))
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}
