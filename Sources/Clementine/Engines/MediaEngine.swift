import Foundation

/// Video and audio work, all through ffmpeg.
enum MediaEngine {
    typealias Progress = (Double) -> Void

    static func convert(_ input: URL, to ext: String, progress: @escaping Progress) async throws -> URL {
        let info = try await FFmpeg.readable(input)
        if ConvertActions.audioTargets.contains(ext), info.probed, !info.hasAudio {
            throw ClementineError.message("\(input.lastPathComponent) has no audio track.")
        }
        let output = Output.file(beside: input, ext: ext)
        return try await FFmpeg.transcode(input, to: output, args: FFmpeg.encodeArgs(ext, streams: info), duration: info.duration,
                                          progress: progress)
    }

    // MARK: Size

    static func compress(_ input: URL, level: Int, progress: @escaping Progress) async throws -> URL {
        let info = try await FFmpeg.readable(input)
        if info.hasVideo {
            let crf = ["23", "28", "32"][level]
            let maxEdge = [0, 1920, 1280][level]
            var args = FFmpeg.streamMaps("mp4", info)
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", ["160k", "128k", "96k"][level], "-movflags", "+faststart"]
            args += ["-vf", maxEdge > 0 ? FFmpeg.fitFilter(maxEdge: maxEdge) : FFmpeg.evenSize]
            let output = Output.file(beside: input, suffix: "compressed", ext: "mp4")
            return try await FFmpeg.transcode(input, to: output, args: args, duration: info.duration, progress: progress)
        }
        let bitrate = ["192k", "128k", "64k"][level]
        let isMP3 = input.pathExtension.lowercased() == "mp3"
        let ext = isMP3 ? "mp3" : "m4a"
        let args = ["-vn", "-c:a", isMP3 ? "libmp3lame" : "aac", "-b:a", bitrate]
        let output = Output.file(beside: input, suffix: "compressed", ext: ext)
        return try await FFmpeg.transcode(input, to: output, args: args, duration: info.duration, progress: progress)
    }

    static func fit(_ input: URL, bytes: Double, progress: @escaping Progress) async throws -> URL {
        let info = await FFmpeg.probe(input)
        guard let duration = info.duration, duration > 0 else {
            throw ClementineError.message("Couldn't read the length of \(input.lastPathComponent).")
        }
        _ = try await FFmpeg.readable(input)
        let label = bytes.megabytes
        // Already fits: re-encoding at a higher bitrate would only grow the file (and MP3 would change the format), so copy as-is.
        if let size = (try? input.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Double(size) <= bytes {
            let output = Output.file(beside: input, suffix: label, ext: input.pathExtension.lowercased())
            return try await FFmpeg.transcode(input, to: output, args: ["-map", "0", "-c", "copy", "-ignore_unknown"],
                                              duration: duration, progress: progress)
        }
        let totalKbps = bytes * 8 / 1000 / duration * 0.96

        guard info.hasVideo else {
            // MP3 only has fixed bitrates; take the highest that fits, leaving room for container overhead.
            let budget = Int(totalKbps * 0.95)
            guard let kbps = [320, 256, 224, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32].first(where: { $0 <= budget }) else {
                throw tooSmall(label, input)
            }
            let output = Output.file(beside: input, suffix: label, ext: "mp3")
            return try await FFmpeg.transcode(input, to: output, args: ["-vn", "-c:a", "libmp3lame", "-b:a", "\(kbps)k"],
                                              duration: duration, progress: progress)
        }

        let audioKbps = info.hasAudio ? (totalKbps > 800 ? 128 : 64) : 0
        let videoKbps = Int(totalKbps) - audioKbps
        guard videoKbps >= 60 else { throw tooSmall(label, input) }
        // Lower bitrates look better at lower resolutions.
        let maxEdge = videoKbps >= 4000 ? 0 : videoKbps >= 1500 ? 1920 : videoKbps >= 700 ? 1280 : 854
        let scale = maxEdge > 0 ? FFmpeg.fitFilter(maxEdge: maxEdge) : FFmpeg.evenSize

        let passDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: passDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: passDir) }
        let log = passDir.appendingPathComponent("pass").path
        let video = ["-vf", scale, "-c:v", "libx264", "-preset", "medium", "-b:v", "\(videoKbps)k", "-pix_fmt", "yuv420p", "-passlogfile", log]

