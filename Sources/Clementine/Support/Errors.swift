import Foundation

enum ClementineError: LocalizedError {
    case missingTool(String)
    case toolFailed(String, String)
    case unreadable(URL)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            let formula = name == "cwebp" ? "webp" : "ffmpeg"
            return "\(name) isn't installed. Install it with `brew install \(formula)` or set its folder in Settings."
        case .toolFailed(let name, let stderr):
            let lines = Self.meaningfulLines(stderr)
            // The first line is usually the cause (e.g. "width not divisible by 2"); the last ones the outcome.
            let shown = lines.count <= 3 ? lines : [lines[0]] + lines.suffix(2)
            return "\(name) failed: \(shown.isEmpty ? "unknown error" : shown.joined(separator: "\n"))"
        case .unreadable(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .message(let message):
            return message
        }
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
