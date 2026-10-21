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
        renderImageEditors(appearance: appearance, out: out)
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

// MARK: Image editors

extension UIPreview {
    /// Crop, Redact and Annotate in typical mid-edit states, on a generated picture with a face-free scene and text.
    fileprivate static func renderImageEditors(appearance: NSAppearance, out: (String) -> URL) {
        guard let url = demoPicture(), let image = try? EditorImage.load(url) else { return }
        let editorSize = CGSize(width: 1000, height: 720)

        let crop = CropModel(source: image)
        crop.setAspect(.standard)
        crop.rect = CGRect(x: 260, y: 150, width: 960, height: 720)
        crop.drag = .handle(.bottomRight, from: crop.rect)
        crop.hover = .bottomRight
        snapshotEditor(CropEditorView(model: crop, onApply: { _ in }, onCancel: {}), size: editorSize, appearance: appearance, to: out("editor-crop"))

        let turned = CropModel(source: image)
        turned.turn(1, animated: false)
        turned.rect = CGRect(x: 120, y: 200, width: 760, height: 900)
        turned.hover = .move
        snapshotEditor(CropEditorView(model: turned, onApply: { _ in }, onCancel: {}), size: CGSize(width: 900, height: 760),
                       appearance: appearance, to: out("editor-crop-turned"))
        turned.spin = -45 // midway through a quarter turn
        snapshotEditor(CropEditorView(model: turned, onApply: { _ in }, onCancel: {}), size: CGSize(width: 900, height: 760),
                       appearance: appearance, to: out("editor-crop-turning"))

        let redact = RedactModel(source: image)
        redact.boxes = [.init(rect: CGRect(x: 1090, y: 180, width: 300, height: 300))]
        Task { await redact.autoDetect(animation: nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(2.5)) // Vision
        redact.selection = redact.boxes.first?.id
        redact.hover = redact.boxes.first.map { .init(id: $0.id, handle: .topRight) }
        snapshotEditor(RedactEditorView(model: redact, onApply: { _ in }, onCancel: {}), size: editorSize, appearance: appearance,
                       settle: 1.2, to: out("editor-redact"))
        redact.style = .blur
        redact.selection = nil
        redact.notice = nil
        snapshotEditor(RedactEditorView(model: redact, onApply: { _ in }, onCancel: {}), size: editorSize, appearance: appearance,
                       settle: 1.2, to: out("editor-redact-blur"))

        let annotate = AnnotateModel(source: image)
        typealias Mark = ImageEdits.Annotation
        let marks = [
            Mark(kind: .highlighter, points: [CGPoint(x: 120, y: 760), CGPoint(x: 700, y: 760)], color: "#FFD43B", width: 18),
            Mark(kind: .arrow, points: [CGPoint(x: 900, y: 860), CGPoint(x: 1150, y: 560)], color: "#FF5E3A", width: 14),
            Mark(kind: .ellipse, points: [CGPoint(x: 1060, y: 160), CGPoint(x: 1420, y: 500)], color: "#FF9A3C", width: 12),
            Mark(kind: .rectangle, points: [CGPoint(x: 90, y: 640), CGPoint(x: 760, y: 900)], color: "#0A84FF", width: 10),
            Mark(kind: .pen, points: stride(from: 0.0, through: 1, by: 0.05).map { t in
                CGPoint(x: 180 + t * 520, y: 520 + sin(t * .pi * 3) * 40) }, color: "#34C77B", width: 10),
            Mark(kind: .text, points: [CGPoint(x: 880, y: 880)], color: "#FF5E3A", width: 64, text: "Ship it!"),
        ]
        annotate.setTool(.select)
        annotate.items = marks
        annotate.selection = marks[2].id
        annotate.hover = marks[1].id
        snapshotEditor(AnnotateEditorView(model: annotate, onApply: { _ in }, onCancel: {}), size: editorSize, appearance: appearance,
                       to: out("editor-annotate"))
        annotate.setTool(.text)
        annotate.typing = .init(origin: CGPoint(x: 120, y: 120), text: "Before → after")
        snapshotEditor(AnnotateEditorView(model: annotate, onApply: { _ in }, onCancel: {}), size: editorSize, appearance: appearance,
                       to: out("editor-annotate-typing"))
    }

    private static func snapshotEditor(_ view: some View, size: CGSize, appearance: NSAppearance, settle: TimeInterval = 0.6, to url: URL) {
        let host = NSHostingController(rootView: view)
        let window = FocusablePanel(resizable: true)
        window.appearance = appearance
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        window.contentView?.layoutSubtreeIfNeeded()
        write(window.contentView?.superview ?? host.view, to: url)
        window.close()
    }

    /// A 1600×1000 scene: sunset gradient, hills, and a receipt card with a name and numbers to redact.
    private static func demoPicture() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-editor-demo.png")
        guard let image = try? ImageEngine.render(width: 1600, height: 1000, { context in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let sky = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.98, green: 0.55, blue: 0.32, alpha: 1),
                                                               CGColor(srgbRed: 0.99, green: 0.84, blue: 0.62, alpha: 1),
                                                               CGColor(srgbRed: 0.55, green: 0.72, blue: 0.86, alpha: 1)] as CFArray,
                                 locations: [0, 0.45, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1000), options: [])
            context.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1))
            context.fillEllipse(in: CGRect(x: 1080, y: 520, width: 320, height: 320))
            for (index, color) in [(0.36, 0.52, 0.42), (0.24, 0.40, 0.33)].enumerated() {
                context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                context.move(to: CGPoint(x: 0, y: 0))
                for x in stride(from: 0, through: 1600, by: 20) {
                    context.addLine(to: CGPoint(x: Double(x), y: 330 - Double(index) * 110 + sin(Double(x) / (220 - Double(index) * 60)) * 70))
                }
                context.addLine(to: CGPoint(x: 1600, y: 0))
                context.fillPath()
            }
            // The card (drawing with AppKit for text).
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let card = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 680, height: 290), xRadius: 22, yRadius: 22)
            NSColor(white: 1, alpha: 0.96).setFill()
            card.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1)]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .regular), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
            NSAttributedString(string: "Boarding pass", attributes: title).draw(at: NSPoint(x: 130, y: 290))
            NSAttributedString(string: "Passenger  Jane Appleseed", attributes: body).draw(at: NSPoint(x: 130, y: 215))
            NSAttributedString(string: "Booking  QX7-4815-1623", attributes: body).draw(at: NSPoint(x: 130, y: 150))
            NSGraphicsContext.restoreGraphicsState()
        }), let data = try? ImageEngine.encode(image, format: .png, quality: 1), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
#endif
