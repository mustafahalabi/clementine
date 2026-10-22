import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs an executable to completion. The process is terminated if the calling task is cancelled.
    /// Throws `CancellationError` only when the stop was asked for (task cancelled or `stopAll`); a tool that dies
    /// from a signal on its own (a crash, an outside `kill`) is a `toolFailed`, whatever its exit status.
    /// - Parameters:
    ///   - stdoutFile: write stdout to this file instead of capturing it (for binary output).
    ///   - onLine: called on a background thread for each stdout line as it arrives.
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        onLine: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let child = Child(process)

        let outPipe = Pipe()
        let errPipe = Pipe()
        var outFile: FileHandle?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            outFile = try FileHandle(forWritingTo: stdoutFile)
            process.standardOutput = outFile
        } else {
            process.standardOutput = outPipe
        }
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Finished when both pipes hit EOF and the process has exited. (`waitUntilExit` can hang off the main thread.)
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                process.terminationHandler = { _ in group.leave() }
                do {
                    // If the task was cancelled before launch, onCancel already ran and found nothing to stop.
                    try Task.checkCancellation()
                    try register(child)
                } catch {
                    try? outFile?.close()
                    continuation.resume(throwing: error)
                    return
                }
                if Task.isCancelled { child.stop() }

                if stdoutFile == nil {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var pending = Data()
                        while true {
                            let chunk = outPipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            outData.append(chunk)
                            guard let onLine else { continue }
                            pending.append(chunk)
                            while let newline = pending.firstIndex(of: 0x0A) {
                                onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                                pending = Data(pending[pending.index(after: newline)...])
                            }
                        }
                        group.leave()
                    }
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.notify(queue: .global(qos: .userInitiated)) {
                    unregister(child)
                    try? outFile?.close()
                    let result = ProcessResult(
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    )
                    let name = executable.lastPathComponent
                    if child.stopRequested {
                        // Whatever it exited with: ffmpeg answers SIGTERM with status 255, others die of the signal.
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationReason == .uncaughtSignal {
                        let signal = process.terminationStatus
                        let cause = String(cString: strsignal(signal))
                        continuation.resume(throwing: ClementineError.toolFailed(name, result.stderr + "\n\(name) stopped unexpectedly (\(cause))"))
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: ClementineError.toolFailed(name, result.stderr))
                    }
                }
            }
        } onCancel: {
            child.stop()
        }
    }

    // MARK: Running children

    /// One launched tool, and whether we asked it to stop (so its exit reads as a cancellation, not a failure).
    final class Child: @unchecked Sendable {
        let process: Process
        private let requested = Locked(false)

        init(_ process: Process) { self.process = process }

        var stopRequested: Bool { requested.withLock { $0 } }

        /// SIGTERM, so ffmpeg can close its files; `stopAll` follows up with SIGKILL.
        func stop() {
            requested.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }

        func kill() {
            requested.withLock { $0 = true }
            guard process.isRunning else { return }
            // The child leads its own process group; take anything it spawned with it.
            let pid = process.processIdentifier
            Darwin.kill(-pid, SIGKILL)
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// Tools run in their own process group and ffmpeg ignores SIGPIPE, so a child outlives an app that quits or a
    /// CLI that's interrupted unless it is stopped explicitly. Every launched child is listed here until it exits.
    private static let children = Locked((running: [ObjectIdentifier: Child](), closed: false))

    /// Launches `child`, or refuses once `stopAll` has run (a job starting during shutdown must not leave a tool behind).
    private static func register(_ child: Child) throws {
        try children.withLock { state in
            if state.closed { throw CancellationError() }
            try child.process.run()
            state.running[ObjectIdentifier(child)] = child
        }
    }

    private static func unregister(_ child: Child) {
        children.withLock { _ = $0.running.removeValue(forKey: ObjectIdentifier(child)) }
    }

    static var runningCount: Int { children.withLock { $0.running.count } }

    /// Stops every running tool and refuses new ones: SIGTERM now, SIGKILL for any still running after `grace`.
    /// Returns once they have all exited (or right after the SIGKILL).
    static func stopAll(grace: TimeInterval = 3) async {
        let running = children.withLock { state -> [Child] in
            state.closed = true
            return Array(state.running.values)
        }
        running.forEach { $0.stop() }
        let deadline = Date().addingTimeInterval(grace)
        while runningCount > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        killAll()
    }

    /// SIGKILL for everything still running; for a forced exit that can't wait.
    static func killAll() {
        let running = children.withLock { state -> [Child] in
            state.closed = true
            return Array(state.running.values)
        }
        running.forEach { $0.kill() }
    }
}

/// Finds command-line tools: bundled `Contents/Resources/bin` first, then the Settings folder, then Homebrew.
enum ToolLocator {
    static func find(_ name: String) -> URL? {
        var dirs: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path { dirs.append(bundled) }
        if let custom = Prefs.toolsDirectory, !custom.isEmpty { dirs.append((custom as NSString).expandingTildeInPath) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func require(_ name: String) throws -> URL {
        guard let url = find(name) else { throw ClementineError.missingTool(name) }
        return url
    }
}
