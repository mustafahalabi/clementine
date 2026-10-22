import Accelerate
import AppKit
import ImageIO
import PDFKit
import Vision

enum ImageFormat: String, CaseIterable {
    case jpeg, png, heic, webp, avif, tiff, bmp, gif, pdf

    init?(ext: String) {
        let ext = ext.lowercased()
        guard let match = Self.allCases.first(where: { $0.aliases.contains(ext) }) else { return nil }
        self = match
    }

    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var label: String { self == .jpeg ? "JPG" : rawValue.uppercased() }

    var aliases: [String] {
        switch self {
        case .jpeg: return ["jpg", "jpeg", "jpe"]
        case .tiff: return ["tif", "tiff"]
        case .heic: return ["heic", "heif"]
        default: return [rawValue]
        }
    }

    var utType: String? {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .webp, .pdf: return nil
        }
    }

    var supportsAlpha: Bool { self != .jpeg && self != .bmp }
    var isLossy: Bool { [.jpeg, .heic, .webp, .avif].contains(self) }
}

struct LoadedImage {
    let image: CGImage
    /// Source metadata with orientation reset, since pixels are already upright.
    let properties: [CFString: Any]
    let format: ImageFormat?

    /// `properties` without what identifies where, by whom or with which camera a photo was taken: GPS, maker
    /// notes, serial numbers, owner name, user comment, IPTC location and Photoshop resources (which can carry a
    /// full-size thumbnail of the unredacted image). Orientation, color and capture settings stay.
    var shareableProperties: [CFString: Any] {
        var kept = properties
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary, kCGImageProperty8BIMDictionary,
                    kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
                    kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerMinoltaDictionary,
                    kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
                    kCGImagePropertyMakerPentaxDictionary] {
            kept.removeValue(forKey: key)
        }
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote, kCGImagePropertyExifCameraOwnerName,
                        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
                        kCGImagePropertyExifImageUniqueID, kCGImagePropertyExifSubjectLocation,
                        kCGImagePropertyExifSubjectArea] {
                exif.removeValue(forKey: key)
            }
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if var iptc = kept[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
                        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
                        kCGImagePropertyIPTCCreatorContactInfo] {
                iptc.removeValue(forKey: key)
            }
            kept[kCGImagePropertyIPTCDictionary] = iptc
        }
        return kept
    }
}

enum ImageEngine {
    // MARK: Loading

