import Foundation

enum ArchiveFormat: String, CaseIterable {
    case zip, tar, gzip

    var label: String { rawValue.uppercased() }
}

/// Archives through the tools that ship with macOS: bsdtar (writes zip/tar, reads zip/tar/gz/rar/7z),
/// gzip (also reads xz), bzip2.
enum ArchiveEngine {
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
        let names = staging.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()) ?? [] }
            ?? inputs.map(\.lastPathComponent)
        // Member names come from the user's files or from an archive being repacked, so they can look like options
        // ("-m", "--use-compress-program=…") or bsdtar's "@archive" syntax. As "./name" after "--" they're only
        // ever paths; `-s` strips the "./" again so the archive holds plain names.
        let members = ["--"] + names.map { "./" + $0 }
        let packing = ["--exclude", ".DS_Store", "--exclude", "__MACOSX", "-s", ",^\\./,,S", "-C", parent.path]

        switch format {
        case .zip:
            // bsdtar rather than /usr/bin/zip: it marks non-ASCII names as UTF-8 (Windows garbles them otherwise),
            // stores symlinks as links, and never expands wildcards in names.
            let output = Output.file(in: dir, base: base, ext: "zip")
            try await Output.produce(output) {
                try await ProcessRunner.run(tar, ["-c", "--format", "zip", "-f", output.path] + packing + members)
            }
            return output
        case .tar:
            let output = Output.file(in: dir, base: base, ext: "tar")
            try await Output.produce(output) {
                try await ProcessRunner.run(tar, ["-c", "-f", output.path] + packing + members)
            }
            return output
        case .gzip:
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            if inputs.count == 1 && !isDir.boolValue {
                // `a.txt` → `a.txt.gz`, or `a 2.txt.gz` on a clash, so it still unpacks to a .txt.
                let ext = first.pathExtension
                let output = ext.isEmpty
                    ? Output.file(in: dir, base: first.lastPathComponent, ext: "gz")
                    : Output.file(in: dir, base: first.deletingPathExtension().lastPathComponent, ext: "\(ext).gz")
                try await Output.produce(output) {
                    try await ProcessRunner.run(gzip, ["-c", "-9", first.path], stdoutFile: output)
                }
                return output
            }
            let output = Output.file(in: dir, base: base, ext: "tar.gz")
            try await Output.produce(output) {
                try await ProcessRunner.run(tar, ["-c", "-z", "-f", output.path] + packing + members)
            }
            return output
        }
    }

    /// Extracts next to the archive. A single top-level item lands directly; several go in a folder.
    static func extract(_ archive: URL) async throws -> URL {
        let dir = archive.deletingLastPathComponent()
        try checkNotEmpty(archive)
        if let tool = plainDecompressor(archive) {
            let output = Output.file(in: dir, sameNameAs: innerName(archive))
            try await Output.produce(output) {
                try await guarding(archive, writingTo: output) {
                    try await decompress(archive, with: tool, to: output)
                }
            }
            return output
        }

        let staging = try await unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        let items = try contents(of: staging)
        let fm = FileManager.default
        if items.count == 1 {
            let output = Output.file(in: dir, sameNameAs: items[0])
            try fm.moveItem(at: items[0], to: output)
            return output
        }
        let folder = Output.file(in: dir, base: baseName(archive), ext: "")
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
            try await guarding(archive, writingTo: staging) {
                if let tool = plainDecompressor(archive) {
                    try await decompress(archive, with: tool, to: staging.appendingPathComponent(innerName(archive).lastPathComponent))
                } else {
                    try await ProcessRunner.run(tar, ["-x", "-f", archive.path, "-C", staging.path])
                }
            }
            try removeEscapingLinks(in: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    // MARK: Safety

    /// Below this, any expansion is fine; above it, an archive may grow at most `maxRatio` times its own size.
    private static let bombFloor: Int64 = 1 << 30
    private static let maxRatio: Int64 = 250
    /// Never fill the disk past this, whatever the archive says.
    private static let reserve: Int64 = 512 << 20

    /// Runs an extraction into `target` while guarding against decompression bombs. Archives with an index
    /// (zip, 7z, rar) are checked up front from their listing; since a listing can lie and tar streams have
    /// none, a watchdog also stops the tool once the disk has filled by more than the limit allows, and the result is
    /// measured once more at the end.
    private static func guarding(_ archive: URL, writingTo target: URL, _ work: @escaping @Sendable () async throws -> Void) async throws {
        let archiveSize = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let folder = target.deletingLastPathComponent()
        let startFree = freeBytes(folder) ?? Int64.max
        let ratioLimit = max(bombFloor, archiveSize.multipliedReportingOverflow(by: maxRatio).overflow ? .max : archiveSize * maxRatio)
        let tooBig = ClementineError.message(
            "\(archive.lastPathComponent) expands to far more than an archive of its size should, so Clementine stopped. "
            + "If you trust it, extract it with Archive Utility.")
        let noSpace = { (needed: Int64?) in
            ClementineError.message("There isn't enough free space to extract \(archive.lastPathComponent)"
                + (needed.map { " (it needs \(Double($0).megabytes))." } ?? "."))
        }

        if hasIndex(archive), let claimed = try? await listedSize(archive) {
            if claimed > ratioLimit { throw tooBig }
            let available = importantFreeBytes(folder) ?? startFree
            if claimed > available - reserve { throw noSpace(claimed) }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    guard let free = freeBytes(folder) else { continue }
                    if free < reserve { throw noSpace(nil) }
                    // The volume's free space is cheap to read but counts other writers too; confirm by measuring.
                    if startFree - free > ratioLimit, allocatedSize(target) > ratioLimit { throw tooBig }
                }
            }
            // Whichever finishes first decides; cancelling the other stops the tool or the watchdog.
            try await group.next()
            group.cancelAll()
        }
        // The watchdog samples; a fast tool can finish in between.
        if allocatedSize(target) > ratioLimit { throw tooBig }
    }

    /// Zip, 7z and rar list their contents from an index without decompressing; tar streams don't.
    private static func hasIndex(_ archive: URL) -> Bool {
        ["zip", "7z", "rar"].contains(archive.pathExtension.lowercased())
    }

    /// The total size the archive's listing claims, from `bsdtar -tv` (size is the fifth column).
    private static func listedSize(_ archive: URL) async throws -> Int64 {
        let listing = try await ProcessRunner.run(tar, ["-t", "-v", "-f", archive.path]).stdout
        var total: Int64 = 0
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            if fields.count > 4, let size = Int64(fields[4]) {
                total = total.addingReportingOverflow(size).overflow ? .max : total + size
            }
        }
        return total
    }

    private static func freeBytes(_ folder: URL) -> Int64? {
        var stats = statfs()
        guard statfs(folder.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Includes space macOS would free on demand (purgeable caches), so it's what an extraction can really use.
    private static func importantFreeBytes(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        var total = Int64((try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return total }
        for case let item as URL in walker {
            total += Int64((try? item.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Drops symlinks that point outside the extracted items (absolute targets, `..` paths, or chains through other
    /// links), and ones that lead nowhere: once moved next to the archive they could expose or overwrite the
    /// user's files. bsdtar already refuses to write through links while extracting.
    private static func removeEscapingLinks(in staging: URL) throws {
        let fm = FileManager.default
        // realpath, not resolvingSymlinksInPath: Foundation drops /private from /private/var, realpath keeps it.
        guard let realRoot = realpath(staging.path, nil) else { return }
        let root = String(cString: realRoot)
        free(realRoot)
        var removedAny = true
        // Removing one link can strand another that went through it, so repeat until nothing changes.
        while removedAny {
            removedAny = false
            guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
            for case let item as URL in walker {
                guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
                let target = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? "/"
                var resolved: String?
                if !target.hasPrefix("/"), let real = realpath(item.path, nil) {
                    resolved = String(cString: real)
                    free(real)
                }
                if let resolved, resolved.hasPrefix(root + "/") { continue }
                try fm.removeItem(at: item)
                removedAny = true
            }
        }
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
