#if DEBUG
import AppKit

extension UITest {
    /// Quitting while a job runs: the app path of `Shutdown.stop` (the CLI's is covered by scripts/test-lifecycle.sh).
    /// Must run last: `ProcessRunner.stopAll` refuses new tools for the rest of the process, as it should on quit.
    static var lifecycle: [Suite] {
        [Suite(name: "lifecycle quit") { t in
            guard ToolLocator.find("ffmpeg") != nil, let action = ActionRegistry.find("convert.media.webm") else {
                t.skip("ffmpeg not installed")
                return
            }
            let folder = t.scratch.appendingPathComponent("quit", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let video = folder.appendingPathComponent("long.mp4")
            t.shell("ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 30 -c:v libx264 -preset ultrafast '\(video.path)'")
            let listing = { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? [] }
            let before = listing()
            // Written under a hidden temporary name until it's complete (see Output.atomically).
            let staged = { listing().contains { $0.hasPrefix(Output.tempPrefix) && $0.hasSuffix("-long.webm") } }

            let delegate = AppDelegate()
            t.check(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "quits at once when nothing runs")

            JobRunner.shared.execute(action, urls: [video], params: action.defaults)
            t.check(t.wait(15) { ProcessRunner.runningCount > 0 && staged() },
                    "the encode is writing its output (under a hidden name)")
            t.check(JobRunner.shared.running.count == 1, "the job is listed as running")

            // What applicationShouldTerminate does after returning .terminateLater (minus the reply, which would quit).
            var stopped = false
            Task { @MainActor in
                await JobRunner.shared.stopAll()
                stopped = true
            }
            t.check(t.wait(15) { stopped }, "stopAll returns")
            t.check(ProcessRunner.runningCount == 0, "no tool left running")
            t.check(JobRunner.shared.running.isEmpty, "no job left running")
            t.check(listing() == before, "no output or partial file left (\(listing()))")
            t.settle(0.5) // let the card slide out
        }]
    }
}
#endif