        try await FFmpeg.run(["-i", input.path] + video + ["-pass", "1", "-an", "-f", "null", "/dev/null"],
                             duration: duration) { progress($0 * 0.5) }
        let output = Output.file(beside: input, suffix: label, ext: "mp4")
        let audio = info.hasAudio ? ["-c:a", "aac", "-b:a", "\(audioKbps)k"] : ["-an"]
        try await Output.produce(output) {
            try await FFmpeg.run(["-i", input.path] + video + ["-pass", "2"] + audio + ["-movflags", "+faststart", output.path],
                                 duration: duration) { progress(0.5 + $0 * 0.5) }
        }
        return output
    }

    private static func tooSmall(_ label: String, _ input: URL) -> ClementineError {
        .message("\(label) is too small for \(input.lastPathComponent). Try a larger target size.")
    }

    // MARK: Editing

    static func trim(_ input: URL, start: String, end: String, progress: @escaping Progress) async throws -> URL {
        func parse(_ text: String) throws -> Double? {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let seconds = TimeCode.seconds(text) else {
                throw ClementineError.message("Couldn't read the time “\(text)”. Use 1:30 or 90.")
            }
            return seconds
        }
        let from = try parse(start) ?? 0
        var to = try parse(end)
        let info = try await FFmpeg.readable(input)
        let total = info.duration
        if let total {
            guard from < total else {
                throw ClementineError.message("The start time is after the end of \(input.lastPathComponent).")
            }
            if let end = to, end > total { to = nil }
        }
        if let to, to <= from { throw ClementineError.message("The end time must be after the start time.") }
        var inputArgs = ["-ss", TimeCode.ffmpeg(from)]
        if let to { inputArgs += ["-to", TimeCode.ffmpeg(to)] }
        let duration = to.map { $0 - from } ?? total.map { $0 - from }
        let ext = input.pathExtension.lowercased()
        let output = Output.file(beside: input, suffix: "trimmed", ext: ext)
        return try await FFmpeg.transcode(input, to: output, inputArgs: inputArgs, args: FFmpeg.encodeArgs(ext, streams: info),
                                          duration: duration, progress: progress)
    }

    static func changeSpeed(_ input: URL, speed: Double, progress: @escaping Progress) async throws -> URL {
        let info = try await FFmpeg.readable(input)
        let ext = input.pathExtension.lowercased()
        let vf = info.hasVideo ? ["setpts=PTS/\(speed)"] : []
        let af = info.hasAudio ? FFmpeg.atempo(speed) : []
        let output = Output.file(beside: input, suffix: "\(formatSpeed(speed))×", ext: ext)
        return try await FFmpeg.transcode(input, to: output, args: FFmpeg.encodeArgs(ext, vf: vf, af: af),
                                          duration: info.duration.map { $0 / speed }, progress: progress)
    }

    static func split(_ input: URL, every seconds: Double, progress: @escaping Progress) async throws -> URL {
        guard seconds >= 1 else { throw ClementineError.message("Parts must be at least 1 second long.") }
        let base = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.lowercased()
        let duration = try await FFmpeg.readable(input).duration
        let folder = try Output.folder(beside: input, name: "\(base) parts")
        let pattern = folder.appendingPathComponent("\(base) part %03d.\(ext)").path
        do {
            try await FFmpeg.run(["-i", input.path, "-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-dn", "-ignore_unknown", "-c", "copy", "-f", "segment",
                                  "-segment_time", String(seconds), "-reset_timestamps", "1", pattern],
                                 duration: duration, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    static func snapshots(_ input: URL, mode: Int, progress: @escaping Progress) async throws -> [URL] {
        let info = try await FFmpeg.readable(input, needsVideo: true)
        let duration = info.duration ?? 0
        let base = input.deletingPathExtension().lastPathComponent
        // Seeking past the last frame silently writes nothing, so stay at least one frame before the end.
        let last = max(duration - 1 / (info.frameRate ?? 25), 0)
        let times: [Double]
        switch mode {
        case 0: times = [min(duration / 2, last)]
        case 1: times = [0]
        default: times = (0..<10).map { min(duration * (Double($0) + 0.5) / 10, last) }
        }
        let folder = times.count > 1 ? try Output.folder(beside: input, name: "\(base) snapshots") : nil
        var outputs: [URL] = []
        try await Output.filling(folder) {
            for (index, time) in times.enumerated() {
                let output = folder.map { Output.unique(in: $0, base: "\(base) \(index + 1)", ext: "png") }
                    ?? Output.file(beside: input, suffix: "snapshot", ext: "png")
                try await Output.produce(output) {
                    try await FFmpeg.run(["-ss", TimeCode.ffmpeg(time), "-i", input.path, "-frames:v", "1", output.path],
                                         duration: nil) { _ in }
                    // Durations can overstate the video track; fall back to the last frame there is.
                    if !FileManager.default.fileExists(atPath: output.path) {
                        try await FFmpeg.run(["-sseof", "-1", "-i", input.path, "-update", "1", output.path], duration: nil) { _ in }
                    }
                    guard FileManager.default.fileExists(atPath: output.path) else {
                        throw ClementineError.message("Couldn't take a snapshot of \(input.lastPathComponent) at \(TimeCode.ffmpeg(time)).")
                    }
                }
                outputs.append(output)
                progress(Double(index + 1) / Double(times.count))
            }
        }
        return folder.map { [$0] } ?? outputs
    }

    static func mute(_ input: URL, progress: @escaping Progress) async throws -> URL {
        _ = try await FFmpeg.readable(input, needsVideo: true)
        let output = Output.file(beside: input, suffix: "muted", ext: input.pathExtension.lowercased())
        return try await FFmpeg.transcode(input, to: output, args: ["-map", "0:v", "-c", "copy", "-an"], progress: progress)
    }

    static func rotate(_ input: URL, choice: Int, progress: @escaping Progress) async throws -> URL {
        let filters = [["transpose=1"], ["transpose=2"], ["transpose=1", "transpose=1"], ["hflip"]][choice]
        let info = try await FFmpeg.readable(input, needsVideo: true)
        let ext = input.pathExtension.lowercased()
        let output = Output.file(beside: input, suffix: "rotated", ext: ext)
        return try await FFmpeg.transcode(input, to: output, args: FFmpeg.encodeArgs(ext, streams: info, vf: filters),
                                          duration: info.duration, progress: progress)
    }

    /// Joins clips end to end, scaling everything to the first clip's frame so mixed sources work.
    static func joinVideos(_ inputs: [URL], progress: @escaping Progress) async throws -> URL {
        var infos: [FFmpeg.Info] = []
        for input in inputs { infos.append(try await FFmpeg.readable(input, needsVideo: true)) }
        let width = max(infos[0].width / 2 * 2, 2)
        let height = max(infos[0].height / 2 * 2, 2)

        var args: [String] = []
        var filters: [String] = []
        var extraInputs = inputs.count
        var concatInputs = ""
        for (index, input) in inputs.enumerated() {
            args += ["-i", input.path]
            filters.append("[\(index):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)]")
        }
        for (index, info) in infos.enumerated() {
            if info.hasAudio {
                filters.append("[\(index):a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            } else {
                // Silent clips get a generated track so concat lines up.
                args += ["-f", "lavfi", "-t", String(info.duration ?? 1), "-i", "anullsrc=r=48000:cl=stereo"]
                filters.append("[\(extraInputs):a]aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
                extraInputs += 1
            }
            concatInputs += "[v\(index)][a\(index)]"
        }
        filters.append("\(concatInputs)concat=n=\(inputs.count):v=1:a=1[v][a]")
        let output = Output.file(beside: inputs[0], suffix: "joined", ext: "mp4")
        let total = infos.compactMap(\.duration).reduce(0, +)
        try await Output.produce(output) {
            try await FFmpeg.run(args + ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                                         "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k",
                                         "-movflags", "+faststart", output.path],
                                 duration: total, progress: progress)
        }
        return output
    }

    static func joinAudio(_ inputs: [URL], progress: @escaping Progress) async throws -> URL {
        var args: [String] = []
        var filters: [String] = []
        var labels = ""
        var total = 0.0
        for (index, input) in inputs.enumerated() {
            args += ["-i", input.path]
            filters.append("[\(index):a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            labels += "[a\(index)]"
            total += try await FFmpeg.readable(input).duration ?? 0
        }
        filters.append("\(labels)concat=n=\(inputs.count):v=0:a=1[out]")
        let ext = inputs[0].pathExtension.lowercased()
        let output = Output.file(beside: inputs[0], suffix: "joined", ext: ext)
        try await Output.produce(output) {
            try await FFmpeg.run(args + ["-filter_complex", filters.joined(separator: ";"), "-map", "[out]"]
                                 + FFmpeg.encodeArgs(ext) + [output.path],
                                 duration: total, progress: progress)
        }
        return output
    }

    // MARK: Audio

    static func normalize(_ input: URL, progress: @escaping Progress) async throws -> URL {
        try await audioFilter(input, suffix: "normalized", filters: ["loudnorm=I=-16:TP=-1.5:LRA=11"], extra: ["-ar", "48000"], progress: progress)
    }

    static func trimSilence(_ input: URL, progress: @escaping Progress) async throws -> URL {
        let edge = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1"
        return try await audioFilter(input, suffix: "trimmed", filters: [edge, "areverse", edge, "areverse"], progress: progress)
    }

    enum ChannelLayout: Int {
        case mono, stereo, swap

        static let names = ["Mono", "Stereo", "Swap"]
    }

    /// Mixes down to mono, keeps stereo, or swaps left and right, with a gain (1 = unchanged) per side.
    /// Mono input feeds both sides; more than two channels are downmixed to stereo first.
    static func channels(_ input: URL, layout: ChannelLayout, left: Double = 1, right: Double = 1, to output: URL? = nil,
                         progress: @escaping Progress) async throws -> URL {
        let info = try await FFmpeg.readable(input)
        if info.probed, !info.hasAudio { throw ClementineError.message("\(input.lastPathComponent) has no audio track.") }
        // pan takes one factor per term and each input channel once per output; mono averages the two sides.
        let (l, r) = (min(max(left, 0), 4), min(max(right, 0), 4))
        func gain(_ value: Double) -> String { String(format: "%.4f", value) }
        let gains = layout == .mono ? [gain(l / 2), gain(r / 2)] : [gain(l), gain(r)]
        let sources = info.audioChannels == 1 ? ["c0", "c0"] : ["c0", "c1"]
        let pan = switch layout {
        case .mono where info.audioChannels == 1: "pan=mono|c0=\(gain((l + r) / 2))*c0"
        case .mono: "pan=mono|c0=\(gains[0])*\(sources[0])+\(gains[1])*\(sources[1])"
        case .stereo: "pan=stereo|c0=\(gains[0])*\(sources[0])|c1=\(gains[1])*\(sources[1])"
        case .swap: "pan=stereo|c0=\(gains[0])*\(sources[1])|c1=\(gains[1])*\(sources[0])"
        }
        let filters = (info.audioChannels > 2 ? ["aformat=channel_layouts=stereo"] : []) + [pan]
        let suffix = layout == .swap ? "swapped" : layout == .mono ? "mono" : "stereo"
        return try await audioFilter(input, suffix: suffix, filters: filters, extra: ["-ac", layout == .mono ? "1" : "2"],
                                     to: output, progress: progress)
    }

    /// Mutes each range and lays a 1 kHz tone over it. Video is copied untouched; only the sound is re-encoded.
    static func bleep(_ input: URL, ranges spec: String, to output: URL? = nil, progress: @escaping Progress) async throws -> URL {
        guard let ranges = TimeCode.ranges(spec) else {
            throw ClementineError.message("Write ranges like 0:05-0:06, 1:10-1:12.")
        }
        let windows = ranges.map { "between(t,\(TimeCode.ffmpeg($0.lowerBound)),\(TimeCode.ffmpeg($0.upperBound)))" }.joined(separator: "+")
        let graph = [
            "[0:a:0]volume=volume=0:enable='\(windows)'[muted]",
            "sine=frequency=1000:sample_rate=48000,volume=volume=0:enable='not(\(windows))'[tone]",
            "[muted][tone]amix=inputs=2:duration=first:normalize=0[out]",
        ].joined(separator: ";")
        let info = try await FFmpeg.readable(input)
        if info.probed, !info.hasAudio { throw ClementineError.message("\(input.lastPathComponent) has no audio track.") }
        let output = output ?? Output.file(beside: input, suffix: "bleeped", ext: input.pathExtension.lowercased())
        let encode = FFmpeg.encodeArgs(output.pathExtension.lowercased())
        var args = ["-filter_complex", graph]
        if info.hasVideo && !encode.contains("-vn") {
            // Keep the picture as it is and re-encode just the soundtrack with the container's usual audio codec.
            args += ["-map", "0:V?", "-map", "[out]", "-c:v", "copy"] + FFmpeg.audioArgs(encode)
        } else {
            args += ["-map", "[out]"] + encode
        }
        return try await FFmpeg.transcode(input, to: output, args: args, duration: info.duration, progress: progress)
    }

    private static func audioFilter(_ input: URL, suffix: String, filters: [String], extra: [String] = [], to output: URL? = nil,
                                    progress: @escaping Progress) async throws -> URL {
        _ = try await FFmpeg.readable(input)
        let output = output ?? Output.file(beside: input, suffix: suffix, ext: input.pathExtension.lowercased())
        return try await FFmpeg.transcode(input, to: output, args: FFmpeg.encodeArgs(output.pathExtension.lowercased(), af: filters) + extra,
                                          progress: progress)
    }

    // MARK: Metadata

    static func metadata(_ input: URL) async throws -> String {
        let ffprobe = try ToolLocator.require("ffprobe")
        let result = try await ProcessRunner.run(ffprobe, ["-hide_banner", input.path])
        return result.stderr
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Input #") }
            .joined(separator: "\n")
    }

    static func stripMetadata(_ input: URL, progress: @escaping Progress) async throws -> URL {
        _ = try await FFmpeg.readable(input)
        let output = Output.file(beside: input, suffix: "no metadata", ext: input.pathExtension.lowercased())
        return try await FFmpeg.transcode(input, to: output,
                                          args: ["-map", "0:V?", "-map", "0:a?", "-map", "0:s?", "-dn", "-ignore_unknown", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", "-fflags", "+bitexact"],
                                          progress: progress)
    }

    static func formatSpeed(_ speed: Double) -> String {
        speed == speed.rounded() ? String(Int(speed)) : String(speed)
    }
}
