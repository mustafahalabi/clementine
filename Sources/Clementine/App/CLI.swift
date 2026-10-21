import AppKit
import SwiftUI

/// Headless entry points, mainly for testing actions without dragging:
///
///     Clementine --list photo.heic
///     Clementine --run convert.image.png photo.heic
///     Clementine --run tool.fit --set megabytes=1.5 photo.heic
enum CLI {
    static let commands: Set = ["--list", "--run", "--render-wheel", "--help"]

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
               Clementine --run <action-id> [--set key=value]... <file>...
        """

    private static func execute(_ arguments: [String]) async -> Int32 {
        var arguments = arguments
        switch arguments.removeFirst() {
        case "--list":
            let urls = arguments.map(fileURL)
            guard !urls.isEmpty else { print(usage); return 2 }
            for (mode, name) in [(WheelMode.convert, "Convert (⇧)"), (.tools, "Tools (⌥⇧)")] {
                print(name)
                for action in ActionRegistry.actions(for: urls, mode: mode) {
                    print("  \(action.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(action.title)")
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
            while !arguments.isEmpty {
                let argument = arguments.removeFirst()
                if argument == "--set", !arguments.isEmpty {
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

            var failed = false
            for unit in action.batch ? [files] : files.map({ [$0] }) {
                do {
                    switch try await action.run(JobContext(inputs: unit, params: params, progress: { _ in })) {
                    case .files(let outputs): outputs.forEach { print($0.path) }
                    case .text(let title, let body): print("== \(title) ==\n\(body)")
                    }
                } catch {
                    fputs("error: \(unit[0].lastPathComponent): \(error.localizedDescription)\n", stderr)
                    failed = true
                }
            }
            return failed ? 1 : 0

        case "--render-wheel":
            // Dev aid: draws the wheel to a PNG (materials render flat).
            // --render-wheel out.png [--tools] [--hover N] [--light] file…
            guard arguments.count >= 2 else { print(usage); return 2 }
            let output = fileURL(arguments.removeFirst())
            let mode: WheelMode = arguments.contains("--tools") ? .tools : .convert
            let appearance = NSAppearance(named: arguments.contains("--light") ? .aqua : .darkAqua)
            let hovered = arguments.firstIndex(of: "--hover").flatMap { Int(arguments[$0 + 1]) }
            let files = arguments.enumerated().filter { index, argument in
                !argument.hasPrefix("--") && (index == 0 || arguments[index - 1] != "--hover")
            }.map { fileURL($0.element) }
            return await renderWheel(files, mode: mode, hovered: hovered, appearance: appearance, to: output)

        default:
            print(usage)
            return 0
        }
    }

    @MainActor
    private static func renderWheel(_ files: [URL], mode: WheelMode, hovered: Int?, appearance: NSAppearance?,
                                    to output: URL) async -> Int32 {
        let model = WheelModel()
        model.load(urls: files, mode: mode)
        model.hovered = hovered
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