    /// Loads the first frame, upright, optionally downscaled so the long edge is at most `maxPixel`.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> LoadedImage {
        if url.pathExtension.lowercased() == "svg" {
            return LoadedImage(image: try rasterize(url, maxPixel: maxPixel ?? 2048), properties: [:], format: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ClementineError.unreadable(url)
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let longEdge = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)

        let image: CGImage?
        if longEdge > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longEdge, longEdge),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw ClementineError.unreadable(url) }

        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            properties.removeValue(forKey: key)
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return LoadedImage(image: image, properties: properties, format: ImageFormat(ext: url.pathExtension))
    }

    private static func rasterize(_ url: URL, maxPixel: Int) throws -> CGImage {
        guard let vector = NSImage(contentsOf: url), vector.size.width > 0, vector.size.height > 0 else {
            throw ClementineError.unreadable(url)
        }
        let scale = CGFloat(maxPixel) / max(vector.size.width, vector.size.height)
        let width = Int(vector.size.width * scale), height = Int(vector.size.height * scale)
        return try render(width: width, height: height) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            vector.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Writing

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = Prefs.imageQuality,
                      properties: [CFString: Any]? = nil) async throws {
        try await Output.produce(url) {
            switch format {
            case .webp:
                try await writeWebP(image, to: url, quality: quality)
            case .pdf:
                try writePDF(image, to: url)
            default:
                try encode(image, format: format, quality: quality, properties: properties).write(to: url)
            }
        }
    }

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double, properties: [CFString: Any]? = nil) throws -> Data {
        guard let type = format.utType else { throw ClementineError.message("\(format.label) can't be encoded directly.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ClementineError.message("This Mac can't write \(format.label) images.")
        }
        let pixels = !format.supportsAlpha && image.hasAlpha ? try flatten(image) : image
        var options = properties ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ClementineError.message("Couldn't encode the image as \(format.label).")
        }
        return data as Data
    }

    /// ImageIO can read WebP but not write it, so this goes through `cwebp`.
    private static func writeWebP(_ image: CGImage, to url: URL, quality: Double) async throws {
        let cwebp = try ToolLocator.require("cwebp")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try encode(image, format: .png, quality: 1).write(to: temp)
        try await ProcessRunner.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", "icc", temp.path, "-o", url.path])
    }

    // MARK: PDF

    /// Pages are at most A4's long edge (11.69 in). Photos declare 72 dpi or nothing, which would otherwise make a
    /// 12 MP photo a 56 × 42 in page.
    static let maxPageEdge: CGFloat = 842
    /// Past this density extra pixels don't show on paper, so bigger images are decoded smaller.
    static let maxPageDPI: CGFloat = 400

    /// One page per image, streamed: each image is decoded, written and released before the next, so memory stays
    /// flat whatever the count. JPEGs that are upright and not oversized go in as they are, without re-encoding.
    static func writePDF(_ inputs: [URL], to url: URL) throws {
        let writer = try ImagePDFWriter(url: url)
        for input in inputs {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = try pdfPage(input)
                try writer.addPage(page.image, size: page.size)
            }
        }
        try writer.finish()
    }

    static func writePDF(_ image: CGImage, to url: URL) throws {
        let writer = try ImagePDFWriter(url: url)
        try writer.addPage(try pdfImage(image), size: pageSize(width: image.width, height: image.height, dpi: 72))
        try writer.finish()
    }

    /// Page size in points for an upright image: its own dpi when it declares a real one (scans), shrunk to fit
    /// `maxPageEdge`.
    private static func pageSize(width: Int, height: Int, dpi declared: CGFloat) -> CGSize {
        let dpi = max(declared > 72 ? declared : 72, CGFloat(max(width, height)) * 72 / maxPageEdge)
        return CGSize(width: CGFloat(width) * 72 / dpi, height: CGFloat(height) * 72 / dpi)
    }

    private static func pdfPage(_ input: URL) throws -> (image: ImagePDFWriter.Image, size: CGSize) {
        let source = CGImageSourceCreateWithURL(input as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&width, &height) }

        guard width > 0, height > 0 else {
            // SVG and anything else ImageIO can't size up front.
            let image = try load(input).image
            return (try pdfImage(image), pageSize(width: image.width, height: image.height, dpi: 72))
        }
        let page = pageSize(width: width, height: height, dpi: CGFloat(properties[kCGImagePropertyDPIWidth] as? Double ?? 72))
        let maxPixel = Int((max(page.width, page.height) / 72 * maxPageDPI).rounded())
        let model = properties[kCGImagePropertyColorModel] as? String
        if ImageFormat(ext: input.pathExtension) == .jpeg, orientation == 1, max(width, height) <= maxPixel,
           model == (kCGImagePropertyColorModelRGB as String) || model == (kCGImagePropertyColorModelGray as String),
           properties[kCGImagePropertyDepth] as? Int ?? 8 == 8,
           let jpeg = try? Data(contentsOf: input, options: .mappedIfSafe) {
            // Embedded byte for byte; only the color space is read, the pixels are never decoded.
            let space = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.colorSpace
            let gray = model == (kCGImagePropertyColorModelGray as String)
            return (ImagePDFWriter.Image(jpeg: jpeg, width: width, height: height, components: gray ? 1 : 3,
                                         icc: space?.copyICCData() as Data?, alpha: nil), page)
        }
        return (try pdfImage(try load(input, maxPixel: maxPixel).image), page)
    }

    /// Re-encodes decoded pixels for a PDF page: color as JPEG, transparency as a separate mask.
    private static func pdfImage(_ image: CGImage) throws -> ImagePDFWriter.Image {
        guard image.hasAlpha else {
            let color = try flatten(image)
            return ImagePDFWriter.Image(jpeg: try encode(color, format: .jpeg, quality: 0.9), width: color.width, height: color.height,
                                        components: 3, icc: color.colorSpace?.copyICCData() as Data?, alpha: nil)
        }
        // The mask is applied by the viewer, so the color must be un-premultiplied (not flattened onto white).
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = Data(count: width * height * 4)
        var alpha = Data(count: width * height)
        let color: CGImage? = try pixels.withUnsafeMutableBytes { rgba in
            guard let context = CGContext(data: rgba.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ClementineError.message("Couldn't allocate a \(width)×\(height) image.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(data: rgba.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            alpha.withUnsafeMutableBytes { mask in
                var plane = vImage_Buffer(data: mask.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                // Channel 3 of RGBA is alpha.
                _ = vImageExtractChannel_ARGB8888(&buffer, &plane, 3, vImage_Flags(kvImageNoFlags))
            }
            // The same bytes read as opaque RGB: the alpha byte is skipped.
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let color else { throw ClementineError.message("Couldn't render the image.") }
        return ImagePDFWriter.Image(jpeg: try encode(color, format: .jpeg, quality: 0.9), width: width, height: height,
                                    components: 3, icc: space.copyICCData() as Data?, alpha: alpha)
    }

    // MARK: Animation

    struct Frame {
        let image: CGImage
        /// Seconds the frame stays on screen.
        let delay: Double
    }

    struct Animation {
        var frames: [Frame]
        /// 0 loops forever.
        var loopCount: Int
    }

    /// Formats whose animations we can both read (ImageIO) and write (ImageIO for GIF, `img2webp` for WebP).
    static func canAnimate(_ format: ImageFormat?) -> Bool {
        format == .gif || (format == .webp && ToolLocator.find("img2webp") != nil)
    }

    /// True for a GIF or WebP with more than one frame.
    static func isAnimated(_ url: URL) -> Bool {
        guard ["gif", "webp"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Every frame of an animated GIF/WebP, composited to full size, with its delay.
    static func loadAnimation(_ url: URL) throws -> Animation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ClementineError.unreadable(url)
        }
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let loop = (file[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
            ?? (file[kCGImagePropertyWebPDictionary] as? [CFString: Any])?[kCGImagePropertyWebPLoopCount]
        var frames: [Frame] = []
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw ClementineError.unreadable(url) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] ?? [:]
            let delay = [gif[kCGImagePropertyGIFUnclampedDelayTime], gif[kCGImagePropertyGIFDelayTime],
                         webp[kCGImagePropertyWebPUnclampedDelayTime], webp[kCGImagePropertyWebPDelayTime]]
                .lazy.compactMap { $0 as? Double }.first ?? 0
            // Browsers treat near-zero delays as 0.1 s; do the same so the timing matches what people see.
            frames.append(Frame(image: image, delay: delay > 0.011 ? delay : 0.1))
        }
        return Animation(frames: frames, loopCount: loop as? Int ?? 0)
    }

    static func writeAnimation(_ animation: Animation, to url: URL, format: ImageFormat,
                               quality: Double = Prefs.imageQuality) async throws {
        try await Output.produce(url) {
            switch format {
            case .gif: try encodeGIF(animation).write(to: url)
            case .webp: try await writeAnimatedWebP(animation, to: url, quality: quality)
            default: throw ClementineError.message("\(format.label) can't hold an animation.")
            }
        }
    }

    private static func encodeGIF(_ animation: Animation) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, animation.frames.count, nil) else {
            throw ClementineError.message("This Mac can't write GIF images.")
        }
        let file = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: animation.loopCount]]
        CGImageDestinationSetProperties(destination, file as CFDictionary)
        for frame in animation.frames {
            let options = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay,
                                                           kCGImagePropertyGIFUnclampedDelayTime: frame.delay]]
            CGImageDestinationAddImage(destination, frame.image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ClementineError.message("Couldn't encode the animation as GIF.") }
        return data as Data
    }

    /// `cwebp` only writes stills, so animations go frame by frame through `img2webp`.
    private static func writeAnimatedWebP(_ animation: Animation, to url: URL, quality: Double) async throws {
        let img2webp = try ToolLocator.require("img2webp")
        let temp = try framesFolder(animation)
        defer { try? FileManager.default.removeItem(at: temp) }
        // `-mixed` picks lossy or lossless per frame: GIF-style flat colors stay small, photographic frames stay lossy.
        var args = ["-loop", String(animation.loopCount), "-mixed", "-q", String(Int(quality * 100))]
        for (index, frame) in animation.frames.enumerated() {
            args += ["-d", String(max(Int((frame.delay * 1000).rounded()), 1)), temp.appendingPathComponent("\(index).png").path]
        }
        try await ProcessRunner.run(img2webp, args + ["-o", url.path])
    }

    /// Writes each frame as `0.png`, `1.png`… in a fresh temporary folder.
    private static func framesFolder(_ animation: Animation, flattened: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (index, frame) in animation.frames.enumerated() {
                try Task.checkCancellation()
                let pixels = flattened && frame.image.hasAlpha ? try flatten(frame.image) : frame.image
                try encode(pixels, format: .png, quality: 1).write(to: folder.appendingPathComponent("\(index).png"))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Animated WebP → video. ffmpeg's WebP decoder can't read animations, so ImageIO decodes the frames
    /// and ffmpeg's concat demuxer plays them back with their original timing.
    static func animationToVideo(_ input: URL, ext: String, progress: @escaping (Double) -> Void) async throws -> URL {
        let animation = try loadAnimation(input)
        let temp = try framesFolder(animation, flattened: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var list = ""
        for (index, frame) in animation.frames.enumerated() {
            list += "file '\(index).png'\nduration \(frame.delay)\n"
        }
        // The concat demuxer ignores the last duration unless the final file is listed again.
        list += "file '\(animation.frames.count - 1).png'\n"
        let listFile = temp.appendingPathComponent("frames.txt")
        try list.write(to: listFile, atomically: true, encoding: .utf8)
        let duration = animation.frames.reduce(0) { $0 + $1.delay }
        let output = Output.file(beside: input, ext: ext)
        return try await FFmpeg.transcode(listFile, to: output, inputArgs: ["-f", "concat", "-safe", "0"],
                                          args: ["-t", String(duration)] + FFmpeg.encodeArgs(ext), duration: duration, progress: progress)
    }

    // MARK: Drawing helpers

    static func render(width: Int, height: Int, colorSpace: CGColorSpace? = nil, _ draw: (CGContext) -> Void) throws -> CGImage {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ClementineError.message("Couldn't allocate a \(width)×\(height) image.") }
        context.interpolationQuality = .high
        draw(context)
        guard let image = context.makeImage() else { throw ClementineError.message("Couldn't render the image.") }
        return image
    }

    static func flatten(_ image: CGImage, color: CGColor = .white) throws -> CGImage {
        try render(width: image.width, height: image.height, colorSpace: image.colorSpace) { context in
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(color)
            context.fill(rect)
            context.draw(image, in: rect)
        }
    }

    static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let width = max(Int(Double(image.width) * factor), 1)
        let height = max(Int(Double(image.height) * factor), 1)
        return try render(width: width, height: height, colorSpace: image.colorSpace) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func scaled(_ image: CGImage, maxEdge: Int) throws -> CGImage {
        let longEdge = max(image.width, image.height)
        return longEdge > maxEdge ? try scaled(image, by: Double(maxEdge) / Double(longEdge)) : image
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Conversion

    static func convert(_ input: URL, to format: ImageFormat) async throws -> URL {
        if canAnimate(format), isAnimated(input) {
            let animation = try loadAnimation(input)
            let output = Output.file(beside: input, ext: format.ext)
            try await writeAnimation(animation, to: output, format: format)
            return output
        }
        if format == .pdf {
            let output = Output.file(beside: input, ext: "pdf")
            try await Output.produce(output) { try writePDF([input], to: output) }
            return output
        }
        let loaded = try load(input)
        let output = Output.file(beside: input, ext: format.ext)
        try await write(loaded.image, to: output, format: format, properties: loaded.properties)
        return output
    }

    /// The format edits are saved in: the original's if we can write it, PNG otherwise.
    static func editFormat(for loaded: LoadedImage) -> ImageFormat {
        guard let format = loaded.format, format != .pdf else { return .png }
        if format == .webp && ToolLocator.find("cwebp") == nil { return .png }
        return format
    }

    /// Saves an edited image. Pass `frames` (the same edit) to keep an animated GIF/WebP animated:
    /// it's applied to every frame instead of saving only the first.
    /// `properties` replaces the source's metadata (Redact passes the privacy-safe subset).
    static func saveEdit(_ image: CGImage, from input: URL, loaded: LoadedImage, suffix: String,
                         properties: [CFString: Any]? = nil,
                         frames edit: ((CGImage) throws -> CGImage)? = nil) async throws -> URL {
        let format = editFormat(for: loaded)
        let output = Output.file(beside: input, suffix: suffix, ext: format.ext)
        if let edit, canAnimate(format), isAnimated(input) {
            var animation = try loadAnimation(input)
            animation.frames = try animation.frames.map { frame in
                try Task.checkCancellation()
                return Frame(image: try edit(frame.image), delay: frame.delay)
            }
            try await writeAnimation(animation, to: output, format: format)
            return output
        }
        try await write(image, to: output, format: format, properties: properties ?? loaded.properties)
        return output
    }

    // MARK: Vision

    static func recognizeText(_ input: URL) throws -> URL {
        let image = try load(input).image
        // Vision rejects images under 3 px on a side with a raw error; there's no text in those anyway.
        guard image.width > 2, image.height > 2 else {
            throw ClementineError.message("No text found in \(input.lastPathComponent).")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw ClementineError.message("No text found in \(input.lastPathComponent).") }
        let output = Output.file(beside: input, ext: "txt")
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    static func readCodes(_ input: URL) throws -> String {
        let image = try load(input).image
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { return "No QR code or barcode found in \(input.lastPathComponent)." }
        var seen = Set<String>()
        return payloads.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
