import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Photo tools from the ⌥⇧ wheel.
enum ImageTools {
    // MARK: Size

    static func compress(_ input: URL, level: Int) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        if let source = loaded.format, ImageEngine.canAnimate(source), ImageEngine.isAnimated(input) {
            return try await compressAnimation(input, format: source, level: level)
        }
        let maxEdge = [0, 3840, 2048][level]
        let image = maxEdge > 0 ? try ImageEngine.scaled(loaded.image, maxEdge: maxEdge) : loaded.image
        let format: ImageFormat
        if let source = loaded.format, source.isLossy, source != .webp || ToolLocator.find("cwebp") != nil {
            format = source
        } else {
            format = image.hasAlpha ? .heic : .jpeg
        }
        let output = Output.file(beside: input, suffix: "compressed", ext: format.ext)
        // Deliberately keeps all metadata, GPS included: Compress is about size, and people expect a smaller copy of
        // the same photo (date, location, camera) in their library. Stripping is Remove Metadata's job, and Redact's.
        try await ImageEngine.write(image, to: output, format: format, quality: [0.82, 0.68, 0.5][level], properties: loaded.properties)
        return output
    }

    /// Animated GIF/WebP stay animated in their own format; frames shrink to keep the file small.
    private static func compressAnimation(_ input: URL, format: ImageFormat, level: Int) async throws -> URL {
        var animation = try ImageEngine.loadAnimation(input)
        let maxEdge = [0, 720, 480][level]
        if maxEdge > 0 {
            animation.frames = try animation.frames.map { frame in
                try Task.checkCancellation()
                return ImageEngine.Frame(image: try ImageEngine.scaled(frame.image, maxEdge: maxEdge), delay: frame.delay)
            }
        }
        let output = Output.file(beside: input, suffix: "compressed", ext: format.ext)
        try await ImageEngine.writeAnimation(animation, to: output, format: format, quality: [0.82, 0.68, 0.5][level])
        return output
    }

    /// Searches quality (then resolution) for the best image that fits in `bytes`.
    static func fit(_ input: URL, bytes: Double) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let format: ImageFormat = loaded.format == .heic || loaded.image.hasAlpha ? .heic : .jpeg
        var image = loaded.image
        let limit = Int(bytes)

        func encode(_ quality: Double) throws -> Data {
            try ImageEngine.encode(image, format: format, quality: quality, properties: loaded.properties)
        }

        for _ in 0..<10 {
            let smallest = try encode(0.05)
            guard smallest.count <= limit else {
                image = try ImageEngine.scaled(image, by: 0.75)
                continue
            }
            var best = smallest
            let top = try encode(0.95)
            if top.count <= limit {
                best = top
            } else {
                var low = 0.05, high = 0.95
                for _ in 0..<7 {
                    let mid = (low + high) / 2
                    let data = try encode(mid)
                    if data.count <= limit { best = data; low = mid } else { high = mid }
                }
            }
            let output = Output.file(beside: input, suffix: bytes.megabytes, ext: format.ext)
            try best.write(to: output)
            return output
        }
        throw ClementineError.message("Couldn't get \(input.lastPathComponent) under \(bytes.megabytes).")
    }

    static let resizeOptions = ["75%", "50%", "25%", "Max 3840 px", "Max 1920 px", "Max 1280 px"]

    static func resize(_ input: URL, choice: Int) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let edit = { (image: CGImage) throws -> CGImage in
            switch choice {
            case 0, 1, 2: return try ImageEngine.scaled(image, by: [0.75, 0.5, 0.25][choice])
            default: return try ImageEngine.scaled(image, maxEdge: [3840, 1920, 1280][choice - 3])
            }
        }
        let image = try edit(loaded.image)
        return try await ImageEngine.saveEdit(image, from: input, loaded: loaded, suffix: "\(image.width)×\(image.height)", frames: edit)
    }

    // MARK: Geometry

    static let cropOptions = ["Square 1:1", "4:5", "4:3", "3:2", "16:9", "9:16"]

    static func crop(_ input: URL, choice: Int) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let ratio = [1.0, 4.0 / 5, 4.0 / 3, 3.0 / 2, 16.0 / 9, 9.0 / 16][choice]
        let width = Double(loaded.image.width), height = Double(loaded.image.height)
        let size = width / height > ratio ? CGSize(width: height * ratio, height: height) : CGSize(width: width, height: width / ratio)
        let rect = CGRect(x: ((width - size.width) / 2).rounded(), y: ((height - size.height) / 2).rounded(),
                          width: size.width.rounded(), height: size.height.rounded())
        let edit = { (image: CGImage) throws -> CGImage in
            guard let cropped = image.cropping(to: rect) else { throw ClementineError.message("Couldn't crop the image.") }
            return cropped
        }
        return try await ImageEngine.saveEdit(try edit(loaded.image), from: input, loaded: loaded, suffix: "cropped", frames: edit)
    }

    static let rotateOptions = ["90° clockwise", "90° counterclockwise", "180°", "Flip horizontally", "Flip vertically"]

    static func rotate(_ input: URL, choice: Int) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let edit = { (source: CGImage) throws -> CGImage in
            let w = source.width, h = source.height
            let swaps = choice < 2
            return try ImageEngine.render(width: swaps ? h : w, height: swaps ? w : h, colorSpace: source.colorSpace) { context in
                switch choice {
                case 0: context.translateBy(x: 0, y: CGFloat(w)); context.rotate(by: -.pi / 2)
                case 1: context.translateBy(x: CGFloat(h), y: 0); context.rotate(by: .pi / 2)
                case 2: context.translateBy(x: CGFloat(w), y: CGFloat(h)); context.rotate(by: .pi)
                case 3: context.translateBy(x: CGFloat(w), y: 0); context.scaleBy(x: -1, y: 1)
                default: context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
                }
                context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return try await ImageEngine.saveEdit(try edit(loaded.image), from: input, loaded: loaded,
                                              suffix: choice < 3 ? "rotated" : "flipped", frames: edit)
    }

    // MARK: Adjust

    private static let ciContext = CIContext()

    static func adjusted(_ image: CGImage, _ params: ParamValues) throws -> CGImage {
        var output = CIImage(cgImage: image)
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = output
        exposure.ev = Float(params.number("exposure"))
        output = exposure.outputImage ?? output

        let color = CIFilter.colorControls()
        color.inputImage = output
        color.brightness = Float(params.number("brightness"))
        color.contrast = Float(params.number("contrast"))
        color.saturation = Float(params.number("saturation"))
        output = color.outputImage ?? output

        let tones = CIFilter.highlightShadowAdjust()
        tones.inputImage = output
        tones.highlightAmount = Float(params.number("highlights"))
        tones.shadowAmount = Float(params.number("shadows"))
        output = tones.outputImage ?? output

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Render back into the source's color space so Display P3 (or any RGB profile) survives the edit.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ciContext.createCGImage(output.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space) else {
            throw ClementineError.message("Couldn't apply the adjustments.")
        }
        return result
    }

    static func adjust(_ input: URL, params: ParamValues) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        return try await ImageEngine.saveEdit(try adjusted(loaded.image, params), from: input, loaded: loaded, suffix: "edited",
                                              frames: { try adjusted($0, params) })
    }

    // MARK: Background

    static let backgrounds: [(name: String, colors: [UInt32])] = [
        ("Sunset", [0xFF9A44, 0xFC6076]),
        ("Ocean", [0x2BC0E4, 0x1E5799]),
        ("Mint", [0xA8FF78, 0x78FFD6]),
        ("Lavender", [0xC471F5, 0xFA71CD]),
        ("Sky", [0xE0F7FF, 0x7FD3FF]),
        ("White", [0xFFFFFF, 0xF1F1F1]),
        ("Graphite", [0x3A3A3C, 0x111111]),
    ]

    static func withBackground(_ image: CGImage, _ params: ParamValues) throws -> CGImage {
        let longEdge = Double(max(image.width, image.height))
        let pad = Int(longEdge * params.number("padding"))
        let radius = longEdge * params.number("corners")
        let width = image.width + pad * 2, height = image.height + pad * 2
        let colors = backgrounds[min(params.choice("background"), backgrounds.count - 1)].colors.map { hex in
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return try ImageEngine.render(width: width, height: height) { context in
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
            let rect = CGRect(x: pad, y: pad, width: image.width, height: image.height)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if params.choice("shadow") == 0 && pad > 0 {
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -Double(pad) * 0.12), blur: Double(pad) * 0.6,
                                  color: CGColor(gray: 0, alpha: 0.35))
                context.addPath(path)
                context.setFillColor(.white)
                context.fillPath()
                context.restoreGState()
            }
            context.addPath(path)
            context.clip()
            context.draw(image, in: rect)
        }
    }

    static func addBackground(_ input: URL, params: ParamValues) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let output = Output.file(beside: input, suffix: "background", ext: "png")
        try await ImageEngine.write(try withBackground(loaded.image, params), to: output, format: .png)
        return output
    }

    // MARK: Metadata

    static func metadata(_ input: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { throw ClementineError.unreadable(input) }
        var lines = describe(properties)
        if let size = try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            lines.insert("File size: \(Double(size).megabytes)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ dictionary: [String: Any], indent: String = "") -> [String] {
        dictionary.keys.sorted().flatMap { key -> [String] in
            let value = dictionary[key]!
            let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if let nested = value as? [String: Any] {
                return ["", "\(indent)\(name)"] + describe(nested, indent: indent + "    ")
            }
            if let list = value as? [Any] {
                return ["\(indent)\(name): \(list.map { "\($0)" }.joined(separator: ", "))"]
            }
            return ["\(indent)\(name): \(value)"]
        }
    }

    /// Re-encodes the pixels with no metadata at all (orientation is baked in first).
    static func stripMetadata(_ input: URL) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let format = ImageEngine.editFormat(for: loaded)
        let output = Output.file(beside: input, suffix: "no metadata", ext: format.ext)
        if ImageEngine.canAnimate(format), ImageEngine.isAnimated(input) {
            // Re-encoded frames carry only timing, no metadata.
            try await ImageEngine.writeAnimation(try ImageEngine.loadAnimation(input), to: output, format: format,
                                                 quality: max(Prefs.imageQuality, 0.92))
            return output
        }
        try await ImageEngine.write(loaded.image, to: output, format: format, quality: max(Prefs.imageQuality, 0.92))
        return output
    }

    // MARK: Multiple images

    static let collageLayouts = ["Grid", "Row", "Column"]

    static func collage(_ inputs: [URL], layout: Int) async throws -> URL {
        let images = try inputs.map { try Task.checkCancellation(); return try ImageEngine.load($0, maxPixel: 2400).image }
        let gap = 24
        let canvas: CGImage
        switch layout {
        case 1, 2:
            // Row: equal heights. Column: equal widths.
            let horizontal = layout == 1
            // Shrink the shared side so very wide rows / tall columns stay encodable (long edge ≤ maxCanvas).
            let maxCanvas = 16000
            let extent = images.reduce(0.0) { total, image in
                total + (horizontal ? Double(image.width) / Double(image.height) : Double(image.height) / Double(image.width))
            }
            let room = Double(maxCanvas - gap * (images.count + 1))
            let side = max(min(1200, Int(room / extent)), 1)
            let sizes = images.map { image -> CGSize in
                let ratio = Double(image.width) / Double(image.height)
                return horizontal ? CGSize(width: (Double(side) * ratio).rounded(), height: Double(side))
                                  : CGSize(width: Double(side), height: (Double(side) / ratio).rounded())
            }
            let length = Int(sizes.reduce(0) { $0 + (horizontal ? $1.width : $1.height) }) + gap * (images.count + 1)
            let width = horizontal ? length : side + gap * 2
            let height = horizontal ? side + gap * 2 : length
            canvas = try ImageEngine.render(width: width, height: height) { context in
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                var offset = Double(gap)
                for (image, size) in zip(images, sizes) {
                    let rect = horizontal
                        ? CGRect(x: offset, y: Double(gap), width: size.width, height: size.height)
                        : CGRect(x: Double(gap), y: Double(height) - offset - size.height, width: size.width, height: size.height)
                    context.draw(image, in: rect)
                    offset += (horizontal ? size.width : size.height) + Double(gap)
                }
            }
        default:
            let columns = Int(Double(images.count).squareRoot().rounded(.up))
            let rows = (images.count + columns - 1) / columns
            let tile = 1000
            let width = columns * tile + (columns + 1) * gap
            let height = rows * tile + (rows + 1) * gap
            canvas = try ImageEngine.render(width: width, height: height) { context in
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                for (index, image) in images.enumerated() {
                    let column = index % columns, row = index / columns
                    let cell = CGRect(x: gap + column * (tile + gap), y: height - (row + 1) * (tile + gap), width: tile, height: tile)
                    // Aspect-fill each tile.
                    let scale = max(cell.width / Double(image.width), cell.height / Double(image.height))
                    let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                    context.saveGState()
                    context.clip(to: cell)
                    context.draw(image, in: CGRect(x: cell.midX - drawn.width / 2, y: cell.midY - drawn.height / 2,
                                                   width: drawn.width, height: drawn.height))
                    context.restoreGState()
                }
            }
        }
        let output = Output.file(beside: inputs[0], name: "Collage", ext: "jpg")
        try await ImageEngine.write(canvas, to: output, format: .jpeg, quality: 0.9)
        return output
    }

    static func makePDF(_ inputs: [URL]) async throws -> URL {
        let output = Output.file(beside: inputs[0], suffix: "combined", ext: "pdf")
        try await Output.produce(output) { try ImageEngine.writePDF(inputs, to: output) }
        return output
    }

    // MARK: Previews

    static func preview(_ input: URL, _ transform: (CGImage) throws -> CGImage) -> NSImage? {
        guard let image = try? ImageEngine.load(input, maxPixel: 900).image,
              let result = try? transform(image) else { return nil }
        return ImageEngine.nsImage(result)
    }
}
