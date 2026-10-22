import Foundation

/// Picks non-clobbering destinations next to the original file.
///
/// Inside a unit of work (`atomically`, which BatchRunner wraps around every action) the destinations handed out by
/// `file(beside:)`, `file(in:)` and `folder(beside:)` are hidden temporary names in the same folder; they get their
/// real names only once the work succeeds. So a crash or SIGKILL never leaves a half-written file under a real name.
enum Output {
    /// `photo.png` → `photo.jpg`, or `photo (compressed).jpg` with a suffix. Never overwrites.
    static func file(beside input: URL, name: String? = nil, suffix: String? = nil, ext: String) -> URL {
        var base = name ?? input.deletingPathExtension().lastPathComponent
        if let suffix { base += " (\(suffix))" }
        return staged(in: input.deletingLastPathComponent(), base: base, ext: ext)
    }

    /// A result destination in `dir` (staged like `file(beside:)`). Use `unique` for names inside an output folder.
    static func file(in dir: URL, base: String, ext: String) -> URL {
        staged(in: dir, base: base, ext: ext)
    }

    /// `file(in:)` for an existing item's name (keeps folder names with dots intact).
    static func file(in dir: URL, sameNameAs item: URL) -> URL {
        let (base, ext) = nameParts(of: item)
        return staged(in: dir, base: base, ext: ext)
    }

    /// Creates a fresh folder next to `input`.
    static func folder(beside input: URL, name: String) throws -> URL {
        let url = staged(in: input.deletingLastPathComponent(), base: name, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A unique destination in `dir` for an existing item's name (keeps folder names with dots intact).
    static func unique(in dir: URL, sameNameAs item: URL) -> URL {
        let (base, ext) = nameParts(of: item)
        return unique(in: dir, base: base, ext: ext)
    }

    private static func nameParts(of item: URL) -> (base: String, ext: String) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        if isDir.boolValue || item.pathExtension.isEmpty { return (item.lastPathComponent, "") }
        return (item.deletingPathExtension().lastPathComponent, item.pathExtension)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        // Compared case- and normalization-insensitively, as APFS and HFS+ do by default: otherwise `Clip.mov` and
        // `clip.ts` → MP4 get `Clip.mp4` and `clip.mp4`, which are the same file there. The listing catches names
        // that differ only by case on case-sensitive volumes too, so outputs stay distinct wherever they're copied.
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map(key))
        return reservations.withLock { reserved in
            var candidate = make(base)
            var n = 2
            while taken.contains(key(candidate.lastPathComponent)) || FileManager.default.fileExists(atPath: candidate.path)
                    || reserved[key(candidate.path)] != nil {
                candidate = make("\(base) \(n)")
                n += 1
            }
            if batches > 0 {
                // Once an output exists on disk the check above covers it; drop those so the set can't keep growing
                // while batches overlap.
                if reserved.count >= pruneThreshold {
                    reserved = reserved.filter { !FileManager.default.fileExists(atPath: $0.value) }
                }
                reserved[key(candidate.path)] = candidate.path
            }
            return candidate
        }
    }

    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    // MARK: Reservations

    /// Names handed out while files run in parallel, so `photo.png` and `photo.heic` → JPG can't both pick
    /// `photo.jpg` before either is written. Keyed by folded path. Cleared once no batch is running.
    private static let reservations = Locked([String: String]())
    nonisolated(unsafe) private static var batches = 0
    private static let pruneThreshold = 256

    static func beginBatch() {
        reservations.withLock { _ in batches += 1 }
    }

    static func endBatch() {
        reservations.withLock { reserved in
            batches -= 1
            if batches == 0 { reserved.removeAll() }
        }
    }

    /// Frees a name once its file is written (the file now guards it) or abandoned.
    private static func release(_ url: URL) {
        reservations.withLock { reserved in _ = reserved.removeValue(forKey: key(url.path)) }
    }

    /// Like `produce`, for an output folder that may not exist (single-file results need no cleanup here).
    static func filling<T>(_ folder: URL?, _ body: () async throws -> T) async throws -> T {
        guard let folder else { return try await body() }
        return try await produce(folder, body)
    }

