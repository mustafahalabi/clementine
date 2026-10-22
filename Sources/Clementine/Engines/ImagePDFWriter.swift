import CoreGraphics
import Foundation
import ImageIO
import zlib

/// Writes a PDF of full-page images, one page at a time straight to disk.
/// CGPDFContext (and PDFKit) keep every image's data until the document closes, so their memory grows with the
/// output (~5 MB per 12 MP photo); here only the page being written is in memory.
final class ImagePDFWriter {
    /// A page image: JPEG data (DCTDecode) plus an optional 8-bit alpha mask.
    struct Image {
        let jpeg: Data
        let width: Int
        let height: Int
        /// 1 (gray) or 3 (RGB).
        let components: Int
        let icc: Data?
        let alpha: Data?
    }

    private let handle: FileHandle
    private var position = 0
    /// Byte offset of each object, by object number - 1. 1 is the catalog, 2 the page tree (written last).
    private var offsets: [Int] = [0, 0]
    private var pages: [Int] = []

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ClementineError.message("Couldn't write \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        // The binary comment line tells transfer tools the file isn't text.
        try write(Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    }

    deinit { try? handle.close() }

    /// Adds a page of `size` points filled by `image`.
    func addPage(_ image: Image, size: CGSize) throws {
        var colorSpace = image.components == 1 ? "/DeviceGray" : "/DeviceRGB"
        if let icc = image.icc {
            colorSpace = "[/ICCBased \(try stream("/N \(image.components)", Self.deflate(icc), filter: "/FlateDecode")) 0 R]"
        }
        var mask = ""
        if let alpha = image.alpha {
            let id = try stream("/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) "
                                + "/ColorSpace /DeviceGray /BitsPerComponent 8", Self.deflate(alpha), filter: "/FlateDecode")
            mask = " /SMask \(id) 0 R"
        }
        let picture = try stream("/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) "
                                 + "/ColorSpace \(colorSpace) /BitsPerComponent 8\(mask)", image.jpeg, filter: "/DCTDecode")
        let width = Self.number(size.width), height = Self.number(size.height)
        let contents = try stream("", Data("q \(width) 0 0 \(height) 0 0 cm /Im0 Do Q".utf8), filter: nil)
        pages.append(try object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] "
                                + "/Resources << /XObject << /Im0 \(picture) 0 R >> >> /Contents \(contents) 0 R >>"))
    }

    /// Writes the page tree, catalog and cross-reference table, and closes the file.
    func finish() throws {
        try object("<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>", id: 2)
        try object("<< /Type /Catalog /Pages 2 0 R >>", id: 1)
        let table = position
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        try write(Data(xref.utf8))
        try handle.close()
    }

    // MARK: Objects

    @discardableResult
    private func object(_ body: String, id: Int? = nil) throws -> Int {
        let id = id ?? { offsets.append(0); return offsets.count }()
        offsets[id - 1] = position
        try write(Data("\(id) 0 obj\n\(body)\nendobj\n".utf8))
        return id
    }

    private func stream(_ dictionary: String, _ data: Data, filter: String?) throws -> Int {
        offsets.append(position)
        let id = offsets.count
        let filter = filter.map { " /Filter \($0)" } ?? ""
        try write(Data("\(id) 0 obj\n<< \(dictionary)\(filter) /Length \(data.count) >>\nstream\n".utf8))
        try write(data)
        try write(Data("\nendstream\nendobj\n".utf8))
        return id
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        position += data.count
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    /// zlib format (what FlateDecode expects).
    static func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 6)
            }
        }
        guard status == Z_OK else { throw ClementineError.message("Couldn't compress a PDF page.") }
        output.count = Int(length)
        return output
    }
}
