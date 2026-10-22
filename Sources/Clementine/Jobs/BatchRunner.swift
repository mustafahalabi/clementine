import Foundation

/// What a run produced, in the order the files were given (whatever order they finished in).
struct BatchReport {
    struct Failure {
        let unit: [URL]
        let message: String
    }

    var files: [URL] = []
    var texts: [(title: String, body: String)] = []
    var failures: [Failure] = []
    /// Per unit, in order.
    var outcomes: [(unit: [URL], result: Result<JobOutput, Error>)] = []
    var cancelled = false
}

/// Runs an action over its units of work (one per file, or one for batch actions), several at once.
/// Shared by the app's JobRunner and the CLI, so `--run` exercises the same path.
enum BatchRunner {
    /// CPU-bound image and document work gets half the cores; ffmpeg already uses several threads per file, so 2.
    static func limit(for action: Action, units: [[URL]]) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        if let fixed = action.maxConcurrent { return max(1, min(fixed, cores)) }
        let media = units.joined().contains { [.video, .audio].contains(FileItem(url: $0).kind) }
        return media ? min(2, cores) : cores
    }

    static func units(for action: Action, urls: [URL]) -> [[URL]] {
        action.batch ? [urls] : urls.map { [$0] }
    }

    /// `progress` gets the overall fraction (0…1) and how many units have finished. It may be called from any thread.
    static func run(_ action: Action, urls: [URL], params: ParamValues,
                    progress: @escaping @Sendable (_ overall: Double, _ finished: Int) -> Void = { _, _ in }) async -> BatchReport {
        let units = units(for: action, urls: urls)
        let limit = limit(for: action, units: units)
        let tally = Tally(units: units.count)
        var results = [Result<JobOutput, Error>?](repeating: nil, count: units.count)

        Output.beginBatch()
        defer { Output.endBatch() }
        // A long encode shouldn't stall because the Mac idled to sleep halfway through.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Clementine is converting files")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        await withTaskGroup(of: (Int, Result<JobOutput, Error>).self) { group in
            var next = 0
            func launch(_ group: inout TaskGroup<(Int, Result<JobOutput, Error>)>) {
                let index = next
                next += 1
                group.addTask {
                    if Task.isCancelled { return (index, .failure(CancellationError())) }
                    tally.started()
                    defer { tally.stopped() }
                    let context = JobContext(inputs: units[index], params: params) { fraction in
                        progress(tally.update(index, fraction), tally.finished)
                    }
                    do {
                        return (index, .success(try await action.run(context)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            while next < min(limit, units.count) { launch(&group) }
            while let (index, result) = await group.next() {
                results[index] = result
                progress(tally.complete(index), tally.finished)
                if next < units.count && !Task.isCancelled { launch(&group) }
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEMENTINE_TRACE_CONCURRENCY"] != nil {
            FileHandle.standardError.write("concurrency: \(tally.peak) of \(limit) for \(units.count) units\n".data(using: .utf8)!)
        }
        #endif

        var report = BatchReport()
        report.cancelled = Task.isCancelled
        for (unit, result) in zip(units, results) {
            let result = result ?? .failure(CancellationError()) // never started
            report.outcomes.append((unit, result))
            switch result {
            case .success(.files(let outputs)):
                report.files += outputs
            case .success(.text(let title, let body)):
                report.texts.append((title, body))
            case .failure(is CancellationError) where report.cancelled:
                break
            case .failure(let error):
                // A CancellationError nobody asked for (the batch wasn't cancelled) is a failure, not a quiet skip.
                let description = error is CancellationError ? "Stopped unexpectedly." : error.localizedDescription
                let message = units.count > 1 ? "\(unit[0].lastPathComponent): \(description)" : description
                report.failures.append(.init(unit: unit, message: message))
            }
        }
        return report
    }

    /// Per-unit progress and a running count, shared by the child tasks.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double]
        private var running = 0
        private var maxRunning = 0
        private var done = 0

        var peak: Int { lock.withLock { maxRunning } }
        var finished: Int { lock.withLock { done } }

        init(units: Int) { fractions = Array(repeating: 0, count: max(units, 1)) }

        func started() { lock.withLock { running += 1; maxRunning = max(maxRunning, running) } }
        func stopped() { lock.withLock { running -= 1 } }

        func update(_ index: Int, _ fraction: Double) -> Double {
            lock.withLock {
                fractions[index] = max(fractions[index], min(max(fraction, 0), 1))
                return fractions.reduce(0, +) / Double(fractions.count)
            }
        }

        func complete(_ index: Int) -> Double {
            lock.withLock {
                fractions[index] = 1
                done += 1
                return fractions.reduce(0, +) / Double(fractions.count)
            }
        }
    }
}
