import Foundation

enum ClementineError: LocalizedError {
    case missingTool(String)
    case toolFailed(String, String)
    case unreadable(URL)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return Self.missingToolMessage(name, bundled: Self.bundlesTools)
        case .toolFailed(let name, let stderr):
            let lines = Self.meaningfulLines(stderr)
            // The first line is usually the cause (e.g. "width not divisible by 2"); the last ones the outcome.
            let shown = lines.count <= 3 ? lines : [lines[0]] + lines.suffix(2)
            // Lead with a plain sentence; keep the tool's own words below it for anyone who needs them.
            let lead = Self.plainCause(of: lines) ?? "\(name) couldn't finish with this file."
            return shown.isEmpty ? lead : "\(lead)\n\(name) said: \(shown.joined(separator: "\n"))"
        case .unreadable(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .message(let message):
            return message
        }
    }

    /// Release builds carry ffmpeg, ffprobe, cwebp and img2webp in Resources/bin; development builds rely on Homebrew.
    static var bundlesTools: Bool {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin") else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        return !contents.isEmpty
    }

    /// The Homebrew formula that provides `tool`.
    static func formula(for tool: String) -> String {
        ["cwebp", "img2webp", "dwebp", "webpmux"].contains(tool) ? "webp" : "ffmpeg"
    }

    static func missingToolMessage(_ name: String, bundled: Bool) -> String {
        if bundled {
            // A brew hint would be wrong here: the app is meant to bring its own copy.
            return "Clementine's built-in \(name) is missing. Reinstall Clementine, or choose a folder that contains \(name) in Settings."
        }
        return "\(name) isn't installed. Install it with `brew install \(formula(for: name))` or set its folder in Settings."
    }

    /// A one-sentence explanation for the failures people actually hit, or nil to fall back to a generic one.
    static func plainCause(of lines: [String]) -> String? {
        let text = lines.joined(separator: "\n").lowercased()
        let causes: [([String], String)] = [
            (["no space left"], "The disk is full."),
            (["permission denied", "operation not permitted"], "Clementine wasn't allowed to read or write a file here."),
            (["invalid data found", "moov atom not found", "could not find codec parameters"],
             "The file looks damaged, or isn't in a format that can be read."),
            (["does not contain any stream", "matches no streams", "output file is empty"],
             "The file doesn't have the kind of track this needs."),
            (["not divisible by 2"], "This format needs an even width and height."),
            (["unknown encoder", "encoder not found", "unsupported codec"], "This format can't be written by the bundled tools."),
            (["stopped unexpectedly"], "The tool stopped unexpectedly before it finished."),
            (["no such file"], "A file couldn't be found. It may have been moved or renamed."),
        ]
        return causes.first { needles, _ in needles.contains(where: text.contains) }?.1
    }

    /// ffmpeg's stderr is noisy: drop `[enc:x @ 0x…]` prefixes, thread bookkeeping and duplicate lines.
    private static func meaningfulLines(_ stderr: String) -> [String] {
        var seen = Set<String>()
        return stderr.split(separator: "\n").compactMap { raw -> String? in
            let line = raw.replacingOccurrences(of: #"^(\[[^\]]*\]\s*)+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let noise = ["Task finished with error", "Terminating thread", "Error opening output files", "Error opening input files", "Conversion failed"]
            guard !line.isEmpty, !noise.contains(where: line.hasPrefix), seen.insert(line).inserted else { return nil }
            return line
        }
    }
}
