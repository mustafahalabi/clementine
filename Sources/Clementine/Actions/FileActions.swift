import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// The ⌃ wheel: things to do with the file itself rather than its contents. Nothing here writes a file; results
/// are `.value` (copied to the clipboard by the app, printed by the CLI) or `.done` (something happened elsewhere).
/// Every action takes the whole selection at once so several files give one clipboard entry, one line each.
enum FileActions {
    /// Bigger files make data URIs nobody wants on the clipboard.
    static let dataURILimit = 5_000_000

    static let all: [Action] = [
        Action(id: "file.path", title: "Copy Path", symbol: "doc.on.clipboard", mode: .files, batch: true,
               accepts: { _ in true },
               run: { ctx in .value(ctx.inputs.map(\.path).joined(separator: "\n")) }),
        Action(id: "file.name", title: "Copy Name", symbol: "character.cursor.ibeam", mode: .files, batch: true,
               accepts: { _ in true },
               run: { ctx in .value(ctx.inputs.map(\.lastPathComponent).joined(separator: "\n")) }),
        Action(id: "file.sha256", title: "SHA-256", symbol: "number", mode: .files, batch: true,
               accepts: { $0.kind != .folder },
               run: { ctx in .value(try sha256Lines(ctx.inputs, progress: ctx.progress)) }),
        Action(id: "file.datauri", title: "Data URI", symbol: "chevron.left.forwardslash.chevron.right", mode: .files,
               batch: true,
               accepts: { $0.kind != .folder && (size(of: $0.url) ?? 0) <= dataURILimit },
               run: { ctx in .value(try ctx.inputs.map(dataURI).joined(separator: "\n")) }),
        Action(id: "file.terminal", title: "Open in Terminal", symbol: "terminal", mode: .files, batch: true,
               accepts: { _ in true },
               run: { ctx in
                   let folders = terminalFolders(for: ctx.inputs)
                   try await FileEffects.openInTerminal(folders)
                   return .done("Opened in Terminal: \(folders.map(\.path).joined(separator: ", "))")
               }),
        Action(id: "file.reveal", title: "Reveal in Finder", symbol: "folder", mode: .files, batch: true,
               accepts: { _ in true },
               run: { ctx in
                   await FileEffects.reveal(ctx.inputs)
                   return .done(ctx.inputs.count == 1 ? "Shown in Finder" : "Shown \(ctx.inputs.count) items in Finder")
               }),
        Action(id: "file.airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", mode: .files, batch: true,
               accepts: { _ in true },
               run: { ctx in
                   switch try await FileEffects.airDrop(ctx.inputs) {
                   case .closed: return .done("AirDrop closed")
                   case .cancelled: return .done("AirDrop cancelled")
                   }
               }),
    ]

    // MARK: Engines

    static func size(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// One file: just the hash. Several: `shasum`-style lines ("hash  name"), so the clipboard says which is which.
    static func sha256Lines(_ urls: [URL], progress: (Double) -> Void) throws -> String {
        let total = max(1, urls.reduce(0) { $0 + (size(of: $1) ?? 0) })
        var done = 0
        var hashes: [String] = []
        for url in urls {
            let before = done
            hashes.append(try sha256(url) { bytes in progress(Double(before + bytes) / Double(total)) })
            done += size(of: url) ?? 0
        }
        guard urls.count > 1 else { return hashes[0] }
        return zip(hashes, urls).map { "\($0)  \($1.lastPathComponent)" }.joined(separator: "\n")
    }

    /// Streams the file in 1 MB reads so big videos don't land in memory.
    static func sha256(_ url: URL, progress: (Int) -> Void = { _ in }) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClementineError.unreadable(url) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            read += chunk.count
            progress(read)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func dataURI(_ url: URL) throws -> String {
        guard let bytes = size(of: url) else { throw ClementineError.unreadable(url) }
        guard bytes <= dataURILimit else {
            throw ClementineError.message("\(url.lastPathComponent) is \(Double(bytes).megabytes); data URIs are for files up to \(Double(dataURILimit).megabytes).")
        }
        guard let data = try? Data(contentsOf: url) else { throw ClementineError.unreadable(url) }
        let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// The folder each item is in, or the item itself when it's a folder; each folder once, in order.
    static func terminalFolders(for urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let folder = FileItem(url: url).kind == .folder ? url : url.deletingLastPathComponent()
            return seen.insert(folder.standardizedFileURL.path).inserted ? folder : nil
        }
    }
}

/// What the file actions do outside Clementine. Debug builds with `CLEMENTINE_FAKE_EFFECTS` set only describe
/// it on stderr, so tests never open Terminal windows or AirDrop sheets.
enum FileEffects {
    static var simulated: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLEMENTINE_FAKE_EFFECTS"] != nil
        #else
        return false
        #endif
    }

    private static func simulate(_ what: String, _ urls: [URL]) {
        FileHandle.standardError.write("effect: \(what) \(urls.map(\.path).joined(separator: " | "))\n".data(using: .utf8)!)
    }

    /// Terminal opens a new window in each folder (Terminal.app; other terminals have no common way to ask).
    @MainActor
    static func openInTerminal(_ folders: [URL]) async throws {
        if simulated { return simulate("terminal", folders) }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ClementineError.message("Terminal isn't installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration)
    }

    @MainActor
    static func reveal(_ urls: [URL]) {
        if simulated { return simulate("reveal", urls) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// How the AirDrop picker ended. There's deliberately no "sent": macOS 26 reports `didShareItems` when the
    /// picker's Cancel is pressed too, so a finished share doesn't prove anything was delivered.
    enum AirDropEnd: Equatable {
        /// The picker closed: maybe after sending, maybe not.
        case closed
        /// macOS said the user cancelled (older systems, or Clementine's Stop button).
        case cancelled
    }

    /// Shows the AirDrop picker and waits for it to close.
    @MainActor
    static func airDrop(_ urls: [URL]) async throws -> AirDropEnd {
        if simulated {
            simulate("airdrop", urls)
            return .closed
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            throw ClementineError.message("AirDrop isn't available. Check that Wi-Fi and Bluetooth are on.")
        }
        // The CLI runs with no UI at all; the picker is a window, so it needs at least an accessory app.
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate()
        return try await AirDropSession(service: service).send(urls)
    }
}

/// Keeps the sharing service's delegate alive until AirDrop reports back.
@MainActor
private final class AirDropSession: NSObject, NSSharingServiceDelegate {
    private static var active: [AirDropSession] = []
    private let service: NSSharingService
    private var continuation: CheckedContinuation<FileEffects.AirDropEnd, Error>?

    init(service: NSSharingService) {
        self.service = service
    }

    func send(_ urls: [URL]) async throws -> FileEffects.AirDropEnd {
        Self.active.append(self)
        defer { Self.active.removeAll { $0 === self } }
        service.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                service.perform(withItems: urls)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.success(.cancelled)) }
        }
    }

    private func finish(_ result: Result<FileEffects.AirDropEnd, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finish(.success(.closed)) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated {
            let cancelled = (error as NSError).code == NSUserCancelledError
            finish(cancelled ? .success(.cancelled) : .failure(ClementineError.message("AirDrop didn't send: \(error.localizedDescription)")))
        }
    }
}
