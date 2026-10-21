import Foundation

enum TimeCode {
    /// Parses `90`, `1:30`, `0:01:30.5` into seconds.
    static func seconds(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var total = 0.0
        for part in trimmed.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Parses `0:05-0:06, 1:10-1:12` into second ranges.
    static func ranges(_ string: String) -> [ClosedRange<Double>]? {
        var result: [ClosedRange<Double>] = []
        for chunk in string.split(separator: ",") {
            let ends = chunk.split(separator: "-")
            guard ends.count == 2, let a = seconds(String(ends[0])), let b = seconds(String(ends[1])), b > a else {
                return nil
            }
            result.append(a...b)
        }
        return result.isEmpty ? nil : result
    }

    static func ffmpeg(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}

extension Double {
    var megabytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
