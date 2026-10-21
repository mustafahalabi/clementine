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

        // Welcome tour, one PNG per page (demo frozen on a hovered slice).
        for page in 0..<OnboardingView.pageCount {
            snapshotWindow(NSHostingController(rootView: OnboardingView(initialStep: page, live: false)),
                           appearance: appearance, settle: 1.2, to: out("onboarding-\(page + 1)"))
        }
        renderProductivity(appearance: appearance, out: out)
        renderWaveformEditors(appearance: appearance, media: media, out: out)
        renderPDFAndMetadata(appearance: appearance, image: image, out: out)
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
        let cards = VStack(spacing: 14) {
            ForEach([offer, undone, partial], id: \.detail) { job in
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
#endif