    /// Runs `body`, deleting a half-written `url` if it throws.
    @discardableResult
    static func produce<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        inFlight.withLock { _ = $0.insert(url.path) }
        defer {
            inFlight.withLock { _ = $0.remove(url.path) }
            release(url)
        }
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
        for path in staging.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: Staging (write to a hidden name, rename when done)

    /// What one unit of work has staged so far.
    final class Scope: @unchecked Sendable {
        struct Pending {
            let temp: URL
            let final: URL
            let base: String
            let ext: String
        }
        fileprivate let pending = Locked([Pending]())
    }

    @TaskLocal static var scope: Scope?

    /// Temporary names start with this, then the owner's pid and a random token: `.clementine-123-1a2b3c4d-clip.mp4`.
    /// The real extension stays last so ffmpeg and ImageIO still pick the format from it.
    static let tempPrefix = ".clementine-"

    /// Every staged path not yet renamed or deleted, across units, for `discardInFlight`.
    private static let staging = Locked(Set<String>())

    private static func staged(in dir: URL, base: String, ext: String) -> URL {
        let final = unique(in: dir, base: base, ext: ext)
        guard let scope else { return final }
        let temp = dir.appendingPathComponent(tempName(for: final.lastPathComponent, ext: ext))
        // Journal first: if we crash right after the writer starts, the next launch knows where to look.
        OutputJournal.record(dir)
        staging.withLock { _ = $0.insert(temp.path) }
        scope.pending.withLock { $0.append(.init(temp: temp, final: final, base: base, ext: ext)) }
        return temp
    }

    private static func tempName(for name: String, ext: String) -> String {
        let token = UUID().uuidString.prefix(8).lowercased()
        let prefix = "\(tempPrefix)\(getpid())-\(token)-"
        let suffix = ext.isEmpty ? "" : "." + ext
        var stem = String(name.dropLast(suffix.count))
        // Names are limited to 255 bytes; the prefix mustn't push a long one over.
        while (prefix + stem + suffix).utf8.count > 255 && !stem.isEmpty { stem.removeLast() }
        return prefix + stem + suffix
    }

    /// Runs one unit of work with staged outputs. On success every staged item that exists is renamed to its
    /// final name (the next free one if something took it meanwhile) and the result's URLs are rewritten to match;
    /// on failure they're all deleted.
    static func atomically(_ body: () async throws -> JobOutput) async throws -> JobOutput {
        let scope = Scope()
        beginBatch() // keeps final names reserved until they exist on disk
        defer { endBatch() }
        let result: JobOutput
        do {
            result = try await $scope.withValue(scope) { try await body() }
        } catch {
            discard(scope)
            throw describing(error, in: scope)
        }
        var moves: [(temp: String, final: URL)] = []
        do {
            for item in scope.pending.withLock({ $0 }) {
                defer { staging.withLock { _ = $0.remove(item.temp.path) } }
                guard FileManager.default.fileExists(atPath: item.temp.path) else { release(item.final); continue }
                moves.append((item.temp.path, try commit(item)))
            }
        } catch {
            discard(scope)
            throw error
        }
        guard case .files(let urls) = result else { return result }
        return .files(urls.map { url in
            let path = url.path
            for move in moves {
                if path == move.temp { return move.final }
                if path.hasPrefix(move.temp + "/") { return URL(fileURLWithPath: move.final.path + path.dropFirst(move.temp.count)) }
            }
            return url
        })
    }

    /// Renames without ever replacing: RENAME_EXCL fails if the name exists (case-insensitively where the volume is).
    private static func commit(_ item: Scope.Pending) throws -> URL {
        var target = item.final
        let dir = item.final.deletingLastPathComponent()
        for _ in 0..<1000 {
            defer { release(target) }
            var code: Int32 = 0
            if renamex_np(item.temp.path, target.path, UInt32(RENAME_EXCL)) != 0 { code = errno }
            if code == ENOTSUP || code == EINVAL {
                // Volumes without exclusive rename (some network shares): check, then rename.
                code = FileManager.default.fileExists(atPath: target.path) ? EEXIST
                    : (rename(item.temp.path, target.path) == 0 ? 0 : errno)
            }
            if code == 0 { return target }
            guard code == EEXIST else {
                throw ClementineError.message("Couldn't save \(target.lastPathComponent): \(String(cString: strerror(code))).")
            }
            target = unique(in: dir, base: item.base, ext: item.ext)
        }
        throw ClementineError.message("Couldn't find a free name for \(item.final.lastPathComponent).")
    }

