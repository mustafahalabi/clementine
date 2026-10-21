import Foundation

/// The ⌥⇧ wheel. Order here is the order around the wheel.
enum ToolActions {
    static let all: [Action] = shared + image + media + pdf + metadata

    static let compressLevels = ["Best quality", "Balanced", "Smallest"]
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    // MARK: Shared

    static let shared: [Action] = [
        Action(id: "tool.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", mode: .tools,
               parameters: [.choice("level", "Level", compressLevels, default: 1)],
               accepts: kinds(.image, .video, .audio),
               run: { ctx in
                   let level = ctx.params.choice("level")
                   if FileItem(url: ctx.input).kind == .image {
                       return .files([try await ImageTools.compress(ctx.input, level: level)])
                   }
                   return .files([try await MediaEngine.compress(ctx.input, level: level, progress: ctx.progress)])
               }),
        Action(id: "tool.pdf.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", mode: .tools,
               accepts: kinds(.pdf),
               run: { ctx in .files([try PDFEngine.compress(ctx.input)]) }),
        Action(id: "tool.fit", title: "Target Size", symbol: "scope", mode: .tools,
               parameters: [.number("megabytes", "Target size", 0.05...4000, unit: "MB", default: 5)],
               accepts: kinds(.image, .video, .audio),
               run: { ctx in
                   let bytes = ctx.params.number("megabytes") * 1_000_000
                   if FileItem(url: ctx.input).kind == .image {
                       return .files([try await ImageTools.fit(ctx.input, bytes: bytes)])
                   }
                   return .files([try await MediaEngine.fit(ctx.input, bytes: bytes, progress: ctx.progress)])
               }),
    ]

    // MARK: Images

