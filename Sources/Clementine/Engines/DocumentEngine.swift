import AppKit

/// Text documents via AppKit's rich-text importers/exporters. These touch WebKit for HTML, so they run on the main actor.
@MainActor
enum DocumentEngine {
    static func convert(_ input: URL, to ext: String) async throws -> URL {
        let text = try read(input)
        let output = Output.file(beside: input, ext: ext)
        try requireWritableFolder(for: output)
        return try await Output.produce(output) {
            try write(text, to: output, ext: ext)
            return output
        }
    }

    /// Checked up front so a read-only folder fails at once with a clear message instead of halfway through.
    static func requireWritableFolder(for output: URL) throws {
        let folder = output.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ClementineError.message("Can't save in “\(folder.lastPathComponent)”: the folder isn't writable.")
        }
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType
        switch url.pathExtension.lowercased() {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "rtf": type = .rtf
        case "html", "htm": return try readHTML(url)
        case "odt": type = .openDocument
        default:
            let string = TextDecoding.decode(try Data(contentsOf: url))
            return NSAttributedString(string: string, attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    /// WebKit's HTML importer fetches every remote image, stylesheet and frame it finds, synchronously on this
    /// thread: a tracking pixel in a saved email would phone home, and a dead host stalls the app for a minute.
    /// The markup is rewritten first so only local files (relative paths, `file:` and `data:` URLs) can load.
    private static func readHTML(_ url: URL) throws -> NSAttributedString {
        let html = HTMLSanitizer.offline(TextDecoding.decodeHTML(try Data(contentsOf: url)))
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .baseURL: url, // relative images next to the page still resolve
        ]
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
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

    /// Lays the text out page by page with TextKit and draws it straight into a PDF context. No print operation:
    /// that one shows modal alerts (e.g. for a read-only folder) that hang a background job forever.
    /// Pages use the system's default paper size (A4 or US Letter depending on region and printer).
    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        var paper = NSPrintInfo.shared.paperSize
        if paper.width < 144 || paper.height < 144 { paper = NSSize(width: 612, height: 792) }
        let margin: CGFloat = 72
        let column = NSSize(width: paper.width - margin * 2, height: paper.height - margin * 2)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var pages: [NSTextContainer] = []
        var emptyPages = 0
        repeat {
            let container = NSTextContainer(size: column)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            pages.append(container)
            let glyphs = layout.glyphRange(for: container)
            if layout.numberOfGlyphs == 0 || NSMaxRange(glyphs) >= layout.numberOfGlyphs { break }
            // Something taller than a page (a huge image) never fits; stop instead of adding pages forever.
            emptyPages = glyphs.length == 0 ? emptyPages + 1 : 0
        } while emptyPages < 2 && pages.count < 20_000

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        var box = CGRect(origin: .zero, size: paper)
        guard let pdf = CGContext(temp as CFURL, mediaBox: &box, nil) else {
            throw ClementineError.message("Couldn't create the PDF.")
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for container in pages {
                pdf.beginPDFPage(nil)
                pdf.translateBy(x: 0, y: paper.height)
                pdf.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
                let glyphs = layout.glyphRange(for: container)
                let origin = NSPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        try FileManager.default.moveItem(at: temp, to: url)
    }
}

/// Plain-text decoding that copes with what people actually save: UTF-16/32 with a BOM (Notepad's "Unicode"),
/// BOM-less UTF-16, UTF-8, and legacy Windows-1252.
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        if let (encoding, bom) = sniffBOM(data) {
            return String(data: data.dropFirst(bom), encoding: encoding) ?? fallback(data)
        }
        if let encoding = guessUTF16(data), let string = String(data: data, encoding: encoding) {
            return string
        }
        return fallback(data)
    }

    /// Like `decode`, but honours a `<meta charset>` when there's no BOM.
    static func decodeHTML(_ data: Data) -> String {
        if sniffBOM(data) == nil, guessUTF16(data) == nil,
           let head = String(data: data.prefix(2048), encoding: .isoLatin1),
           let match = head.range(of: #"charset\s*=\s*["']?\s*([A-Za-z0-9_:.-]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let name = head[match].replacingOccurrences(of: #"^charset\s*=\s*["']?\s*"#, with: "",
                                                        options: [.regularExpression, .caseInsensitive])
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let string = String(data: data, encoding: encoding) { return string }
            }
        }
        return decode(data)
    }

    private static func sniffBOM(_ data: Data) -> (String.Encoding, Int)? {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if b.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if b.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    /// Mostly-ASCII text in UTF-16 has a zero in nearly every other byte, which UTF-8 text never does.
    private static func guessUTF16(_ data: Data) -> String.Encoding? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) || data.count > 4096 else { return nil }
        let pairs = bytes.count / 2
        var evenZeros = 0, oddZeros = 0
        for i in 0..<pairs {
            if bytes[2 * i] == 0 { evenZeros += 1 }
            if bytes[2 * i + 1] == 0 { oddZeros += 1 }
        }
        if oddZeros * 10 >= pairs * 7 && evenZeros * 10 < pairs { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 7 && oddZeros * 10 < pairs { return .utf16BigEndian }
        return nil
    }

    private static func fallback(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) // every byte sequence is valid Latin-1
            ?? String(decoding: data, as: UTF8.self)
    }
}

