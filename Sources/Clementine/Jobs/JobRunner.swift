import AppKit

@MainActor
final class RunningJob: ObservableObject {
    enum State: Equatable {
        case running
        case done
        case failed(String)
    }

    let title: String
    let symbol: String
    @Published var detail: String
    /// nil shows an indeterminate bar.
    @Published var progress: Double?
    @Published var state: State = .running
    /// Set once a finished job's files are in history: moves them to the Trash.
    @Published var undo: (() -> Void)?
    @Published var undone = false
    var task: Task<Void, Never>?

    init(title: String, symbol: String, detail: String) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }
}

@MainActor
final class JobRunner {
    static let shared = JobRunner()

    /// Jobs whose batch is still running, so quitting can stop them first.
    private(set) var running: [RunningJob] = []

    func start(_ action: Action, urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let editor = action.editor {
            editor(urls, action.defaults) { [weak self] values in
                self?.execute(action, urls: urls, params: values)
            }
        } else if action.parameters.isEmpty {
            execute(action, urls: urls, params: action.defaults)
        } else {
            ParameterWindow.present(action: action, urls: urls) { [weak self] values in
                self?.execute(action, urls: urls, params: values)
            }
        }
    }

    static func title(for action: Action) -> String {
        action.mode == .convert ? "Convert to \(action.title)" : action.title
    }

    func execute(_ action: Action, urls: [URL], params: ParamValues) {
        let count = BatchRunner.units(for: action, urls: urls).count
        let job = RunningJob(title: Self.title(for: action),
                      symbol: action.symbol ?? "arrow.triangle.2.circlepath",
                      detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        let panel = ProgressPanel.show(job)
        ActionUsage.record(action, urls: urls)

        running.append(job)
        job.task = Task {
            job.progress = count > 1 ? 0 : nil
            let report = await BatchRunner.run(action, urls: urls, params: params) { overall, finished in
                Task { @MainActor in
                    guard job.state == .running else { return }
                    job.progress = max(job.progress ?? 0, overall)
                    if count > 1 { job.detail = "\(finished) of \(count) done" }
                }
            }
            running.removeAll { $0 === job }

            if Task.isCancelled {
                // Files that finished before the cancel are complete; keep them findable and undoable.
                if !report.files.isEmpty { HistoryStore.shared.record(action, inputs: urls, outputs: report.files) }
                panel.close()
                return
            }
            if !report.files.isEmpty && Prefs.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(report.files)
            }
            for (title, body) in report.texts {
                ResultWindow.show(title: title, body: body)
            }
            if !report.files.isEmpty {
                let entry = HistoryStore.shared.record(action, inputs: urls, outputs: report.files)
                job.undo = { [weak job] in
                    guard let job, !job.undone else { return }
                    guard HistoryStore.shared.entries.contains(where: { $0.id == entry.id }) else {
                        job.undo = nil // already undone from the menu bar
                        return
                    }
                    do {
                        let trashed = try HistoryStore.shared.undo(entry)
                        job.undone = true
                        job.detail = trashed.count == 1 ? "Moved to the Trash" : "Moved \(trashed.count) items to the Trash"
                        panel.close(after: 1.4)
                    } catch {
                        job.state = .failed("Couldn't move the files to the Trash: \(error.localizedDescription)")
                    }
                }
            }
            let note = Self.note(for: report, units: count)
            if let note { job.detail = note }
            if report.failures.isEmpty {
                job.progress = 1
                job.state = .done
                // Long enough to reach Undo (or read why nothing was written); hovering the card keeps it open.
                panel.close(after: job.undo != nil ? 5 : note != nil ? 4 : 1.2)
            } else {
                job.state = .failed(report.failures.map(\.message).joined(separator: "\n"))
            }
        }
    }

    /// What the card says when some units deliberately wrote nothing (Compress keeping a smaller original).
    static func note(for report: BatchReport, units: Int) -> String? {
        guard let first = report.notes.first else { return nil }
        if units == 1 { return first.message }
        let kept = report.notes.count
        if kept == units { return "All \(kept) were already as small as they get — originals kept." }
        return kept == 1 ? "1 was already as small as it gets — original kept."
                         : "\(kept) were already as small as they get — originals kept."
    }

    /// Cancels every running job and waits (bounded) for its tools to stop and partial outputs to be deleted.
    func stopAll() async {
        let jobs = running
        await Shutdown.stop(cancel: { jobs.forEach { $0.task?.cancel() } },
                            waitingFor: { for job in jobs { await job.task?.value } })
    }
}

/// Stopping work for good: the app quitting, or the CLI getting SIGINT/SIGTERM.
enum Shutdown {
    /// How long writers get to unwind (and delete their partial outputs) before we force the issue.
    static let deadline: TimeInterval = 10

    /// Cancels the work, stops every tool (SIGTERM, then SIGKILL after a grace period) and waits for the work to
    /// finish, up to `deadline`. Past that, kills what's left and deletes outputs still being written.
    static func stop(cancel: () -> Void, waitingFor work: @escaping @Sendable () async -> Void) async {
        cancel()
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Locked(false)
            let finish: @Sendable (Bool) -> Void = { value in
                if once.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: value) }
            }
            Task.detached {
                await ProcessRunner.stopAll()
                await work()
                finish(true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { finish(false) }
        }
        if !finished {
            ProcessRunner.killAll()
            Output.discardInFlight()
        }
    }
}