    static let image: [Action] = [
        Action(id: "tool.image.resize", title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", mode: .tools,
               parameters: [.choice("size", "New size", ImageTools.resizeOptions, default: 1)],
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.resize(ctx.input, choice: ctx.params.choice("size"))]) }),
        Action(id: "tool.image.crop", title: "Crop", symbol: "crop", mode: .tools,
               parameters: [.choice("aspect", "Aspect ratio", ImageTools.cropOptions)],
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.crop(ctx.input, choice: ctx.params.choice("aspect"))]) }),
        Action(id: "tool.image.rotate", title: "Rotate", symbol: "rotate.right", mode: .tools,
               parameters: [.choice("rotation", "Rotation", ImageTools.rotateOptions)],
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.rotate(ctx.input, choice: ctx.params.choice("rotation"))]) }),
        Action(id: "tool.image.adjust", title: "Edit", symbol: "slider.horizontal.3", mode: .tools,
               parameters: [
                   .slider("exposure", "Exposure", -2...2, default: 0),
                   .slider("brightness", "Brightness", -0.5...0.5, default: 0),
                   .slider("contrast", "Contrast", 0.5...1.5, default: 1),
                   .slider("saturation", "Saturation", 0...2, default: 1),
                   .slider("highlights", "Highlights", 0...1, default: 1),
                   .slider("shadows", "Shadows", -1...1, default: 0),
               ],
               preview: { url, params in ImageTools.preview(url) { try ImageTools.adjusted($0, params) } },
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.adjust(ctx.input, params: ctx.params)]) }),
        Action(id: "tool.image.background", title: "Add BG", symbol: "photo.on.rectangle", mode: .tools,
               parameters: [
                   .choice("background", "Background", ImageTools.backgrounds.map(\.name)),
                   .slider("padding", "Padding", 0...0.3, default: 0.08),
                   .slider("corners", "Corner radius", 0...0.1, default: 0.02),
                   .choice("shadow", "Shadow", ["On", "Off"]),
               ],
               preview: { url, params in ImageTools.preview(url) { try ImageTools.withBackground($0, params) } },
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.addBackground(ctx.input, params: ctx.params)]) }),
        Action(id: "tool.image.qr", title: "Read QR", symbol: "qrcode.viewfinder", mode: .tools,
               accepts: kinds(.image),
               run: { ctx in .text(title: ctx.input.lastPathComponent, body: try ImageEngine.readCodes(ctx.input)) }),
        Action(id: "tool.image.collage", title: "Collage", symbol: "square.grid.2x2", mode: .tools, minInputs: 2, batch: true,
               parameters: [.choice("layout", "Layout", ImageTools.collageLayouts)],
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.collage(ctx.inputs, layout: ctx.params.choice("layout"))]) }),
        Action(id: "tool.image.pdf", title: "Make PDF", symbol: "doc.richtext", mode: .tools, minInputs: 2, batch: true,
               accepts: kinds(.image),
               run: { ctx in .files([try await ImageTools.makePDF(ctx.inputs)]) }),
    ]

    // MARK: Video & audio

    static let media: [Action] = [
        Action(id: "tool.media.trim", title: "Trim", symbol: "timeline.selection", mode: .tools,
               parameters: [
                   .text("start", "Start", placeholder: "0:00", default: "0:00"),
                   .text("end", "End", placeholder: "End of file"),
               ],
               accepts: kinds(.video, .audio),
               run: { ctx in .files([try await MediaEngine.trim(ctx.input, start: ctx.params.text("start"),
                                                                 end: ctx.params.text("end"), progress: ctx.progress)]) }),
        Action(id: "tool.media.speed", title: "Speed", symbol: "gauge.with.dots.needle.67percent", mode: .tools,
               parameters: [.choice("speed", "Speed", speeds.map { "\(MediaEngine.formatSpeed($0))×" }, default: 5)],
               accepts: kinds(.video, .audio),
               run: { ctx in .files([try await MediaEngine.changeSpeed(ctx.input, speed: speeds[ctx.params.choice("speed")],
                                                                        progress: ctx.progress)]) }),
        Action(id: "tool.media.split", title: "Split", symbol: "scissors", mode: .tools,
               parameters: [.number("seconds", "Part length", 1...36000, unit: "sec", default: 60)],
               accepts: kinds(.video, .audio),
               run: { ctx in .files([try await MediaEngine.split(ctx.input, every: ctx.params.number("seconds"), progress: ctx.progress)]) }),
        Action(id: "tool.video.snapshot", title: "Snapshot", symbol: "camera", mode: .tools,
               parameters: [.choice("frames", "Frames", ["Middle frame", "First frame", "10 across the video"])],
               accepts: kinds(.video),
               run: { ctx in .files(try await MediaEngine.snapshots(ctx.input, mode: ctx.params.choice("frames"), progress: ctx.progress)) }),
        Action(id: "tool.video.mute", title: "Mute", symbol: "speaker.slash", mode: .tools,
               accepts: kinds(.video),
               run: { ctx in .files([try await MediaEngine.mute(ctx.input, progress: ctx.progress)]) }),
        Action(id: "tool.video.rotate", title: "Rotate", symbol: "rotate.right", mode: .tools,
               parameters: [.choice("rotation", "Rotation", ["90° clockwise", "90° counterclockwise", "180°", "Flip horizontally"])],
               accepts: kinds(.video),
               run: { ctx in .files([try await MediaEngine.rotate(ctx.input, choice: ctx.params.choice("rotation"), progress: ctx.progress)]) }),
        Action(id: "tool.video.join", title: "Join", symbol: "link", mode: .tools, minInputs: 2, batch: true,
               accepts: kinds(.video),
               run: { ctx in .files([try await MediaEngine.joinVideos(ctx.inputs, progress: ctx.progress)]) }),
        Action(id: "tool.audio.normalize", title: "Normalize", symbol: "waveform", mode: .tools,
               accepts: kinds(.audio),
               run: { ctx in .files([try await MediaEngine.normalize(ctx.input, progress: ctx.progress)]) }),
        Action(id: "tool.audio.silence", title: "Trim Silence", symbol: "waveform.path", mode: .tools,
               accepts: kinds(.audio),
               run: { ctx in .files([try await MediaEngine.trimSilence(ctx.input, progress: ctx.progress)]) }),
        Action(id: "tool.audio.channels", title: "Channels", symbol: "speaker.wave.2", mode: .tools,
               parameters: [.choice("channels", "Output", ["Mono", "Stereo"])],
               accepts: kinds(.audio),
               run: { ctx in .files([try await MediaEngine.channels(ctx.input, mono: ctx.params.choice("channels") == 0,
                                                                     progress: ctx.progress)]) }),
        Action(id: "tool.audio.bleep", title: "Bleep", symbol: "exclamationmark.bubble", mode: .tools,
               parameters: [.text("ranges", "Bleep ranges", placeholder: "0:05-0:06, 1:10-1:12")],
               accepts: kinds(.audio),
               run: { ctx in .files([try await MediaEngine.bleep(ctx.input, ranges: ctx.params.text("ranges"), progress: ctx.progress)]) }),
        Action(id: "tool.audio.join", title: "Join", symbol: "link", mode: .tools, minInputs: 2, batch: true,
               accepts: kinds(.audio),
               run: { ctx in .files([try await MediaEngine.joinAudio(ctx.inputs, progress: ctx.progress)]) }),
    ]

    // MARK: PDF

    static let pdf: [Action] = [
        Action(id: "tool.pdf.pages", title: "Pages", symbol: "doc.on.doc", mode: .tools,
               parameters: [.text("pages", "Pages to keep, in order", placeholder: "3, 1-2, 5-")],
               accepts: kinds(.pdf),
               run: { ctx in .files([try PDFEngine.pick(ctx.input, spec: ctx.params.text("pages"))]) }),
        Action(id: "tool.pdf.split", title: "Split", symbol: "scissors", mode: .tools,
               accepts: kinds(.pdf),
               run: { ctx in .files([try await PDFEngine.split(ctx.input)]) }),
        Action(id: "tool.pdf.rotate", title: "Rotate", symbol: "rotate.right", mode: .tools,
               parameters: [.choice("rotation", "Rotation", PDFEngine.rotateOptions)],
               accepts: kinds(.pdf),
               run: { ctx in .files([try PDFEngine.rotate(ctx.input, choice: ctx.params.choice("rotation"))]) }),
        Action(id: "tool.pdf.merge", title: "Merge", symbol: "square.stack", mode: .tools, minInputs: 2, batch: true,
               accepts: kinds(.pdf),
               run: { ctx in .files([try PDFEngine.merge(ctx.inputs)]) }),
    ]

    // MARK: Metadata

    static let metadata: [Action] = [
        Action(id: "tool.metadata", title: "Metadata", symbol: "tag", mode: .tools,
               accepts: kinds(.image, .video, .audio, .pdf),
               run: { ctx in
                   let body: String
                   switch FileItem(url: ctx.input).kind {
                   case .image: body = try ImageTools.metadata(ctx.input)
                   case .pdf: body = try PDFEngine.metadata(ctx.input)
                   default: body = try await MediaEngine.metadata(ctx.input)
                   }
                   return .text(title: ctx.input.lastPathComponent, body: body)
               }),
        Action(id: "tool.metadata.strip", title: "Remove Metadata", symbol: "tag.slash", mode: .tools,
               accepts: kinds(.image, .video, .audio, .pdf),
               run: { ctx in
                   switch FileItem(url: ctx.input).kind {
                   case .image: return .files([try await ImageTools.stripMetadata(ctx.input)])
                   case .pdf: return .files([try PDFEngine.stripMetadata(ctx.input)])
                   default: return .files([try await MediaEngine.stripMetadata(ctx.input, progress: ctx.progress)])
                   }
               }),
    ]
}
