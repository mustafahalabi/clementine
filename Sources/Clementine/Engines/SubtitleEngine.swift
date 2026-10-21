import Foundation

/// SRT ⇄ WebVTT.
enum SubtitleEngine {
    static func convert(_ input: URL, to ext: String) throws -> URL {
        let data = try Data(contentsOf: input)
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let converted = ext == "vtt" ? toVTT(text) : toSRT(text)
        let output = Output.file(beside: input, ext: ext)
        try converted.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    static func toVTT(_ srt: String) -> String {
        let body = srt.components(separatedBy: "\n").map { line in
            line.contains("-->") ? line.replacingOccurrences(of: ",", with: ".") : line
        }
        return (["WEBVTT", ""] + body).joined(separator: "\n")
    }

    static func toSRT(_ vtt: String) -> String {
        var cues: [String] = []
        for block in blocks(vtt) {
            guard let timing = block.firstIndex(where: { $0.contains("-->") }) else { continue } // header, NOTE, STYLE
            let ends = block[timing].components(separatedBy: "-->")
            let start = srtTime(ends[0])
            let end = srtTime(ends[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            let text = block[(timing + 1)...].map(stripVoiceTags).joined(separator: "\n")
            cues.append("\(cues.count + 1)\n\(start) --> \(end)\n\(text)")
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    private static func blocks(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// `01:02.5` or `00:01:02.500` → `00:01:02,500`.
    private static func srtTime(_ raw: String) -> String {
        var parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        while parts.count < 3 { parts.insert("00", at: 0) }
        let secondsParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        let seconds = String(secondsParts[0])
        var millis = secondsParts.count > 1 ? String(secondsParts[1]) : "000"
        millis = String((millis + "000").prefix(3))
        func pad(_ s: String) -> String { s.count >= 2 ? s : String(repeating: "0", count: 2 - s.count) + s }
        return "\(pad(parts[0])):\(pad(parts[1])):\(pad(seconds)),\(millis)"
    }

    /// Keeps <b>, <i>, <u> (SRT understands them) and drops VTT-only tags like <v Name> or <c.red>.
    private static func stripVoiceTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<(?!/?[biu]>)[^>]*>"#, with: "", options: .regularExpression)
    }
}
