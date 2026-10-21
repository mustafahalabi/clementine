import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Full-resolution rendering for the interactive image editors (Crop, Redact, Annotate).
///
/// Editors only produce JSON in pixel coordinates of the upright image (top-left origin, as `ImageEngine.load`
/// returns it); the drawing happens here, so the windows and the CLI (`--set crop=…`) give identical results.
enum ImageEdits {
    // MARK: JSON

    static func decode<T: Decodable>(_ type: T.Type, from text: String, what: String, example: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ClementineError.message("Couldn't read the \(what). Expected JSON like \(example)")
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A rectangle in image pixels, as it appears in the JSON.
    struct PixelRect: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double

        init(_ rect: CGRect) {
            x = rect.minX.rounded(); y = rect.minY.rounded(); w = rect.width.rounded(); h = rect.height.rounded()
        }

        var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    // MARK: Crop

    /// Rotation (clockwise degrees, applied first) and a crop rectangle in the rotated image. Missing values mean
    /// no rotation and the whole image, so `{"rotate":90}` alone just turns it.
    struct CropSpec: Codable, Equatable {
        var x: Double?, y: Double?, w: Double?, h: Double?
        var rotate: Int?
    }

    static let cropExample = #"{"x":0,"y":0,"w":800,"h":600,"rotate":0}"#

    /// Turns an image clockwise by `degrees`, a multiple of 90.
    static func rotated(_ image: CGImage, degrees: Int) throws -> CGImage {
        let turns = (degrees / 90 % 4 + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        return try ImageEngine.render(width: turns == 2 ? w : h, height: turns == 2 ? h : w, colorSpace: image.colorSpace) { context in
            switch turns {
            case 1: context.translateBy(x: 0, y: CGFloat(w)); context.rotate(by: -.pi / 2)
            case 2: context.translateBy(x: CGFloat(w), y: CGFloat(h)); context.rotate(by: .pi)
            default: context.translateBy(x: CGFloat(h), y: 0); context.rotate(by: .pi / 2)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// The pixel rectangle a spec selects in an image of `size` (already rotated), clipped to the image.
    static func cropRect(_ spec: CropSpec, in size: CGSize) throws -> CGRect {
        let x = spec.x ?? 0, y = spec.y ?? 0
        let w = spec.w ?? size.width - x, h = spec.h ?? size.height - y
        guard [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else {
            throw ClementineError.message("The crop width and height must be positive numbers.")
        }
        let clipped = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
            .intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw ClementineError.message("The crop area is outside the \(Int(size.width))×\(Int(size.height)) image.")
        }
        return clipped
    }

    static func cropped(_ image: CGImage, _ spec: CropSpec) throws -> CGImage {
        let turned = try rotated(image, degrees: spec.rotate ?? 0)
        let rect = try cropRect(spec, in: CGSize(width: turned.width, height: turned.height))
        if rect.size == CGSize(width: turned.width, height: turned.height) { return turned }
        guard let result = turned.cropping(to: rect) else { throw ClementineError.message("Couldn't crop the image.") }
        return result
    }

    static func crop(_ input: URL, json: String) async throws -> URL {
        let spec = try decode(CropSpec.self, from: json, what: "crop settings", example: cropExample)
        guard (spec.rotate ?? 0) % 90 == 0 else { throw ClementineError.message("Rotation must be a multiple of 90 degrees.") }
        let loaded = try ImageEngine.load(input)
        let edit = { (image: CGImage) throws -> CGImage in try cropped(image, spec) }
        let result = try edit(loaded.image)
        let turned = (spec.rotate ?? 0) % 360 != 0
        let trimmed = spec.x != nil || spec.y != nil || spec.w != nil || spec.h != nil
        return try await ImageEngine.saveEdit(result, from: input, loaded: loaded,
                                              suffix: turned && !trimmed ? "rotated" : "cropped", frames: edit)
    }

    // MARK: Redact

    enum RedactStyle: Int, CaseIterable {
        case pixelate, blur, black
    }

    static let redactStyles = ["Pixelate", "Blur", "Black"]
    static let boxesExample = #"[{"x":10,"y":20,"w":300,"h":40}] or "auto""#

    /// Covers `boxes` (image pixels) so the original pixels can't be recovered: every style works from block averages
    /// of the area (with a little random noise, so they can't be matched against candidate renderings) or plain black.
    /// `minBlock` is the smallest pixel block; previews pass it scaled down so they match the full-size result.
    static func redacted(_ image: CGImage, boxes: [CGRect], style: RedactStyle, seed: UInt64, minBlock: Double = 12) throws -> CGImage {
        let width = image.width, height = image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let regions = boxes.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        var random = SplitMix(seed: seed)
        return try ImageEngine.render(width: width, height: height, colorSpace: image.colorSpace) { context in
            context.draw(image, in: bounds)
            for region in regions {
                // The bitmap's rows run top-down, but drawing calls use a bottom-left origin.
                let drawn = CGRect(x: region.minX, y: CGFloat(height) - region.maxY, width: region.width, height: region.height)
                let long = Double(max(region.width, region.height)), short = Double(min(region.width, region.height))
                switch style {
                case .black:
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(drawn)
                case .pixelate:
                    let block = Int(max(minBlock, long / 10, short / 4).rounded())
                    let grid = averages(context, region, cell: block, random: &random)
                    paint(grid, into: context, region, cell: block)
                case .blur:
                    let cell = Int(max(minBlock / 2, long / 20, short / 8).rounded())
                    let grid = averages(context, region, cell: cell, random: &random)
                    if let smooth = blurred(grid, size: region.size, cell: cell, colorSpace: context.colorSpace) {
                        context.clear(drawn)
                        context.draw(smooth, in: drawn)
                    } else {
                        paint(grid, into: context, region, cell: cell)
                    }
                }
            }
        }
    }

    /// Premultiplied RGBA averages of `cell`-sized blocks of `region`, row by row, with ±5 levels of noise.
    private struct Grid {
        var columns: Int, rows: Int
        var pixels: [UInt8]
    }

    private static func averages(_ context: CGContext, _ region: CGRect, cell: Int, random: inout SplitMix) -> Grid {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        let x0 = Int(region.minX), y0 = Int(region.minY), w = Int(region.width), h = Int(region.height)
        let columns = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = [Int](repeating: 0, count: 4)
                let xs = x0 + column * cell, ys = y0 + row * cell
                let xe = min(xs + cell, x0 + w), ye = min(ys + cell, y0 + h)
                for y in ys..<ye {
                    var offset = y * stride + xs * 4
                    for _ in xs..<xe {
                        for c in 0..<4 { sum[c] += Int(data[offset + c]) }
                        offset += 4
                    }
                }
                let count = max((xe - xs) * (ye - ys), 1)
                let alpha = sum[3] / count
                let index = (row * columns + column) * 4
                let noise = Int(random.next() % 11) - 5 // the same for every channel, so it reads as grain, not confetti
                for c in 0..<3 {
                    pixels[index + c] = UInt8(min(max(sum[c] / count + noise, 0), alpha))
                }
                pixels[index + 3] = UInt8(alpha)
            }
        }
        return Grid(columns: columns, rows: rows, pixels: pixels)
    }

    /// Fills each block of `region` with its average.
    private static func paint(_ grid: Grid, into context: CGContext, _ region: CGRect, cell: Int) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        let x0 = Int(region.minX), y0 = Int(region.minY), w = Int(region.width), h = Int(region.height)
        for y in y0..<(y0 + h) {
            let row = (y - y0) / cell
            for x in x0..<(x0 + w) {
                let index = (row * grid.columns + (x - x0) / cell) * 4
                let offset = y * stride + x * 4
                for c in 0..<4 { data[offset + c] = grid.pixels[index + c] }
            }
        }
    }

    private static let ciContext = CIContext()

    /// The block averages scaled up smoothly and blurred (edges clamped, so the area doesn't fade out at its sides).
    private static func blurred(_ grid: Grid, size: CGSize, cell: Int, colorSpace: CGColorSpace?) -> CGImage? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = grid.pixels
        guard let tiny = pixels.withUnsafeMutableBytes({ buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: grid.columns, height: grid.rows, bitsPerComponent: 8,
                      bytesPerRow: grid.columns * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }) else { return nil }
        let extent = CGRect(origin: .zero, size: size)
        let scaled = CIImage(cgImage: tiny)
            .transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(grid.columns), y: size.height / CGFloat(grid.rows)))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(cell) * 0.9)
            .cropped(to: extent)
        return ciContext.createCGImage(scaled, from: extent, format: .RGBA8, colorSpace: space)
    }

    /// Boxes from the JSON, or detected faces and text for `"auto"`.
    static func redactBoxes(_ text: String, image: CGImage) throws -> [CGRect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "auto" || trimmed == #""auto""# {
            return try detectSensitive(in: image).map(\.rect)
        }
        let boxes = try decode([PixelRect].self, from: trimmed, what: "redaction boxes", example: boxesExample)
        guard boxes.allSatisfy({ $0.w > 0 && $0.h > 0 }) else {
            throw ClementineError.message("Redaction boxes need a positive width and height.")
        }
        return boxes.map(\.cgRect)
    }

    static func redact(_ input: URL, boxes json: String, style: Int) async throws -> URL {
        guard let style = RedactStyle(rawValue: style) else { throw ClementineError.message("Unknown redaction style.") }
        let loaded = try ImageEngine.load(input)
        let boxes = try redactBoxes(json, image: loaded.image)
        guard !boxes.isEmpty else { throw ClementineError.message("Nothing to redact in \(input.lastPathComponent).") }
        let bounds = CGRect(x: 0, y: 0, width: loaded.image.width, height: loaded.image.height)
        guard boxes.contains(where: { $0.intersects(bounds) }) else {
            throw ClementineError.message("The redaction boxes are outside the \(loaded.image.width)×\(loaded.image.height) image.")
        }
        let seed = UInt64.random(in: .min ... .max) // one seed for every frame, so animations don't shimmer
        let edit = { (image: CGImage) throws -> CGImage in try redacted(image, boxes: boxes, style: style, seed: seed) }
        return try await ImageEngine.saveEdit(try edit(loaded.image), from: input, loaded: loaded, suffix: "redacted", frames: edit)
    }

    // MARK: Detection

    struct Detection {
        enum Kind { case face, text }
        let kind: Kind
        let rect: CGRect
    }

    /// Faces and lines of text, padded a little, in the image's pixels (top-left origin).
    static func detectSensitive(in image: CGImage) throws -> [Detection] {
        guard image.width > 2, image.height > 2 else { return [] }
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([faces, text])
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ box: CGRect, padX: CGFloat, padY: CGFloat) -> CGRect {
            let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            return rect.insetBy(dx: -padX, dy: -padY).intersection(CGRect(origin: .zero, size: size)).integral
        }
        var found: [Detection] = []
        for face in faces.results ?? [] {
            let box = face.boundingBox
            found.append(Detection(kind: .face, rect: pixels(box, padX: box.width * size.width * 0.15, padY: box.height * size.height * 0.25)))
        }
        for line in text.results ?? [] {
            let height: CGFloat = line.boundingBox.height * size.height
            found.append(Detection(kind: .text, rect: pixels(line.boundingBox, padX: height * 0.3, padY: height * 0.2)))
        }
        return found.filter { !$0.rect.isNull && $0.rect.width >= 1 && $0.rect.height >= 1 }
    }

    // MARK: Annotate

    /// One mark on the image. `points` are image pixels: arrows go from the first to the last, rectangles and ellipses
    /// span two corners, pens and highlighters follow them all, and text starts at the first (its top-left).
    struct Annotation: Codable, Identifiable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case arrow, rectangle, ellipse, pen, highlighter, text
        }

        var id = UUID()
        var kind: Kind
        var points: [CGPoint]
        /// `#RRGGBB`.
        var color = "#FF9A3C"
        /// Stroke width in pixels; the font size for text.
        var width = 8.0
        var text: String?

        private enum CodingKeys: String, CodingKey { case kind, points, color, width, text }

        init(kind: Kind, points: [CGPoint], color: String = "#FF9A3C", width: Double = 8, text: String? = nil) {
            self.kind = kind
            self.points = points
            self.color = color
            self.width = width
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            points = try container.decode([CGPoint].self, forKey: .points)
            color = try container.decodeIfPresent(String.self, forKey: .color) ?? color
            width = try container.decodeIfPresent(Double.self, forKey: .width) ?? width
            text = try container.decodeIfPresent(String.self, forKey: .text)
        }

        var cgColor: CGColor { ImageEdits.color(hex: color) ?? CGColor(srgbRed: 1, green: 0.6, blue: 0.24, alpha: 1) }

        func moved(by delta: CGSize) -> Annotation {
            var copy = self
            copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
            return copy
        }
    }

    static let annotationsExample = ##"[{"kind":"arrow","points":[[40,40],[300,200]],"color":"#FF5E3A","width":12}]"##

    static func color(hex: String) -> CGColor? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func parseAnnotations(_ json: String) throws -> [Annotation] {
        let items = try decode([Annotation].self, from: json, what: "annotations", example: annotationsExample)
        for item in items {
            let needed = [.arrow: 2, .rectangle: 2, .ellipse: 2][item.kind] ?? 1
            guard item.points.count >= needed, item.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw ClementineError.message("A \(item.kind.rawValue) annotation needs at least \(needed) point\(needed == 1 ? "" : "s").")
            }
            guard color(hex: item.color) != nil else { throw ClementineError.message("“\(item.color)” isn't a #RRGGBB color.") }
            guard item.width > 0, item.width.isFinite else { throw ClementineError.message("Annotation widths must be positive.") }
            if item.kind == .text, (item.text ?? "").isEmpty { throw ClementineError.message("A text annotation needs some text.") }
        }
        return items
    }

    static func annotated(_ image: CGImage, _ items: [Annotation]) throws -> CGImage {
        try ImageEngine.render(width: image.width, height: image.height, colorSpace: image.colorSpace) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            draw(items, in: context)
        }
    }

    static func annotate(_ input: URL, json: String) async throws -> URL {
        let items = try parseAnnotations(json)
        guard !items.isEmpty else { throw ClementineError.message("There are no annotations to draw.") }
        let loaded = try ImageEngine.load(input)
        let edit = { (image: CGImage) throws -> CGImage in try annotated(image, items) }
        return try await ImageEngine.saveEdit(try edit(loaded.image), from: input, loaded: loaded, suffix: "annotated", frames: edit)
    }

    // MARK: Drawing annotations

    /// Draws in image pixels on a context whose origin is top-left (the editor canvas, or a flipped bitmap).
    static func draw(_ items: [Annotation], in context: CGContext) {
        for item in items {
            context.saveGState()
            draw(item, in: context)
            context.restoreGState()
        }
    }

    private static func draw(_ item: Annotation, in context: CGContext) {
        let width = CGFloat(item.width)
        context.setStrokeColor(item.cgColor)
        context.setFillColor(item.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        guard let first = item.points.first, let last = item.points.last else { return }
        switch item.kind {
        case .arrow:
            let head = arrowHead(item)
            context.move(to: first)
            context.addLine(to: head.base)
            context.strokePath()
            context.setLineWidth(width * 0.5)
            context.addLines(between: [last, head.left, head.right])
            context.closePath()
            context.drawPath(using: .fillStroke)
        case .rectangle:
            context.stroke(span(first, last))
        case .ellipse:
            context.strokeEllipse(in: span(first, last))
        case .pen, .highlighter:
            if item.kind == .highlighter {
                context.setAlpha(0.4)
                context.setLineWidth(width * 3)
                context.setLineCap(.square)
            }
            if item.points.count == 1 {
                let side = item.kind == .highlighter ? width * 3 : width
                context.fillEllipse(in: CGRect(x: first.x - side / 2, y: first.y - side / 2, width: side, height: side))
            } else {
                context.addPath(smoothPath(item.points))
                context.strokePath()
            }
        case .text:
            let string = attributedText(item)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            // A contrasting halo first, then the fill on top, so text reads on busy photos.
            let halo = NSMutableAttributedString(attributedString: string)
            let light = luminance(item.cgColor) > 0.6
            halo.addAttributes([.strokeColor: light ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 1, alpha: 0.9),
                                .strokeWidth: 16], range: NSRange(location: 0, length: halo.length))
            halo.draw(at: first)
            string.draw(at: first)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func span(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Where the shaft ends and the arrowhead's back corners are.
    private static func arrowHead(_ item: Annotation) -> (base: CGPoint, left: CGPoint, right: CGPoint) {
        let start = item.points[0], end = item.points[item.points.count - 1]
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let size = min(max(CGFloat(item.width) * 3.2, 10), length)
        let back = CGPoint(x: end.x - ux * size, y: end.y - uy * size)
        let spread = size * 0.58
        return (CGPoint(x: end.x - ux * size * 0.7, y: end.y - uy * size * 0.7),
                CGPoint(x: back.x - uy * spread, y: back.y + ux * spread),
                CGPoint(x: back.x + uy * spread, y: back.y - ux * spread))
    }

    /// A curve through the points' midpoints, so freehand strokes come out smooth rather than jagged.
    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func attributedText(_ item: Annotation) -> NSAttributedString {
        let size = CGFloat(item.width)
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return NSAttributedString(string: item.text ?? "", attributes: [.font: font, .foregroundColor: NSColor(cgColor: item.cgColor) ?? .orange])
    }

    private static func luminance(_ color: CGColor) -> CGFloat {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        return c.count >= 3 ? 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] : c[0]
    }

    // MARK: Geometry for editing

    /// The area an annotation covers, in image pixels.
    static func bounds(_ item: Annotation) -> CGRect {
        if item.kind == .text, let origin = item.points.first {
            return CGRect(origin: origin, size: attributedText(item).size())
        }
        let xs = item.points.map(\.x), ys = item.points.map(\.y)
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        let reach = CGFloat(item.width) * (item.kind == .highlighter ? 1.5 : item.kind == .arrow ? 1.9 : 0.5)
        return box.insetBy(dx: -reach, dy: -reach)
    }

    /// Whether `point` (image pixels) is on the annotation, within `tolerance` pixels.
    static func hitTest(_ item: Annotation, _ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = CGFloat(item.width) * (item.kind == .highlighter ? 1.5 : 0.5) + tolerance
        switch item.kind {
        case .text:
            return bounds(item).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle:
            let rect = span(item.points[0], item.points[item.points.count - 1])
            let inside = rect.insetBy(dx: reach, dy: reach), outside = rect.insetBy(dx: -reach, dy: -reach)
            return outside.contains(point) && (inside.isNull || !inside.contains(point))
        case .ellipse:
            let rect = span(item.points[0], item.points[item.points.count - 1])
            let a = max(rect.width / 2, 0.5), b = max(rect.height / 2, 0.5)
            let dx = (point.x - rect.midX) / a, dy = (point.y - rect.midY) / b
            return abs(sqrt(dx * dx + dy * dy) - 1) * min(a, b) <= reach
        case .arrow, .pen, .highlighter:
            let points = item.points
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
            return zip(points, points.dropFirst()).contains { distance(point, $0, $1) <= reach }
        }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// A small seeded generator for redaction noise (the seed itself is random per job).
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
