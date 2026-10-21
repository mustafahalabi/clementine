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

        job.task = Task {
            job.progress = count > 1 ? 0 : nil
            let report = await BatchRunner.run(action, urls: urls, params: params) { overall, finished in
                Task { @MainActor in
                    guard job.state == .running else { return }
                    job.progress = max(job.progress ?? 0, overall)
                    if count > 1 { job.detail = "\(finished) of \(count) done" }
                }
            }

            if Task.isCancelled {
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
            if report.failures.isEmpty {
                job.progress = 1
                job.state = .done
                // Long enough to reach Undo; hovering the card keeps it open.
                panel.close(after: job.undo == nil ? 1.2 : 5)
            } else {
                job.state = .failed(report.failures.map(\.message).joined(separator: "\n"))
            }
        }
    }
}
