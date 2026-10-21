import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, subtitle, archive, folder, other
}

struct FileItem {
    let url: URL
    let kind: FileKind

    var ext: String { url.pathExtension.lowercased() }

    init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        // Any directory is a folder, whatever its name: `Vacation.mov/`, `backup.zip/`, and packages
        // like `Thing.app` alike. Folders only get the archive actions.
        kind = isDir.boolValue ? .folder : Self.classify(url)
    }

    private static func classify(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt", "vtt": return .subtitle
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "tbz", "tbz2", "xz", "txz": return .archive
        case "pdf": return .pdf
        case "docx", "doc", "txt", "rtf", "md", "html", "htm", "odt": return .document
        case "svg": return .image
        case "webm", "mkv", "wmv", "avi", "flv", "m4v", "mpg", "mpeg", "3gp": return .video
        case "opus", "ogg", "oga", "flac", "wma": return .audio
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .directory) || type.conforms(to: .package) { return .folder }
        if type.conforms(to: .text) { return .document }
        return .other
    }
}
