import AppKit

/// Text documents via AppKit's rich-text importers/exporters. These touch WebKit for HTML, so they run on the main actor.
@MainActor
enum DocumentEngine {
    static func convert(_ input: URL, to ext: String) throws -> URL {
        let text = try read(input)
        let output = Output.file(beside: input, ext: ext)
        do {
            try write(text, to: output, ext: ext)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType
        switch url.pathExtension.lowercased() {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "rtf": type = .rtf
        case "html", "htm": type = .html
        case "odt": type = .openDocument
        default:
            let data = try Data(contentsOf: url)
            let string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
            return NSAttributedString(string: string, attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    static func write(_ text: NSAttributedString, to url: URL, ext: String) throws {
        let range = NSRange(location: 0, length: text.length)
        switch ext {
        case "txt":
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case "docx":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case "rtf":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case "pdf":
            try writePDF(text, to: url)
        default:
            throw ClementineError.message("Can't write .\(ext) documents.")
        }
    }

    /// Lays the text out on US Letter pages with an off-screen text view and "prints" it to a file.
    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 612, height: 792)
        let margin: CGFloat = 72
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = paper.width - margin * 2
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: max(layout.usedRect(for: container).height, 1)))
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ClementineError.message("Couldn't create the PDF.") }
    }
}
