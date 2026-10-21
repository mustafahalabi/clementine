import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs an executable to completion. The process is terminated if the calling task is cancelled.
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
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if Task.isCancelled { process.terminate() }

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
                    try? outFile?.close()
                    let result = ProcessResult(
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    )
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: result)
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: ClementineError.toolFailed(executable.lastPathComponent, result.stderr))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
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
