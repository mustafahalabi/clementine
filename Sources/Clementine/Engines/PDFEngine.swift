import AppKit
import PDFKit

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ClementineError.unreadable(url) }
        guard !document.isLocked else { throw ClementineError.message("\(url.lastPathComponent) is password protected.") }
        return document
    }

    private static func save(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard document.write(to: url, withOptions: options) else {
            try? FileManager.default.removeItem(at: url)
            throw ClementineError.message("Couldn't write \(url.lastPathComponent).")
        }
    }

    // MARK: Conversion

    static func toText(_ input: URL) throws -> URL {
        let text = try open(input).string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClementineError.message("\(input.lastPathComponent) has no selectable text. It may be a scan.")
        }
        let output = Output.file(beside: input, ext: "txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    static func toDOCX(_ input: URL) async throws -> URL {
        try await MainActor.run {
            let document = try open(input)
            let text = document.selectionForEntireDocument?.attributedString ?? NSAttributedString(string: document.string ?? "")
            let output = Output.file(beside: input, ext: "docx")
            try DocumentEngine.write(text, to: output, ext: "docx")
            return output
        }
    }

    static func toImages(_ input: URL, format: ImageFormat, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let document = try open(input)
        let count = document.pageCount
        let base = input.deletingPathExtension().lastPathComponent
        let folder = count > 1 ? try Output.folder(beside: input, name: "\(base) pages") : nil
        var outputs: [URL] = []
        try await Output.filling(folder) {
            for index in 0..<count {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let output = folder.map { Output.unique(in: $0, base: "\(base) \(index + 1)", ext: format.ext) }
                    ?? Output.file(beside: input, ext: format.ext)
                try await ImageEngine.write(try render(page, scale: 2), to: output, format: format, quality: 0.9)
                outputs.append(output)
                progress(Double(index + 1) / Double(count))
            }
        }
        return folder.map { [$0] } ?? outputs
    }

    static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        // The cropBox is what viewers show; the mediaBox can include bleed or trimmed-away margins.
        let box = page.bounds(for: .cropBox)
        let quarterTurn = page.rotation % 180 != 0
        let size = NSSize(width: (quarterTurn ? box.height : box.width) * scale, height: (quarterTurn ? box.width : box.height) * scale)
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        var rect = NSRect(origin: .zero, size: size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ClementineError.message("Couldn't render a page.")
        }
        return try ImageEngine.flatten(image)
    }

    // MARK: Tools

    static func compress(_ input: URL) throws -> URL {
        let document = try open(input)
        let output = Output.file(beside: input, suffix: "compressed", ext: "pdf")
        try save(document, to: output, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        return output
    }

    static func split(_ input: URL) async throws -> URL {
        let document = try open(input)
        let base = input.deletingPathExtension().lastPathComponent
        let folder = try Output.folder(beside: input, name: "\(base) pages")
        try await Output.produce(folder) {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                try save(single, to: Output.unique(in: folder, base: "\(base) page \(index + 1)", ext: "pdf"))
            }
        }
        return folder
    }

    /// Joins the PDFs, or with a `spec` builds the result from chosen pages (see `parseSpec`), e.g. `2:1-3, 1:2r90`.
    static func merge(_ inputs: [URL], spec: String = "") throws -> URL {
        let documents = try inputs.map(open)
        let counts = documents.map(\.pageCount)
        let refs = spec.allSatisfy({ $0 == "," || $0.isWhitespace })
            ? counts.enumerated().flatMap { file, count in (0..<count).map { PageRef(file: file, page: $0) } }
            : try parseSpec(spec, counts: counts)
        let output = Output.file(beside: inputs[0], suffix: "merged", ext: "pdf")
        try save(assemble(refs, from: documents), to: output)
        return output
    }

    /// Keeps the listed pages in the listed order, rotating any marked with `r`, e.g. `3r90, 1-2, 5-`.
    static func pick(_ input: URL, spec: String) throws -> URL {
        let document = try open(input)
        let refs = try parseSpec(spec, counts: [document.pageCount])
        let output = Output.file(beside: input, suffix: "pages", ext: "pdf")
        try save(assemble(refs, from: [document]), to: output)
        return output
    }

    private static func assemble(_ refs: [PageRef], from documents: [PDFDocument]) -> PDFDocument {
        let result = PDFDocument()
        for ref in refs {
            guard let page = documents[ref.file].page(at: ref.page)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + ref.rotation) % 360
            result.insert(page, at: result.pageCount)
        }
        return result
    }

    /// A page picked by a spec: file and page are 0-based, `rotation` is extra clockwise degrees (0, 90, 180 or 270).
    struct PageRef: Hashable {
        var file = 0
        var page: Int
        var rotation = 0
    }

    /// Reads a page list. Items are comma-separated: `3`, `1-2`, `5-` (to the end), `-2` (from the start), `3-1` (reversed).
    /// A trailing `r90`, `r180`, `r270` or `r-90` rotates those pages clockwise. With several files, `2:3` is page 3 of
    /// file 2 and `2:` all of file 2; plain numbers count through the files one after another.
    static func parseSpec(_ spec: String, counts: [Int]) throws -> [PageRef] {
        let total = counts.reduce(0, +)
        guard total > 0 else { throw ClementineError.message(counts.count == 1 ? "This PDF has no pages." : "These PDFs have no pages.") }
        let example = counts.count > 1 ? "3, 1-2, 2:1-4, 5r90" : "3, 1-2, 5-, or 3r90 to rotate"
        var refs: [PageRef] = []
        for item in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            var body = item
            var rotation = 0
            if let r = body.lastIndex(where: { $0 == "r" || $0 == "R" }) {
                let degrees = body[body.index(after: r)...].trimmingCharacters(in: .whitespaces)
                guard let value = Int(degrees), value % 90 == 0 else {
                    throw ClementineError.message("Couldn't read the rotation in “\(item)”. Use r90, r180 or r270, like 3r90.")
                }
                rotation = (value % 360 + 360) % 360
                body = body[..<r].trimmingCharacters(in: .whitespaces)
            }

            // Which file the numbers count through: one named with `n:`, or all of them back to back.
            var file: Int?
            if let colon = body.firstIndex(of: ":") {
                let name = body[..<colon].trimmingCharacters(in: .whitespaces)
                guard let number = Int(name) else {
                    throw ClementineError.message("Couldn't read “\(item)”. Use pages like \(example).")
                }
                guard counts.indices.contains(number - 1) else {
                    throw ClementineError.message(counts.count == 1
                        ? "There's no file \(number) in “\(item)”. Only one PDF is open, so leave out the “\(number):”."
                        : "There's no file \(number) in “\(item)”. Files are numbered 1–\(counts.count) in the order they were dropped.")
                }
                file = number - 1
                body = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let count = file.map { counts[$0] } ?? total

            func number(_ text: String, fallback: Int) throws -> Int {
                if text.isEmpty { return fallback }
                guard let value = Int(text) else {
                    throw ClementineError.message("Couldn't read “\(item)”. Use pages like \(example).")
                }
                guard (1...count).contains(value) else {
                    if let file, counts.count > 1 {
                        throw ClementineError.message("Page \(value) doesn't exist in file \(file + 1), which has \(pageCount(count)).")
                    }
                    throw ClementineError.message(counts.count == 1 ? "Page \(text) doesn't exist. This PDF has \(pageCount(count))."
                                                                    : "Page \(text) doesn't exist. These PDFs have \(pageCount(count)) in all.")
                }
                return value
            }
            let ends = body.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers: [Int]
            switch ends.count {
            case 1 where ends[0].isEmpty:
                numbers = Array(1...count) // `2:` or a bare rotation like `r90`: every page
            case 1:
                numbers = [try number(ends[0], fallback: 1)]
            case 2:
                let start = try number(ends[0], fallback: 1), end = try number(ends[1], fallback: count)
                numbers = start <= end ? Array(start...end) : Array((end...start).reversed())
            default:
                throw ClementineError.message("Couldn't read “\(item)”. Use pages like \(example).")
            }
            refs += numbers.map { number in
                if let file { return PageRef(file: file, page: number - 1, rotation: rotation) }
                // Count through the files one after another.
                var page = number - 1, index = 0
                while page >= counts[index] { page -= counts[index]; index += 1 }
                return PageRef(file: index, page: page, rotation: rotation)
            }
        }
        guard !refs.isEmpty else { throw ClementineError.message("List the pages to keep, like \(example).") }
        return refs
    }

    /// The shortest spec that `parseSpec` reads back as `refs`, joining runs into ranges (`1-3, 2:4r90`).
    static func spec(for refs: [PageRef], qualified: Bool) -> String {
        var parts: [String] = []
        var index = 0
        while index < refs.count {
            let first = refs[index]
            var last = index
            while last + 1 < refs.count, refs[last + 1].file == first.file, refs[last + 1].rotation == first.rotation,
                  refs[last + 1].page == refs[last].page + 1 {
                last += 1
            }
            var part = qualified ? "\(first.file + 1):" : ""
            part += last > index ? "\(first.page + 1)-\(refs[last].page + 1)" : "\(first.page + 1)"
            if first.rotation != 0 { part += "r\(first.rotation)" }
            parts.append(part)
            index = last + 1
        }
        return parts.joined(separator: ", ")
    }

    private static func pageCount(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    static let rotateOptions = ["90° clockwise", "90° counterclockwise", "180°"]

    static func rotate(_ input: URL, choice: Int) throws -> URL {
        let document = try open(input)
        let degrees = [90, 270, 180][choice]
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { page.rotation = (page.rotation + degrees) % 360 }
        }
        let output = Output.file(beside: input, suffix: "rotated", ext: "pdf")
        try save(document, to: output)
        return output
    }

    static func fromImages(_ inputs: [URL]) async throws -> URL {
        try await ImageTools.makePDF(inputs)
    }

    // MARK: Metadata

    static func metadata(_ input: URL) throws -> String {
        let document = try open(input)
        var lines = ["Pages: \(document.pageCount)", "PDF version: \(document.majorVersion).\(document.minorVersion)"]
        for (key, value) in (document.documentAttributes ?? [:]).sorted(by: { "\($0.key)" < "\($1.key)" }) {
            let text = (value as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? "\(value)"
            lines.append("\(key): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    static func stripMetadata(_ input: URL) throws -> URL {
        let document = try open(input)
        document.documentAttributes = [:]
        let output = Output.file(beside: input, suffix: "no metadata", ext: "pdf")
        try save(document, to: output)
        return output
    }
}