    private static func discard(_ scope: Scope) {
        for item in scope.pending.withLock({ $0 }) {
            try? FileManager.default.removeItem(at: item.temp)
            staging.withLock { _ = $0.remove(item.temp.path) }
            release(item.final)
        }
    }

    /// Error messages name the file being written; show the name it would have had, not the hidden one.
    private static func describing(_ error: Error, in scope: Scope) -> Error {
        guard !(error is CancellationError) else { return error }
        var text = error.localizedDescription
        for item in scope.pending.withLock({ $0 }) {
            text = text.replacingOccurrences(of: item.temp.lastPathComponent, with: item.final.lastPathComponent)
        }
        return text == error.localizedDescription ? error : ClementineError.message(text)
    }

    /// Deletes temporaries left by a Clementine process that died before renaming them (crash, SIGKILL, power
    /// loss). Only looks in folders recorded in the journal, never anywhere else.
    static func sweepStale() {
        OutputJournal.sweep { dir in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var kept = false
            for name in names where name.hasPrefix(tempPrefix) {
                guard let owner = owner(of: name) else { continue } // not ours after all
                let url = dir.appendingPathComponent(name)
                if isStale(url, owner: owner) {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    kept = true
                }
            }
            return kept
        }
    }

    /// The pid in `.clementine-<pid>-<8 hex>-…`, or nil if the name doesn't have that exact shape.
    static func owner(of name: String) -> pid_t? {
        let parts = name.dropFirst(tempPrefix.count).split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard name.hasPrefix(tempPrefix), parts.count == 3, let pid = pid_t(parts[0]), pid > 0,
              parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return pid
    }

    /// Its owner has exited, or (in case the pid was reused) it hasn't been touched for an hour.
    private static func isStale(_ url: URL, owner: pid_t) -> Bool {
        if owner == getpid() { return false }
        let alive = kill(owner, 0) == 0 || errno == EPERM
        if !alive { return true }
        return Date().timeIntervalSince(lastTouched(url)) > 3600
    }

    /// Newest modification date of the item or anything inside it (a folder's own date doesn't change as its
    /// files grow).
    private static func lastTouched(_ url: URL) -> Date {
        let fm = FileManager.default
        var newest = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let child as URL in walker {
                if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    newest = max(newest, date)
                }
            }
        }
        return newest
    }
}

/// Folders where outputs have been staged, so a later launch can find temporaries left by a crash without
/// scanning anything else. NUL-separated paths in `in-progress` under the support folder, guarded by flock
/// because the app and CLI runs may share it.
enum OutputJournal {
    static var file: URL { Prefs.supportDirectory.appendingPathComponent("in-progress") }

    /// Folders this process has already recorded.
    private static let recorded = Locked(Set<String>())

    static func record(_ dir: URL) {
        let path = dir.standardizedFileURL.path
        guard recorded.withLock({ $0.insert(path).inserted }) else { return }
        withLockedFile { fd in
            _ = (path + "\0").withCString { write(fd, $0, strlen($0) + 1) }
        }
    }

    /// Calls `keep` for each recorded folder that still exists; folders it returns false for are dropped.
    static func sweep(_ keep: (URL) -> Bool) {
        withLockedFile { fd in
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
            let paths = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
            var remaining: [String] = []
            for path in Set(paths).sorted() {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if keep(URL(fileURLWithPath: path, isDirectory: true)) { remaining.append(path) }
            }
            ftruncate(fd, 0)
            for path in remaining {
                _ = (path + "\0").withCString { write(fd, $0, strlen($0) + 1) }
            }
        }
    }

    private static func withLockedFile(_ body: (Int32) -> Void) {
        try? FileManager.default.createDirectory(at: Prefs.supportDirectory, withIntermediateDirectories: true)
        let fd = open(file.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        body(fd)
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
