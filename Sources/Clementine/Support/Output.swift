import Foundation

/// Picks non-clobbering destinations next to the original file.
enum Output {
    /// `photo.png` → `photo.jpg`, or `photo (compressed).jpg` with a suffix. Never overwrites.
    static func file(beside input: URL, name: String? = nil, suffix: String? = nil, ext: String) -> URL {
        var base = name ?? input.deletingPathExtension().lastPathComponent
        if let suffix { base += " (\(suffix))" }
        return unique(in: input.deletingLastPathComponent(), base: base, ext: ext)
    }

    /// Creates a fresh folder next to `input`.
    static func folder(beside input: URL, name: String) throws -> URL {
        let url = unique(in: input.deletingLastPathComponent(), base: name, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A unique destination in `dir` for an existing item's name (keeps folder names with dots intact).
    static func unique(in dir: URL, sameNameAs item: URL) -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        if isDir.boolValue || item.pathExtension.isEmpty {
            return unique(in: dir, base: item.lastPathComponent, ext: "")
        }
        return unique(in: dir, base: item.deletingPathExtension().lastPathComponent, ext: item.pathExtension)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// Like `produce`, for an output folder that may not exist (single-file results need no cleanup here).
    static func filling<T>(_ folder: URL?, _ body: () async throws -> T) async throws -> T {
        guard let folder else { return try await body() }
        return try await produce(folder, body)
    }

    /// Runs `body`, deleting a half-written `url` if it throws.
    static func produce<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
