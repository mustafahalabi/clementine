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

    static func merge(_ inputs: [URL]) throws -> URL {
        let merged = PDFDocument()
        for input in inputs {
            let document = try open(input)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let output = Output.file(beside: inputs[0], suffix: "merged", ext: "pdf")
        try save(merged, to: output)
        return output
    }

    /// Keeps the listed pages in the listed order, e.g. `3, 1-2, 5-`.
    static func pick(_ input: URL, spec: String) throws -> URL {
        let document = try open(input)
        let pages = try parsePages(spec, count: document.pageCount)
        let result = PDFDocument()
        for number in pages {
            if let page = document.page(at: number - 1)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        let output = Output.file(beside: input, suffix: "pages", ext: "pdf")
        try save(result, to: output)
        return output
    }

    static func parsePages(_ spec: String, count: Int) throws -> [Int] {
        guard count > 0 else { throw ClementineError.message("This PDF has no pages.") }
        var pages: [Int] = []
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func number(_ text: String, fallback: Int) throws -> Int {
                if text.isEmpty { return fallback }
                guard let value = Int(text), (1...count).contains(value) else {
                    throw ClementineError.message("Page \(text) doesn't exist. This PDF has \(count) pages.")
                }
                return value
            }
            switch ends.count {
            case 1: pages.append(try number(ends[0], fallback: 1))
            case 2:
                let start = try number(ends[0], fallback: 1), end = try number(ends[1], fallback: count)
                pages += start <= end ? Array(start...end) : Array((end...start).reversed())
            default: throw ClementineError.message("Couldn't read “\(part)”. Use pages like 3, 1-2, 5-.")
            }
        }
        guard !pages.isEmpty else { throw ClementineError.message("List the pages to keep, like 3, 1-2, 5-.") }
        return pages
    }

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
            lines.append("\(key): \(value)")
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
