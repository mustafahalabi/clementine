import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Reads and edits the common metadata fields of images, audio/video and PDFs.
///
/// Edits arrive as a JSON object of field keys to new values (`{"title": "Lisbon", "rating": 4}`); keys left out
/// stay as they are and an empty string clears a field. Every writer leaves the original alone and saves an
/// `(edited)` copy without re-encoding: ImageIO copies the compressed image data, ffmpeg copies streams, and
/// PDFKit rewrites only the document info.
enum MetadataEngine {
    enum Kind {
        case image, media, pdf

        init?(_ url: URL) {
            switch FileItem(url: url).kind {
            case .image: self = .image
            case .video, .audio: self = .media
            case .pdf: self = .pdf
            default: return nil
            }
        }

        var noun: String {
            switch self {
            case .image: "images"
            case .media: "audio and video"
            case .pdf: "PDFs"
            }
        }
    }

    struct Field: Identifiable, Hashable {
        enum Style { case text, multiline, keywords, date, year, track, rating }
        let key: String
        let label: String
        var placeholder = ""
        var style = Style.text
        var id: String { key }
    }

    /// The editable fields for a kind of file, in display order.
    static func fields(for kind: Kind) -> [Field] {
        switch kind {
        case .image:
            [Field(key: "title", label: "Title", placeholder: "Sunset over Lisbon"),
             Field(key: "description", label: "Description", placeholder: "What's in the picture", style: .multiline),
             Field(key: "artist", label: "Artist", placeholder: "Who took it"),
             Field(key: "copyright", label: "Copyright", placeholder: "© 2026 Your Name"),
             Field(key: "keywords", label: "Keywords", placeholder: "Add keyword", style: .keywords),
             Field(key: "date", label: "Date taken", placeholder: "2026-07-14 18:42", style: .date),
             Field(key: "rating", label: "Rating", style: .rating)]
        case .media:
            [Field(key: "title", label: "Title", placeholder: "Song or video title"),
             Field(key: "artist", label: "Artist", placeholder: "Performer"),
             Field(key: "album", label: "Album", placeholder: "Album"),
             Field(key: "album_artist", label: "Album artist", placeholder: "Various Artists"),
             Field(key: "year", label: "Year", placeholder: "2026", style: .year),
             Field(key: "genre", label: "Genre", placeholder: "Genre"),
             Field(key: "track", label: "Track", placeholder: "3 or 3/12", style: .track),
             Field(key: "comment", label: "Comment", placeholder: "Notes", style: .multiline)]
        case .pdf:
            [Field(key: "title", label: "Title", placeholder: "Document title"),
             Field(key: "author", label: "Author", placeholder: "Who wrote it"),
             Field(key: "subject", label: "Subject", placeholder: "What it's about"),
             Field(key: "keywords", label: "Keywords", placeholder: "Add keyword", style: .keywords),
             Field(key: "creator", label: "Creator", placeholder: "App that made it")]
        }
    }

    /// Images only: set to true to drop GPS coordinates.
    static let removeLocationKey = "removeLocation"

    /// What the editor shows: current field values, read-only facts and the raw dump.
    struct Snapshot {
        var kind: Kind
        var values: [String: String] = [:]
        /// Read-only details (camera, lens, size, duration…), in display order.
        var facts: [(label: String, value: String)] = []
        /// Where an image was taken, formatted for display, and as signed degrees.
        var location: String?
        var coordinate: (latitude: Double, longitude: Double)?
        var dump = ""
    }

    static func read(_ url: URL) async throws -> Snapshot {
        guard let kind = Kind(url) else { throw ClementineError.message("Clementine can't edit the metadata of \(url.lastPathComponent).") }
        switch kind {
        case .image: return try readImage(url)
        case .media: return try await readMedia(url)
        case .pdf: return try readPDF(url)
        }
    }

