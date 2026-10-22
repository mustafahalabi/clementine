#if DEBUG
import AppKit
import SwiftUI

/// Dev aid: draws the job windows and Settings to PNGs without putting anything on screen.
/// `Clementine --render-ui <dir> [image] [audio] [video]`, in light and dark (materials render flat).
@MainActor
enum UIPreview {
    static func handle(_ arguments: [String]) -> Bool {
        guard arguments.first == "--render-ui", arguments.count >= 2 else { return false }
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil
            let media = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(appearance: NSAppearance(named: appearance)!, suffix: name, image: image, media: media, to: directory)
            }
        }
        return true
    }

    private static func render(appearance: NSAppearance, suffix: String, image: URL?, media: [URL], to directory: URL) {
        func out(_ name: String) -> URL { directory.appendingPathComponent("\(name)-\(suffix).png") }

        // Progress cards, stacked as they'd be on screen.
        let running = RunningJob(title: "Convert to WebP", symbol: "photo", detail: "IMG_2041 holiday in Lisbon.heic")
        running.progress = 0.62
        let indeterminate = RunningJob(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "screen-recording.mov")
        let done = RunningJob(title: "Convert to MP3", symbol: "music.note", detail: "interview.m4a")
        done.progress = 1
        done.state = .done
        let failed = RunningJob(title: "Target Size", symbol: "scalemass", detail: "clip.mov")
        failed.state = .failed(ClementineError.missingTool("ffmpeg").localizedDescription)
        // A batch where several files failed: collapsed behind "Show details…", then opened.
        let noisy = ClementineError.toolFailed("ffmpeg", """
            [mov,mp4,m4a,3gp,3g2,mj2 @ 0x600001] moov atom not found
            [in#0 @ 0x600002] Error opening input: Invalid data found when processing input
            Error opening input file /Users/me/Movies/broken take 3.mov.
            """).localizedDescription
        let batchFailure = (1...3).map { "take \($0).mov: \(noisy)" }.joined(separator: "\n")
        let manyFailed = RunningJob(title: "Convert to MP4", symbol: "film", detail: "3 of 3 done")
        manyFailed.state = .failed(batchFailure)
        let manyOpen = RunningJob(title: "Convert to MP4 ", symbol: "film", detail: "3 of 3 done ")
        manyOpen.state = .failed(batchFailure)
        let cards = VStack(spacing: 14) {
            ForEach([running, indeterminate, done, failed, manyFailed], id: \.detail) { job in
                JobView(job: job, cancel: {}, dismiss: {}).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            }
            JobView(job: manyOpen, cancel: {}, dismiss: {}, expanded: true).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
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

        // Menu bar icon, plain and with the update-available dot, tinted the way the menu bar tints templates.
        let icons = HStack(spacing: 18) {
            ForEach([false, true], id: \.self) { badged in
                Image(nsImage: MenuBarIcon.image(badged: badged)).renderingMode(.template).scaleEffect(2)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        snapshot(NSHostingView(rootView: icons), appearance: appearance, to: out("menubar-icon"))

        // Welcome tour, one PNG per page (demo frozen on a hovered slice).
        for page in 0..<OnboardingView.pageCount {
            snapshotWindow(NSHostingController(rootView: OnboardingView(initialStep: page, live: false)),
                           appearance: appearance, settle: 1.2, to: out("onboarding-\(page + 1)"))
        }
        renderProductivity(appearance: appearance, out: out)
        renderWaveformEditors(appearance: appearance, media: media, out: out)
        renderPDFAndMetadata(appearance: appearance, image: image, out: out)
        renderImageEditors(appearance: appearance, out: out)
    }

    /// Undo on finished cards, and Settings › Wheel.
    private static func renderProductivity(appearance: NSAppearance, out: (String) -> URL) {
        let offer = RunningJob(title: "Convert to JPG", symbol: "arrow.triangle.2.circlepath", detail: "12 of 12 done")
        offer.progress = 1
        offer.state = .done
        offer.undo = {}
        let undone = RunningJob(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Moved 3 items to the Trash")
        undone.progress = 1
        undone.state = .done
        undone.undo = {}
        undone.undone = true
        let partial = RunningJob(title: "Convert to WebP", symbol: "arrow.triangle.2.circlepath", detail: "9 of 10 done")
        partial.state = .failed("broken.png: Couldn't read broken.png.")
        partial.undo = {}
        let kept = RunningJob(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: JobOutput.keptOriginal)
        kept.progress = 1
        kept.state = .done
        let cards = VStack(spacing: 14) {
            ForEach([offer, undone, partial, kept], id: \.detail) { job in
                JobView(job: job, cancel: {}, dismiss: {}).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(hex: 0x6E8CA8), Color(hex: 0xB59BC4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        snapshot(NSHostingView(rootView: cards), appearance: appearance, to: out("progress-undo"))

        snapshotWindow(NSHostingController(rootView: SettingsView(tab: .wheel)), appearance: appearance, settle: 1.6, to: out("settings-wheel"))
        let tools = WheelSettingsView(kind: "audio", mode: .tools).frame(width: 520).background(WindowBackdrop()).tint(Theme.tangerine)
        snapshotWindow(NSHostingController(rootView: tools), appearance: appearance, settle: 1.6, to: out("settings-wheel-tools"))
    }

    /// Trim, Bleep and Channels editors with real peaks read from the given audio and video files.
    private static func renderWaveformEditors(appearance: NSAppearance, media: [URL], out: (String) -> URL) {
        let audio = media.first { FileItem(url: $0).kind == .audio }
        let video = media.first { FileItem(url: $0).kind == .video }
        func settle(_ model: WaveformEditorModel) {
            model.load()
            let deadline = Date().addingTimeInterval(8)
            while model.waveform == nil && model.failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        if let trim = ActionRegistry.find("tool.media.trim") {
            let loading = TrimModel(url: URL(fileURLWithPath: "/tmp/voice memo.m4a"), values: trim.defaults)
            loading.holdsPlaceholder = true
            snapshotWindow(NSHostingController(rootView: TrimEditorView(model: loading, subtitle: "voice memo.m4a", onApply: { _ in }, onCancel: {})),
                           appearance: appearance, to: out("trim-loading"))
            for (name, url) in [("trim-audio", audio), ("trim-video", video)] {
                guard let url else { continue }
                var values = trim.defaults
                values.storage["start"] = .text("0:02.6")
                values.storage["end"] = .text("0:14.2")
                let model = TrimModel(url: url, values: values)
                settle(model)
                snapshotWindow(NSHostingController(rootView: TrimEditorView(model: model, subtitle: url.lastPathComponent,
                                                                            onApply: { _ in }, onCancel: {})),
                               appearance: appearance, settle: 1, to: out(name))
                if name == "trim-audio" {
                    model.setTrimsSilence(true)
                    snapshotWindow(NSHostingController(rootView: TrimEditorView(model: model, subtitle: url.lastPathComponent,
                                                                                onApply: { _ in }, onCancel: {})),
                                   appearance: appearance, settle: 0.6, to: out("trim-audio-silence"))
                }
                model.close()
            }
        }
        if let bleep = ActionRegistry.find("tool.audio.bleep"), let url = audio ?? video {
            for (name, ranges) in [("bleep", "0:04.1-0:04.9, 0:08.3-0:09.4, 0:12-0:12.6"), ("bleep-empty", "")] {
                var values = bleep.defaults
                values.storage["ranges"] = .text(ranges)
                let model = BleepModel(url: url, values: values)
                settle(model)
                if !ranges.isEmpty { model.playback.time = 6.2 }
                snapshotWindow(NSHostingController(rootView: BleepEditorView(model: model, subtitle: url.lastPathComponent,
                                                                             onApply: { _ in }, onCancel: {})),
                               appearance: appearance, settle: 1, to: out(name))
                model.close()
            }
        }
        if let channels = ActionRegistry.find("tool.audio.channels"), let url = audio {
            for (name, layout, left, right) in [("channels-swap", 2, 0.6, 1.4), ("channels-mono", 0, 1.0, 1.0)] {
                var values = channels.defaults
                values.storage["channels"] = .choice(layout)
                values.storage["left"] = .number(left)
                values.storage["right"] = .number(right)
                let model = ChannelsModel(url: url, values: values)
                settle(model)
                snapshotWindow(NSHostingController(rootView: ChannelsEditorView(model: model, subtitle: url.lastPathComponent,
                                                                                onApply: { _ in }, onCancel: {})),
                               appearance: appearance, settle: 1, to: out(name))
                model.close()
            }
        }
    }

    // MARK: Page organizer and metadata editor

    private static func renderPDFAndMetadata(appearance: NSAppearance, image: URL?, out: (String) -> URL) {
        let fixtures = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clementine-ui-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let report = fixtures.appendingPathComponent("Quarterly report.pdf")
        let slides = fixtures.appendingPathComponent("Slides.pdf")
        samplePDF(report, pages: 9, landscape: false, hue: 0.07)
        samplePDF(slides, pages: 3, landscape: true, hue: 0.42)

        if let model = try? PageOrganizerModel(urls: [report], merging: false) {
            let ids = model.tiles.map(\.id)
            model.select(ids[2], modifiers: [])
            model.rotate(clockwise: true)
            model.move([ids[2]], to: 0)
            model.select(ids[4], modifiers: [])
            model.select(ids[5], modifiers: .shift)
            let view = PageOrganizerView(model: model, title: "Pages", symbol: "doc.on.doc", onApply: { _ in }, onCancel: {})
                .frame(width: 780, height: 640)
            snapshotWindow(NSHostingController(rootView: view), appearance: appearance, settle: 1.5, to: out("pages"))
            let dragging = PageOrganizerView(model: model, title: "Pages", symbol: "doc.on.doc", onApply: { _ in }, onCancel: {},
                                             previewDrag: CGPoint(x: 470, y: 250))
                .frame(width: 780, height: 640)
            snapshotWindow(NSHostingController(rootView: dragging), appearance: appearance, settle: 1.5, to: out("pages-drag"))
        }
        if let model = try? PageOrganizerModel(urls: [report, slides], merging: true) {
            let ids = model.tiles.map(\.id)
            model.move([ids[9], ids[10]], to: 1)
            model.select(ids[9], modifiers: [])
            model.duplicate()
            let view = PageOrganizerView(model: model, title: "Merge", symbol: "square.stack", onApply: { _ in }, onCancel: {})
                .frame(width: 780, height: 600)
            snapshotWindow(NSHostingController(rootView: view), appearance: appearance, settle: 1.5, to: out("merge"))
        }

        let photo = fixtures.appendingPathComponent("IMG_2041.jpg")
        samplePhoto(photo, from: image)
        if let snapshot = wait({ try await MetadataEngine.read(photo) }) {
            let model = MetadataEditorModel(url: photo, snapshot: snapshot, preview: NSImage(contentsOf: photo))
            model.values["title"] = "Golden hour in Alfama"
            model.values["keywords"] = "Lisbon, sunset, tram 28"
            model.values["rating"] = "4"
            model.values["date"] = "2026-07-14 18:42:09"
            model.removeLocation = true
            let view = MetadataEditorView(model: model, onSave: { _ in }, onCancel: {}).frame(width: 540, height: 760)
            snapshotWindow(NSHostingController(rootView: view), appearance: appearance, settle: 0.8, to: out("metadata-image"))

            model.values["date"] = "2026-02-30"
            let open = MetadataEditorView(model: model, onSave: { _ in }, onCancel: {}, showsAll: true).frame(width: 540, height: 900)
            snapshotWindow(NSHostingController(rootView: open), appearance: appearance, settle: 0.8, to: out("metadata-image-all"))
        }
        if let snapshot = wait({ try await MetadataEngine.read(report) }) {
            let model = MetadataEditorModel(url: report, snapshot: snapshot, preview: NSWorkspace.shared.icon(forFile: report.path))
            model.values["author"] = "Mustafa"
            let view = MetadataEditorView(model: model, onSave: { _ in }, onCancel: {}).frame(width: 540, height: 600)
            snapshotWindow(NSHostingController(rootView: view), appearance: appearance, settle: 0.5, to: out("metadata-pdf"))
        }
    }

    /// Runs async work to completion from the synchronous render loop.
    private static func wait<T>(_ work: @escaping @MainActor () async throws -> T) -> T? {
        var result: T?
        var finished = false
        Task { @MainActor in
            result = try? await work()
            finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return result
    }

    /// A believable document: a heading, text lines and a colored figure on every page.
    private static func samplePDF(_ url: URL, pages: Int, landscape: Bool, hue: CGFloat) {
        var box = landscape ? CGRect(x: 0, y: 0, width: 792, height: 612) : CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Quarterly report", kCGPDFContextAuthor: "Ana Sousa"] as CFDictionary)
        else { return }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let color = NSColor(hue: (hue + CGFloat(index) * 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.95, alpha: 1)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 60, y: box.height - 300, width: box.width - 120, height: 170), xRadius: 14, yRadius: 14).fill()
            let heading = landscape ? "Slide \(index + 1)" : "Section \(index + 1)"
            (heading as NSString).draw(at: NSPoint(x: 60, y: box.height - 110),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.black])
            NSColor(white: 0.78, alpha: 1).setFill()
            for line in 0..<(landscape ? 6 : 14) {
                let width = (box.width - 120) * (line % 4 == 3 ? 0.6 : 1)
                NSBezierPath(roundedRect: NSRect(x: 60, y: box.height - 350 - CGFloat(line) * 30, width: width, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A JPEG with a camera, lens, GPS and a few tags, drawn from `source` when given.
    private static func samplePhoto(_ url: URL, from source: URL?) {
        var image = source.flatMap { try? ImageEngine.load($0, maxPixel: 1200).image }
        if image == nil {
            let size = NSSize(width: 1200, height: 800)
            let drawn = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.62, blue: 0.3, alpha: 1),
                                    NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.6, alpha: 1)])?.draw(in: rect, angle: -90)
                NSColor(calibratedRed: 1, green: 0.9, blue: 0.6, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 520, y: 300, width: 160, height: 160)).fill()
                return true
            }
            var rect = NSRect(origin: .zero, size: size)
            image = drawn.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                                             kCGImagePropertyTIFFArtist: "Ana Sousa"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "iPhone 15 Pro back triple camera 6.765mm f/1.78",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:07:14 18:42:09"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7139, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 9.1394, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["Lisbon", "sunset"]],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
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