/// Rewrites HTML so rendering it can't touch the network. Allow-list based: a URL survives only if it's relative,
/// `file:` without a host, `data:`, or a fragment; everything else (http, https, ftp, protocol-relative `//host`,
/// unknown schemes) is removed. CSS `url()`/`@import`/`image-set()` are disabled wherever CSS can appear, and
/// `<base>`, `<meta http-equiv>`, scripts and comments are dropped. A small tokenizer (rather than regexes over the
/// whole page) keeps quoted `>` and stray quotes from hiding a tag.
enum HTMLSanitizer {
    static func offline(_ html: String) -> String {
        let s = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        // Turns off DNS prefetching for links too. Goes after a doctype, if any, so the page keeps its mode.
        let header = #"<meta http-equiv="x-dns-prefetch-control" content="off">"#
        var injected = false
        func inject() { if !injected { out.append(contentsOf: header.unicodeScalars); injected = true } }
        func starts(_ p: [Unicode.Scalar], at index: Int) -> Bool {
            guard index + p.count <= s.count else { return false }
            for k in 0..<p.count where lower(s[index + k]) != p[k] { return false }
            return true
        }
        func find(_ needle: String, from index: Int) -> Int? {
            let p = Array(needle.lowercased().unicodeScalars)
            var j = index
            while j < s.count { if starts(p, at: j) { return j }; j += 1 }
            return nil
        }
        func pastNext(_ needle: String, from index: Int) -> Int {
            find(needle, from: index).map { $0 + needle.unicodeScalars.count } ?? s.count
        }
        var i = 0
        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else {
                if !isSpace(c) { inject() }
                out.append(c); i += 1; continue
            }
            let next = s[i + 1]
            if starts(Array("<!--".unicodeScalars), at: i) { // dropped; an unterminated one runs to the end, as in browsers
                i = pastNext("-->", from: i + 4)
                continue
            }
            if next == "!" || next == "?" { // a doctype is kept; other bogus comments are dropped
                let end = pastNext(">", from: i)
                if starts(Array("<!doctype".unicodeScalars), at: i) { out.append(contentsOf: s[i..<end]) }
                i = end
                continue
            }
            let closing = next == "/"
            let nameStart = closing ? i + 2 : i + 1
            guard nameStart < s.count, isLetter(s[nameStart]) else { inject(); out.append(c); i += 1; continue }
            inject()
            var tag = Tag(closing: closing)
            i = parseTag(s, nameStart: nameStart, into: &tag)
            if closing {
                if !dropped.contains(tag.name) { out.append(contentsOf: "</\(tag.name)>".unicodeScalars) }
                continue
            }

            // Raw-text elements: their content isn't markup, so it must not be tokenized as tags.
            var rawText: String?
            if rawTextElements.contains(tag.name) {
                let end = find("</\(tag.name)", from: i) ?? s.count
                rawText = String(String.UnicodeScalarView(s[i..<end]))
                i = end
            }
            if dropped.contains(tag.name) || (tag.name == "meta" && (tag.has("http-equiv") || tag.has("charset"))) {
                continue // the raw text of <script>/<noscript> goes with it
            }
            out.append(contentsOf: tag.sanitized().unicodeScalars)
            if let raw = rawText {
                switch tag.name {
                case "style": out.append(contentsOf: css(raw).unicodeScalars)
                case "iframe", "noembed", "noframes": break
                default: out.append(contentsOf: raw.unicodeScalars)
                }
            }
        }
        return String(out)
    }

    /// Removed with their content. `<link>` only ever loads things (stylesheets, icons, preloads), and a local
    /// stylesheet could still import a remote one; `<noscript>` is where emails hide fallback tracking pixels.
    private static let dropped: Set<String> = ["script", "noscript", "base", "link"]
    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "xmp", "noembed",
                                                       "noframes", "iframe", "noscript"]
    /// Embedded documents could load remote content of their own, so they lose every URL.
    static let embedders: Set<String> = ["iframe", "frame", "object", "embed", "applet", "portal"]

    // MARK: Tags

    private struct Tag {
        let closing: Bool
        var name = ""
        var attributes: [(name: String, value: String?)] = []

        func has(_ attribute: String) -> Bool { attributes.contains { $0.name == attribute } }

        func sanitized() -> String {
            var text = "<" + name
            for (attr, raw) in attributes {
                guard var value = raw else { text += " " + attr; continue }
                if HTMLSanitizer.urlAttributes.contains(attr) && !(attr == "href" && (name == "a" || name == "area")) {
                    let safe = HTMLSanitizer.embedders.contains(name) || attr == "srcdoc" ? false
                        : attr == "srcset" || attr == "imagesrcset" ? HTMLSanitizer.srcsetIsLocal(value)
                        : HTMLSanitizer.isLocal(value)
                    guard safe else { continue }
                } else if attr == "content" && name == "meta" {
                    value = ""
                } else if attr.hasPrefix("on") {
                    continue // event handlers
                } else if value.contains(where: { "(@\\".contains($0) }) {
                    value = HTMLSanitizer.css(value) // style="", SVG fill="url(…)" and the like
                }
                text += " \(attr)=\"\(HTMLSanitizer.escape(value))\""
            }
            return text + ">"
        }
    }

    static let urlAttributes: Set<String> = [
        "src", "srcset", "imagesrcset", "href", "xlink:href", "background", "poster", "data", "action", "formaction",
        "codebase", "cite", "longdesc", "usemap", "profile", "lowsrc", "dynsrc", "manifest", "icon", "archive",
        "classid", "ping", "code", "itemtype", "srcdoc", "xml:base",
    ]

    /// Parses from the tag name to just past `>` (HTML tokenizer rules: quotes only matter after `=`).
    private static func parseTag(_ s: [Unicode.Scalar], nameStart: Int, into tag: inout Tag) -> Int {
        var i = nameStart
        var name = ""
        while i < s.count, !isSpace(s[i]), s[i] != "/", s[i] != ">" { name.unicodeScalars.append(lower(s[i])); i += 1 }
        tag.name = name
        while i < s.count {
            while i < s.count, isSpace(s[i]) || s[i] == "/" { i += 1 }
            guard i < s.count else { break }
            if s[i] == ">" { return i + 1 }
            var attr = ""
            repeat { attr.unicodeScalars.append(lower(s[i])); i += 1 }
            while i < s.count && !isSpace(s[i]) && s[i] != "/" && s[i] != ">" && s[i] != "="
            var j = i
            while j < s.count, isSpace(s[j]) { j += 1 }
            guard j < s.count, s[j] == "=" else { tag.attributes.append((attr, nil)); continue }
            i = j + 1
            while i < s.count, isSpace(s[i]) { i += 1 }
            var value = String.UnicodeScalarView()
            if i < s.count, s[i] == "\"" || s[i] == "'" {
                let quote = s[i]; i += 1
                while i < s.count, s[i] != quote { value.append(s[i]); i += 1 }
                i += 1
            } else {
                while i < s.count, !isSpace(s[i]), s[i] != ">" { value.append(s[i]); i += 1 }
            }
            tag.attributes.append((attr, decodeEntities(String(value))))
        }
        return s.count
    }

    // MARK: URLs

    static func isLocal(_ raw: String) -> Bool {
        // Browsers ignore whitespace/control characters inside URLs and treat `\` like `/`.
        let url = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
            .replacingOccurrences(of: "\\", with: "/").lowercased()
        if url.isEmpty || url.hasPrefix("#") { return true }
        if url.hasPrefix("//") { return false }
        if url.hasPrefix("data:") { return true }
        if url.hasPrefix("file:") { return !url.hasPrefix("file://") || url.hasPrefix("file:///") }
        // Any other scheme (http, https, ftp, ws, javascript, …) is refused; a ":" before any "/", "?" or "#"
        // means a scheme.
        if let colon = url.firstIndex(of: ":") {
            let beforeColon = url[..<colon]
            if !beforeColon.contains(where: { "/?#".contains($0) }) { return false }
        }
        return true
    }

    static func srcsetIsLocal(_ raw: String) -> Bool {
        raw.split(separator: ",").allSatisfy { candidate in
            let url = candidate.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init) ?? ""
            return isLocal(url)
        }
    }

    // MARK: CSS

    /// Disables every way CSS can load a resource. Escapes are decoded first so `\75rl(` can't sneak through.
    static func css(_ raw: String) -> String {
        var text = decodeCSSEscapes(raw)
        text = text.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)@import"#, with: "@blocked-import", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\b(url|image-set|image|cross-fade|element|src)\s*\("#, with: "blocked(",
                                         options: .regularExpression)
        return text
    }

    private static func decodeCSSEscapes(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        let s = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            guard s[i] == "\\", i + 1 < s.count else { out.append(s[i]); i += 1; continue }
            i += 1
            var hex = ""
            while i < s.count, hex.count < 6, s[i].properties.isASCIIHexDigit { hex.unicodeScalars.append(s[i]); i += 1 }
            if hex.isEmpty {
                if s[i] != "\n" { out.append(s[i]) }
                i += 1
            } else {
                if i < s.count, isSpace(s[i]) { i += 1 }
                out.append(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
            }
        }
        return String(out)
    }

    // MARK: Characters

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "colon": ":", "sol": "/", "period": ".",
        "tab": "\t", "newline": "\n", "nbsp": "\u{A0}", "lpar": "(", "rpar": ")", "bsol": "\\", "num": "#",
        "quest": "?", "equals": "=", "commat": "@", "excl": "!", "comma": ",", "semi": ";", "percnt": "%",
    ]

    /// Decodes character references the way a browser would before using an attribute value. Unknown named
    /// references are left as they are.
    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let pattern = try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);?")
        let ns = raw as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body.lowercased()]
            }
            out += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
    private static func isLetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
    private static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        c >= "A" && c <= "Z" ? Unicode.Scalar(c.value + 32)! : c
    }
}
