#if DEBUG
import AppKit
import SwiftUI

/// Dev aid: draws the job windows and Settings to PNGs without putting anything on screen.
/// `Clementine --render-ui <dir> [image]`, in light and dark (materials render flat).
@MainActor
enum UIPreview {
    static func handle(_ arguments: [String]) -> Bool {
        guard arguments.first == "--render-ui", arguments.count >= 2 else { return false }
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(appearance: NSAppearance(named: appearance)!, suffix: name, image: image, to: directory)
            }
        }
        return true
    }

    private static func render(appearance: NSAppearance, suffix: String, image: URL?, to directory: URL) {
        func out(_ name: String) -> URL { directory.appendingPathComponent("\(name)-\(suffix).png") }

        // Progress cards, stacked as they'd be on screen.
        let running = RunningJob(title: "Convert to WebP", symbol: "photo", detail: "IMG_2041 holiday in Lisbon.heic")
        running.progress = 0.62
        let indeterminate = RunningJob(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "screen-recording.mov")
        let done = RunningJob(title: "Convert to MP3", symbol: "music.note", detail: "interview.m4a")
        done.progress = 1
        done.state = .done
        let failed = RunningJob(title: "Target Size", symbol: "scalemass", detail: "clip.mov")
        failed.state = .failed("ffmpeg was not found. Install it with `brew install ffmpeg` or set a tools folder in Settings.")
        let cards = VStack(spacing: 14) {
            ForEach([running, indeterminate, done, failed], id: \.detail) { job in
                JobView(job: job, cancel: {}, dismiss: {}).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(hex: 0x6E8CA8), Color(hex: 0xB59BC4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        snapshot(NSHostingView(rootView: cards), appearance: appearance, to: out("progress"))

        // Parameter sheets: one with a live preview, one with typed numbers.
        if let edit = ActionRegistry.find("tool.image.adjust") {
            let urls = [image ?? URL(fileURLWithPath: "/tmp/missing.png")]
            var values = edit.defaults
            values.storage["saturation"] = .number(1.4)
            let form = ParameterForm(action: edit, urls: urls, values: values, onApply: { _ in }, onCancel: {})
            snapshotWindow(NSHostingController(rootView: form), appearance: appearance, settle: 1.5, to: out("parameters-preview"))
        }
        if let fit = ActionRegistry.find("tool.fit") {
            let form = ParameterForm(action: fit, urls: [URL(fileURLWithPath: "/tmp/clip.mov")], values: fit.defaults,
                                     onApply: { _ in }, onCancel: {})
            snapshotWindow(NSHostingController(rootView: form), appearance: appearance, to: out("parameters"))
        }

        let qr = ResultView(title: "poster.png", text: "https://clementine.app/download?ref=poster")
        snapshotWindow(NSHostingController(rootView: qr.frame(width: 480, height: 300)), appearance: appearance, to: out("result-qr"))
        let metadata = """
            File            IMG_2041.heic
            Dimensions      4032 × 3024
            Camera          Apple iPhone 15 Pro
            Lens            iPhone 15 Pro back triple camera 6.765mm f/1.78
            Exposure        1/120 s at f/1.8, ISO 64
            Taken           2026-07-14 18:42:09
            Location        38.7139° N, 9.1394° W
            Color profile   Display P3
            """
        snapshotWindow(NSHostingController(rootView: ResultView(title: "IMG_2041.heic", text: metadata).frame(width: 520, height: 420)),
                       appearance: appearance, to: out("result-metadata"))

        snapshotWindow(NSHostingController(rootView: SettingsView()), appearance: appearance, to: out("settings"))
    }

    /// Draws a view hierarchy into a PNG.
    private static func snapshot(_ view: NSView, appearance: NSAppearance, to url: URL) {
        view.appearance = appearance
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        write(view, to: url)
    }

    /// Hosts the content in an unshown FocusablePanel so the transparent title bar and its safe area are real.
    private static func snapshotWindow(_ host: NSHostingController<some View>, appearance: NSAppearance, settle: TimeInterval = 0.3, to url: URL) {
        let window = FocusablePanel()
        window.appearance = appearance
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(settle)) // let previews render and layout settle
        window.setContentSize(host.view.fittingSize)
        window.contentView?.layoutSubtreeIfNeeded()
        write(window.contentView?.superview ?? host.view, to: url)
        window.close()
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
#endif
