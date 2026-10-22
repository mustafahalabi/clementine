import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Remove Background: Vision's subject lifting (the same model as Photos' "Copy Subject"), entirely on-device.
enum BackgroundRemover {
    /// Formats that keep transparency. PNG first: lossless and readable everywhere.
    static let formats: [ImageFormat] = [.png, .heic, .webp]
    static let formatNames = formats.map(\.label)

    static func removeBackground(_ input: URL, format: Int, crop: Bool) async throws -> URL {
        let loaded = try ImageEngine.load(input)
        let image = try cutOut(loaded.image, crop: crop, name: input.lastPathComponent)
        let format = formats[min(max(format, 0), formats.count - 1)]
        let output = Output.file(beside: input, suffix: "cut out", ext: format.ext)
        try await ImageEngine.write(image, to: output, format: format, properties: loaded.properties)
        return output
    }

    /// The image with everything but its foreground subjects transparent, optionally cropped to them.
    static func cutOut(_ image: CGImage, crop: Bool, name: String = "the image") throws -> CGImage {
        let noSubject = ClementineError.message(
            "No subject found in \(name). Remove Background works on photos with a clear foreground, like a person, pet or object.")
        // Vision rejects tiny images with a raw error; there's no subject to find in those anyway.
        guard image.width > 2, image.height > 2 else { throw noSubject }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        let observation: VNInstanceMaskObservation
        do {
            try handler.perform([request])
            guard let first = request.results?.first, !first.allInstances.isEmpty else { throw noSubject }
            observation = first
        } catch let error as ClementineError {
            throw error
        } catch {
            throw ClementineError.message("This Mac couldn't separate the subject (\(error.localizedDescription)).")
        }
        // A soft mask at the image's own size; compositing it ourselves keeps the original color space (P3 photos
        // stay P3), which Vision's ready-made masked image doesn't promise.
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let (mask, bounds) = try grayMask(buffer)
        guard let bounds else { throw noSubject }

        let width = image.width, height = image.height
        let full = try ImageEngine.render(width: width, height: height, colorSpace: image.colorSpace) { context in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.clip(to: rect, mask: mask)
            context.draw(image, in: rect)
        }
        guard crop else { return full }
        guard let cropped = full.cropping(to: bounds) else { throw ClementineError.message("Couldn't crop to the subject.") }
        return cropped
    }

    /// Vision's float mask as an 8-bit gray image for `CGContext.clip(to:mask:)`, plus the subject's bounding box
    /// (top-left origin, in pixels), or nil when the mask is empty.
    private static func grayMask(_ buffer: CVPixelBuffer) throws -> (CGImage, CGRect?) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            throw ClementineError.message("Unexpected mask format from Vision.")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ClementineError.message("Couldn't read the subject mask.") }

        var gray = [UInt8](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let value = UInt8((min(max(row[x], 0), 1) * 255).rounded())
                gray[y * width + x] = value
                // Ignore the faint halo so "crop to subject" hugs what you can actually see.
                if value > 12 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ClementineError.message("Couldn't build the subject mask.") }
        let bounds = maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (mask, bounds)
    }
}