    /// Whether edits can be saved without re-encoding: any audio, video or PDF, and JPEG, HEIC, TIFF or PNG images.
    static func canWrite(_ url: URL) -> Bool {
        guard let kind = Kind(url) else { return false }
        guard kind == .image else { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.jpeg, .heic, .heif, .tiff, .png].contains { type.conforms(to: $0) }
    }

    static func readOnlyReason(_ url: URL) -> String {
        "Clementine can't save metadata in \(url.pathExtension.uppercased()) files without re-encoding them. JPEG, HEIC, TIFF and PNG work."
    }

    /// Applies `json` edits and returns the `(edited)` copy.
    static func write(_ url: URL, json: String) async throws -> URL {
        guard let kind = Kind(url) else { throw ClementineError.message("Clementine can't edit the metadata of \(url.lastPathComponent).") }
        let edits = try parse(json, kind: kind)
        guard canWrite(url) else { throw ClementineError.message(readOnlyReason(url)) }
        switch kind {
        case .image: return try writeImage(url, edits)
        case .media: return try await writeMedia(url, edits)
        case .pdf: return try writePDF(url, edits)
        }
    }

    // MARK: Edits

    /// Decodes and validates edits, normalizing dates. Values may be strings, numbers, booleans or (keywords) arrays.
    static func parse(_ json: String, kind: Kind) throws -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ClementineError.message("Fields should be a JSON object, like {\"title\": \"Holiday\"}.")
        }
        let fields = fields(for: kind)
        var edits: [String: String] = [:]
        for (key, raw) in object {
            if kind == .image && key == removeLocationKey {
                edits[key] = (raw as? Bool ?? (raw as? String).map { ["true", "1", "yes"].contains($0.lowercased()) } ?? false) ? "true" : "false"
                continue
            }
            guard let field = fields.first(where: { $0.key == key }) else {
                var known = fields.map(\.key)
                if kind == .image { known.append(removeLocationKey) }
                throw ClementineError.message("“\(key)” isn't a field Clementine edits for \(kind.noun). Use \(known.joined(separator: ", ")).")
            }
            let text: String
            switch raw {
            case let string as String: text = string
            case let list as [Any]: text = list.map { "\($0)" }.joined(separator: ", ")
            case is NSNull: text = ""
            case let number as NSNumber: text = number.stringValue
            default: text = "\(raw)"
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = problem(with: trimmed, for: field) { throw ClementineError.message(problem) }
            edits[key] = field.style == .date && !trimmed.isEmpty ? exifDate(trimmed)! : trimmed
        }
        return edits
    }

    /// Why `value` isn't acceptable for `field`, or nil if it is (empty always is: it clears the field).
    static func problem(with value: String, for field: Field) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch field.style {
        case .date:
            return exifDate(value) == nil ? "“\(value)” isn't a valid date. Use YYYY-MM-DD HH:MM." : nil
        case .year:
            return matches(value, #"\d{4}"#) || exifDate(value) != nil && matches(value, #"\d{4}-\d{2}-\d{2}"#)
                ? nil : "“\(value)” isn't a year. Use 2026, or a full date like 2026-07-14."
        case .track:
            return matches(value, #"\d{1,4}(\s*/\s*\d{1,4})?"#) ? nil : "Track should be a number like 3, or 3/12."
        case .rating:
            return Int(value).map { (0...5).contains($0) } == true ? nil : "Rating should be 0 to 5 stars."
        case .text, .multiline, .keywords:
            return nil
        }
    }

    /// Accepts `2026-07-14`, `2026-07-14 18:42[:09]`, `2026-07-14T18:42:09` and EXIF's `2026:07:14 18:42:09`;
    /// returns the EXIF form, or nil for anything else (including impossible dates like February 30th).
    static func exifDate(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "T", with: " ")
        guard matches(cleaned, #"\d{4}[-:]\d{2}[-:]\d{2}( \d{2}:\d{2}(:\d{2})?)?"#) else { return nil }
        // Normalize to `yyyy-MM-dd HH:mm:ss`, filling in a missing time or seconds.
        var candidate = String(cleaned.prefix(10)).replacingOccurrences(of: ":", with: "-") + String(cleaned.dropFirst(10))
        if candidate.count == 10 { candidate += " 00:00" }
        if candidate.count == 16 { candidate += ":00" }
        guard let date = secondFormatter.date(from: candidate),
              secondFormatter.string(from: date) == candidate // rejects rollovers like 02-30
        else { return nil }
        return exifFormatter.string(from: date)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "^\(pattern)$", options: .regularExpression) != nil
    }

    /// EXIF `2026:07:14 18:42:09` → `2026-07-14 18:42:09` for display.
    static func displayDate(_ exif: String) -> String {
        guard let date = exifFormatter.date(from: exif) else { return exif }
        return secondFormatter.string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static let secondFormatter = formatter("yyyy-MM-dd HH:mm:ss")
    private static let exifFormatter = formatter("yyyy:MM:dd HH:mm:ss")

    static func keywords(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Images

    private static func readImage(_ url: URL) throws -> Snapshot {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { throw ClementineError.unreadable(url) }
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        func tag(_ path: String) -> [String] { xmp.map { tagStrings($0, path) } ?? [] }
        /// The first candidate with a value (XMP first, then its EXIF/IPTC twin), lists joined with commas.
        func first(_ candidates: Any?...) -> String {
            for candidate in candidates {
                let list: [String] = switch candidate {
                case let strings as [String]: strings
                case let values as [Any]: values.map { "\($0)" }
                case let value?: ["\(value)"]
                case nil: []
                }
                let joined = list.filter { !$0.isEmpty }.joined(separator: ", ")
                if !joined.isEmpty { return joined }
            }
            return ""
        }

        var snapshot = Snapshot(kind: .image)
        snapshot.values = [
            "title": first(tag("dc:title"), iptc[kCGImagePropertyIPTCObjectName as String]),
            "description": first(tag("dc:description"), tiff[kCGImagePropertyTIFFImageDescription as String]),
            "artist": first(tag("dc:creator"), tiff[kCGImagePropertyTIFFArtist as String]),
            "copyright": first(tag("dc:rights"), tiff[kCGImagePropertyTIFFCopyright as String]),
            "keywords": first(tag("dc:subject"), iptc[kCGImagePropertyIPTCKeywords as String]),
            "date": (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).map(displayDate) ?? "",
            "rating": first(tag("xmp:Rating"), iptc[kCGImagePropertyIPTCStarRating as String]),
        ]
        if let date = snapshot.values["date"], date.isEmpty, let created = tag("xmp:CreateDate").first ?? tag("photoshop:DateCreated").first {
            snapshot.values["date"] = exifDate(String(created.prefix(19))).map(displayDate) ?? created
        }

        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { snapshot.facts.append(("Camera", camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String, !lens.isEmpty { snapshot.facts.append(("Lens", lens)) }
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            snapshot.facts.append(("Size", "\(width) × \(height)"))
        }
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let north = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N").uppercased()
            let east = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E").uppercased()
            snapshot.location = String(format: "%.4f° %@, %.4f° %@", latitude, north, longitude, east)
            snapshot.coordinate = (north == "S" ? -latitude : latitude, east == "W" ? -longitude : longitude)
        }
        snapshot.dump = (try? ImageTools.metadata(url)) ?? ""
        return snapshot
    }

    /// A tag's value as strings: one for simple values, several for arrays and alternative-language text.
    private static func tagStrings(_ metadata: CGImageMetadata, _ path: String) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return [] }
        func strings(_ value: Any?) -> [String] {
            switch value {
            case let string as String: return [string]
            case let number as NSNumber: return [number.stringValue]
            case let list as [Any]:
                return list.flatMap { item -> [String] in
                    CFGetTypeID(item as CFTypeRef) == CGImageMetadataTagGetTypeID()
                        ? strings(CGImageMetadataTagCopyValue(item as! CGImageMetadataTag)) : strings(item)
                }
            default: return []
            }
        }
        return strings(CGImageMetadataTagCopyValue(tag))
    }

    private static func writeImage(_ url: URL, _ edits: [String: String]) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0
        else { throw ClementineError.unreadable(url) }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()

        func remove(_ paths: String...) {
            for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
        }
        func set(_ path: String, _ value: Any) {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFTypeRef)
        }
        // ImageIO keeps the EXIF/TIFF/IPTC twins of these XMP tags in step when it writes the file.
        for (key, value) in edits {
            switch key {
            case "title":
                value.isEmpty ? remove("dc:title") : set("dc:title", value)
            case "description":
                value.isEmpty ? remove("dc:description", "tiff:ImageDescription") : set("dc:description", value)
            case "artist":
                if value.isEmpty {
                    remove("dc:creator", "tiff:Artist")
                } else if let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                             "creator" as CFString, .arrayOrdered, [value] as CFArray) {
                    CGImageMetadataSetTagWithPath(metadata, nil, "dc:creator" as CFString, tag)
                }
            case "copyright":
                value.isEmpty ? remove("dc:rights", "tiff:Copyright") : set("dc:rights", value)
            case "keywords":
                let list = keywords(value)
                list.isEmpty ? remove("dc:subject") : set("dc:subject", list)
            case "date":
                remove("exif:DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate")
                if !value.isEmpty {
                    CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                                 kCGImagePropertyExifDateTimeOriginal, value as CFString)
                }
            case "rating":
                let stars = Int(value) ?? 0
                stars > 0 ? set("xmp:Rating", "\(stars)") : remove("xmp:Rating")
            default:
                break
            }
        }

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let output = Output.file(beside: url, suffix: "edited", ext: ext)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw ClementineError.message("Couldn't write \(output.lastPathComponent).")
        }
        let dropGPS = edits[removeLocationKey] == "true"
        var ok: Bool
        if (type as String) == "public.png" {
            // ImageIO can't swap PNG metadata in place; PNG is lossless, so re-saving keeps every pixel.
            guard CGImageSourceGetCount(source) == 1, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ClementineError.message("Clementine can't edit the metadata of animated PNGs.")
            }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata,
                                                  [kCGImageMetadataShouldExcludeGPS: dropGPS] as CFDictionary)
            ok = CGImageDestinationFinalize(destination)
        } else {
            // Copies the compressed image data as-is: no re-encoding, no quality loss.
            ok = CGImageDestinationCopyImageSource(destination, source, [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: dropGPS,
            ] as CFDictionary, nil)
        }
        guard ok else {
            try? FileManager.default.removeItem(at: output)
            throw ClementineError.message(readOnlyReason(url))
        }
        return output
    }

    // MARK: Audio & video

    /// JSON field key → ffmpeg tag name.
    private static let mediaTags = ["title": "title", "artist": "artist", "album": "album", "album_artist": "album_artist",
                                    "year": "date", "genre": "genre", "track": "track", "comment": "comment"]

    private static func readMedia(_ url: URL) async throws -> Snapshot {
        _ = try await FFmpeg.readable(url)
        let ffprobe = try ToolLocator.require("ffprobe")
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration,format_name:format_tags:stream=codec_type,codec_name,width,height:stream_tags:stream_disposition=attached_pic",
            "-of", "json", url.path,
        ])
        let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []

        // Tag names vary in case by container (TITLE in FLAC/Ogg); Ogg keeps them on the audio stream.
        var tags: [String: String] = [:]
        let audioTags = streams.first { $0["codec_type"] as? String == "audio" }?["tags"] as? [String: Any] ?? [:]
        for source in [audioTags, format["tags"] as? [String: Any] ?? [:]] {
            for (key, value) in source { tags[key.lowercased()] = "\(value)" }
        }
        var snapshot = Snapshot(kind: .media)
        for (field, tag) in mediaTags { snapshot.values[field] = tags[tag] ?? (tag == "date" ? tags["year"] : nil) ?? "" }

        if let duration = (format["duration"] as? String).flatMap(Double.init) {
            snapshot.facts.append(("Length", Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        for stream in streams {
            let codec = (stream["codec_name"] as? String ?? "").uppercased()
            let cover = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
            switch stream["codec_type"] as? String {
            case "video" where cover: snapshot.facts.append(("Cover art", "\(stream["width"] ?? "?") × \(stream["height"] ?? "?")"))
            case "video": snapshot.facts.append(("Video", "\(codec), \(stream["width"] ?? "?") × \(stream["height"] ?? "?")"))
            case "audio": snapshot.facts.append(("Audio", codec))
            default: break
            }
        }
        snapshot.dump = (try? await MediaEngine.metadata(url)) ?? ""
        return snapshot
    }

    private static func writeMedia(_ url: URL, _ edits: [String: String]) async throws -> URL {
        let info = try await FFmpeg.readable(url)
        let ext = url.pathExtension.lowercased()
        // Ogg-family files keep their tags on the audio stream, which would otherwise win over the global ones.
        let streamTags = ["ogg", "oga", "opus", "spx"].contains(ext)
        var args = ["-map", "0", "-c", "copy", "-ignore_unknown", "-map_metadata", "0"]
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            guard let tag = mediaTags[key] else { continue }
            args += ["-metadata", "\(tag)=\(value)"]
            if streamTags { args += ["-metadata:s:a:0", "\(tag)=\(value)"] }
        }
        if ["mp4", "m4a", "m4v", "mov"].contains(ext) { args += ["-movflags", "+faststart"] }
        let output = Output.file(beside: url, suffix: "edited", ext: ext)
        return try await FFmpeg.transcode(url, to: output, args: args, duration: info.duration, progress: { _ in })
    }

    // MARK: PDF

    private static let pdfAttributes: [String: PDFDocumentAttribute] = [
        "title": .titleAttribute, "author": .authorAttribute, "subject": .subjectAttribute,
        "keywords": .keywordsAttribute, "creator": .creatorAttribute,
    ]

    private static func readPDF(_ url: URL) throws -> Snapshot {
        let document = try PDFEngine.open(url)
        let attributes = document.documentAttributes ?? [:]
        var snapshot = Snapshot(kind: .pdf)
        for (key, attribute) in pdfAttributes {
            switch attributes[attribute] {
            case let list as [Any]: snapshot.values[key] = list.map { "\($0)" }.joined(separator: ", ")
            case let value?: snapshot.values[key] = "\(value)"
            case nil: snapshot.values[key] = ""
            }
        }
        snapshot.facts = [("Pages", "\(document.pageCount)"), ("Version", "PDF \(document.majorVersion).\(document.minorVersion)")]
        if let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String, !producer.isEmpty {
            snapshot.facts.append(("Producer", producer))
        }
        snapshot.dump = (try? PDFEngine.metadata(url)) ?? ""
        return snapshot
    }

    private static func writePDF(_ url: URL, _ edits: [String: String]) throws -> URL {
        let document = try PDFEngine.open(url)
        var attributes = document.documentAttributes ?? [:]
        for (key, value) in edits {
            guard let attribute = pdfAttributes[key] else { continue }
            if value.isEmpty {
                attributes.removeValue(forKey: attribute)
            } else {
                attributes[attribute] = key == "keywords" ? keywords(value) : value
            }
        }
        document.documentAttributes = attributes
        let output = Output.file(beside: url, suffix: "edited", ext: "pdf")
        guard document.write(to: output) else {
            try? FileManager.default.removeItem(at: output)
            throw ClementineError.message("Couldn't write \(output.lastPathComponent).")
        }
        return output
    }
}
