import Foundation

/// The ⇧ wheel: one slice per target format.
enum ConvertActions {
    static let all: [Action] = images + media + documents + pdf + subtitles + archives

    // MARK: Images

    static let images: [Action] = ImageFormat.allCases.map { format in
        Action(id: "convert.image.\(format.rawValue)", title: format.label, mode: .convert,
               accepts: { $0.kind == .image && !format.aliases.contains($0.ext) },
               run: { ctx in .files([try await ImageEngine.convert(ctx.input, to: format)]) })
    } + [
        Action(id: "convert.image.txt", title: "TXT", mode: .convert,
               accepts: { $0.kind == .image && $0.ext != "svg" },
               run: { ctx in .files([try ImageEngine.recognizeText(ctx.input)]) }),
        Action(id: "convert.image.mp4", title: "MP4", mode: .convert,
               accepts: { $0.ext == "gif" || ($0.ext == "webp" && ImageEngine.isAnimated($0.url)) },
               run: { ctx in
                   // ffmpeg can't decode animated WebP, so those frames come from ImageIO.
                   if ctx.input.pathExtension.lowercased() == "webp" {
                       return .files([try await ImageEngine.animationToVideo(ctx.input, ext: "mp4", progress: ctx.progress)])
                   }
                   return .files([try await MediaEngine.convert(ctx.input, to: "mp4", progress: ctx.progress)])
               }),
    ]

    // MARK: Video & audio

    static let videoTargets = ["mp4", "mov", "mkv", "avi", "wmv", "webm", "gif"]
    static let audioTargets = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
    /// Audio formats offered when the source is a video (extract the soundtrack).
    static let soundtrackTargets: Set = ["mp3", "m4a", "wav"]

    private static let synonyms: [String: Set<String>] = ["aiff": ["aif"], "ogg": ["oga"], "mp4": ["m4v"], "m4a": ["aac"]]

    private static func sameFormat(_ ext: String, _ target: String) -> Bool {
        ext == target || synonyms[target]?.contains(ext) == true
    }

    static let media: [Action] = (videoTargets + audioTargets).map { target in
        let isVideoTarget = videoTargets.contains(target)
        return Action(
            id: "convert.media.\(target)", title: target.uppercased(), mode: .convert,
            accepts: { item in
                guard !sameFormat(item.ext, target) else { return false }
                if isVideoTarget { return item.kind == .video }
                return item.kind == .audio || (item.kind == .video && soundtrackTargets.contains(target))
            },
            run: { ctx in .files([try await MediaEngine.convert(ctx.input, to: target, progress: ctx.progress)]) })
    }

    // MARK: Documents

    static let documents: [Action] = ["pdf", "docx", "txt", "rtf"].map { target in
        Action(id: "convert.document.\(target)", title: target.uppercased(), mode: .convert,
               accepts: { $0.kind == .document && $0.ext != target },
               run: { ctx in .files([try await DocumentEngine.convert(ctx.input, to: target)]) })
    }

    static let pdf: [Action] = [
        Action(id: "convert.pdf.txt", title: "TXT", mode: .convert, accepts: kinds(.pdf),
               run: { ctx in .files([try PDFEngine.toText(ctx.input)]) }),
        Action(id: "convert.pdf.docx", title: "DOCX", mode: .convert, accepts: kinds(.pdf),
               run: { ctx in .files([try await PDFEngine.toDOCX(ctx.input)]) }),
        Action(id: "convert.pdf.png", title: "PNG", mode: .convert, accepts: kinds(.pdf),
               run: { ctx in .files(try await PDFEngine.toImages(ctx.input, format: .png, progress: ctx.progress)) }),
        Action(id: "convert.pdf.jpeg", title: "JPG", mode: .convert, accepts: kinds(.pdf),
               run: { ctx in .files(try await PDFEngine.toImages(ctx.input, format: .jpeg, progress: ctx.progress)) }),
    ]

    static let subtitles: [Action] = ["srt", "vtt"].map { target in
        Action(id: "convert.subtitle.\(target)", title: target.uppercased(), mode: .convert,
               accepts: { $0.kind == .subtitle && $0.ext != target },
               run: { ctx in .files([try SubtitleEngine.convert(ctx.input, to: target)]) })
    }

    // MARK: Archives

    static let archives: [Action] = [
        Action(id: "convert.archive.extract", title: "Extract", mode: .convert, accepts: kinds(.archive),
               run: { ctx in .files([try await ArchiveEngine.extract(ctx.input)]) }),
    ] + ArchiveFormat.allCases.map { format in
        Action(id: "convert.archive.\(format.rawValue)", title: format.label, mode: .convert,
               accepts: { item in
                   guard item.kind == .archive else { return false }
                   switch format {
                   case .zip: return item.ext != "zip"
                   case .tar: return item.ext != "tar"
                   case .gzip: return !["gz", "tgz"].contains(item.ext)
                   }
               },
               run: { ctx in .files([try await ArchiveEngine.repack(ctx.input, to: format)]) })
    }

    /// Pack everything that was dropped into one archive. Offered as a fallback by `ActionRegistry`.
    static let archiveCreate: [Action] = ArchiveFormat.allCases.map { format in
        Action(id: "archive.\(format.rawValue)", title: format.label, mode: .convert, batch: true,
               accepts: { _ in true },
               run: { ctx in .files([try await ArchiveEngine.create(ctx.inputs, format: format)]) })
    }
}
