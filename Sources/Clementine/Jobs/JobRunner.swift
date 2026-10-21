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

    func execute(_ action: Action, urls: [URL], params: ParamValues) {
        let units = action.batch ? [urls] : urls.map { [$0] }
        let job = RunningJob(title: action.mode == .convert ? "Convert to \(action.title)" : action.title,
                      symbol: action.symbol ?? "arrow.triangle.2.circlepath",
                      detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        let panel = ProgressPanel.show(job)

        job.task = Task {
            var files: [URL] = []
            var texts: [(String, String)] = []
            var failures: [String] = []

            for (index, unit) in units.enumerated() {
                if Task.isCancelled { break }
                if units.count > 1 { job.detail = "\(unit[0].lastPathComponent) (\(index + 1) of \(units.count))" }
                job.progress = units.count > 1 ? Double(index) / Double(units.count) : nil
                let context = JobContext(inputs: unit, params: params) { fraction in
                    let overall = (Double(index) + min(max(fraction, 0), 1)) / Double(units.count)
                    Task { @MainActor in if job.state == .running { job.progress = overall } }
                }
                do {
                    switch try await action.run(context) {
                    case .files(let outputs): files += outputs
                    case .text(let title, let body): texts.append((title, body))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failures.append(units.count > 1 ? "\(unit[0].lastPathComponent): \(error.localizedDescription)"
                                                    : error.localizedDescription)
                }
            }

            if Task.isCancelled {
                panel.close()
                return
            }
            if !files.isEmpty && Prefs.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
            for (title, body) in texts {
                ResultWindow.show(title: title, body: body)
            }
            if failures.isEmpty {
                job.progress = 1
                job.state = .done
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { panel.close() }
            } else {
                job.state = .failed(failures.joined(separator: "\n"))
            }
        }
    }
}
