import Foundation

enum ArchiveFormat: String, CaseIterable {
    case zip, tar, gzip

    var label: String { rawValue.uppercased() }
}

/// Archives through the tools that ship with macOS: zip, bsdtar (reads zip/tar/gz/rar/7z), gzip (also reads xz), bzip2.
enum ArchiveEngine {
    private static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    private static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    private static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    private static let bzip2 = URL(fileURLWithPath: "/usr/bin/bzip2")

    /// Packs `inputs` into one archive. Defaults to sitting next to the first input.
    static func create(_ inputs: [URL], format: ArchiveFormat, in destination: URL? = nil, name: String? = nil) async throws -> URL {
        let first = inputs[0]
        let firstParent = first.deletingLastPathComponent().standardizedFileURL
        let dir = destination ?? firstParent
        let base = name ?? (inputs.count == 1 ? first.lastPathComponent : "Archive")

        // Files from different folders (search results, Recents) are copied side by side first,
        // so the archive holds plain names rather than absolute paths. On APFS the copies are clones.
        var parent = firstParent
        var staging: URL?
        if !inputs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == firstParent }) {
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: dir, create: true)
            staging = folder
            parent = folder
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        if let staging {
            for input in inputs {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: input, to: Output.unique(in: staging, sameNameAs: input))
            }
        }
        let members = staging.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()) ?? [] }
            ?? inputs.map(\.lastPathComponent)

        switch format {
        case .zip:
            let output = Output.unique(in: dir, base: base, ext: "zip")
            try await Output.produce(output) {
                try await ProcessRunner.run(zip, ["-r", "-y", "-q", output.path] + members + ["-x", "*.DS_Store", "-x", "__MACOSX/*"],
                                            currentDirectory: parent)
            }
            return output
        case .tar:
            let output = Output.unique(in: dir, base: base, ext: "tar")
            try await Output.produce(output) {
                try await ProcessRunner.run(tar, ["-c", "-f", output.path, "--exclude", ".DS_Store", "-C", parent.path] + members)
            }
            return output
        case .gzip:
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            if inputs.count == 1 && !isDir.boolValue {
                // `a.txt` → `a.txt.gz`, or `a 2.txt.gz` on a clash, so it still unpacks to a .txt.
                let ext = first.pathExtension
                let output = ext.isEmpty
                    ? Output.unique(in: dir, base: first.lastPathComponent, ext: "gz")
                    : Output.unique(in: dir, base: first.deletingPathExtension().lastPathComponent, ext: "\(ext).gz")
                try await Output.produce(output) {
                    try await ProcessRunner.run(gzip, ["-c", "-9", first.path], stdoutFile: output)
                }
                return output
            }
            let output = Output.unique(in: dir, base: base, ext: "tar.gz")
            try await Output.produce(output) {
                try await ProcessRunner.run(tar, ["-c", "-z", "-f", output.path, "--exclude", ".DS_Store", "-C", parent.path] + members)
            }
            return output
        }
    }

    /// Extracts next to the archive. A single top-level item lands directly; several go in a folder.
    static func extract(_ archive: URL) async throws -> URL {
        let dir = archive.deletingLastPathComponent()
        try checkNotEmpty(archive)
        if let tool = plainDecompressor(archive) {
            let output = Output.unique(in: dir, sameNameAs: innerName(archive))
            try await Output.produce(output) {
                try await decompress(archive, with: tool, to: output)
            }
            return output
        }

        let staging = try await unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        let items = try contents(of: staging)
        let fm = FileManager.default
        if items.count == 1 {
            let output = Output.unique(in: dir, sameNameAs: items[0])
            try fm.moveItem(at: items[0], to: output)
            return output
        }
        let folder = Output.unique(in: dir, base: baseName(archive), ext: "")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for item in items {
            try fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
        }
        return folder
    }

    /// e.g. RAR → ZIP: unpack to a temporary folder, then pack again.
    static func repack(_ archive: URL, to format: ArchiveFormat) async throws -> URL {
        try checkNotEmpty(archive)
        let staging = try await unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        let items = try contents(of: staging)
        return try await create(items, format: format, in: archive.deletingLastPathComponent(), name: baseName(archive))
    }

    // MARK: Helpers

    /// Unpacks into a temporary folder. A plain `.gz`/`.bz2`/`.xz` (one compressed file, no tar inside)
    /// is decompressed there under its inner name; everything else goes through bsdtar.
    private static func unpack(_ archive: URL) async throws -> URL {
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: archive.deletingLastPathComponent(), create: true)
        do {
            if let tool = plainDecompressor(archive) {
                try await decompress(archive, with: tool, to: staging.appendingPathComponent(innerName(archive).lastPathComponent))
            } else {
                try await ProcessRunner.run(tar, ["-x", "-f", archive.path, "-C", staging.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Writes the decompressed stream to `output`. Corrupt input reads as unreadable, not as raw tool output.
    private static func decompress(_ archive: URL, with tool: URL, to output: URL) async throws {
        do {
            try await ProcessRunner.run(tool, ["-d", "-c", archive.path], stdoutFile: output)
        } catch ClementineError.toolFailed {
            try? FileManager.default.removeItem(at: output)
            throw ClementineError.unreadable(archive)
        }
    }

    /// A 0-byte file would otherwise surface a raw "unexpected end of file" from the tool.
    private static func checkNotEmpty(_ archive: URL) throws {
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if size == 0 { throw ClementineError.message("The archive is empty.") }
    }

    private static func contents(of dir: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard !items.isEmpty else { throw ClementineError.message("The archive is empty.") }
        return items
    }

    /// The tool that decompresses a single-file `.gz`/`.bz2`/`.xz`, or nil for tarballs and real archives.
    /// Apple's gzip also reads xz, and macOS ships no xz binary.
    private static func plainDecompressor(_ url: URL) -> URL? {
        let name = url.lastPathComponent.lowercased()
        guard !name.hasSuffix(".tar.gz"), !name.hasSuffix(".tar.bz2"), !name.hasSuffix(".tar.xz") else { return nil }
        switch url.pathExtension.lowercased() {
        case "gz", "xz": return gzip
        case "bz2": return bzip2
        default: return nil
        }
    }

    /// `notes.txt.gz` → `notes.txt`.
    private static func innerName(_ archive: URL) -> URL {
        let name = archive.deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: name.isEmpty ? "Extracted" : name)
    }

    static func baseName(_ archive: URL) -> String {
        var name = archive.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz",
                       ".zip", ".tar", ".rar", ".7z", ".gz", ".bz2", ".xz"]
        where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }
}
