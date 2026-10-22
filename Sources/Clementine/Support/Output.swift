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
        return reservations.withLock { reserved in
            var candidate = make(base)
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
                candidate = make("\(base) \(n)")
                n += 1
            }
            if batches > 0 { reserved.insert(candidate.path) }
            return candidate
        }
    }

    // MARK: Reservations

    /// Names handed out while files run in parallel, so `photo.png` and `photo.heic` → JPG can't both pick
    /// `photo.jpg` before either is written. Cleared once no batch is running.
    private static let reservations = Locked(Set<String>())
    nonisolated(unsafe) private static var batches = 0

    static func beginBatch() {
        reservations.withLock { _ in batches += 1 }
    }

    static func endBatch() {
        reservations.withLock { reserved in
            batches -= 1
            if batches == 0 { reserved.removeAll() }
        }
    }

    /// Like `produce`, for an output folder that may not exist (single-file results need no cleanup here).
    static func filling<T>(_ folder: URL?, _ body: () async throws -> T) async throws -> T {
        guard let folder else { return try await body() }
        return try await produce(folder, body)
    }

    /// Runs `body`, deleting a half-written `url` if it throws.
    static func produce<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        inFlight.withLock { _ = $0.insert(url.path) }
        defer { inFlight.withLock { _ = $0.remove(url.path) } }
        do {
            return try await body()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Outputs being written right now.
    private static let inFlight = Locked(Set<String>())

    /// Deletes outputs whose writers are still running, for a forced exit that can't wait for them to unwind.
    static func discardInFlight() {
        for path in inFlight.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
    }
}

/// A value guarded by a lock, for state shared between parallel units of work.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
