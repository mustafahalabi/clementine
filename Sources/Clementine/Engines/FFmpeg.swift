import Foundation

enum FFmpeg {
    struct Info {
        /// False when ffprobe is missing or couldn't read the file, so the other fields mean nothing.
        var probed = false
        var duration: Double?
        var hasAudio = false
        /// Channel count of the first audio stream.
        var audioChannels = 0
        var hasVideo = false
        var width = 0
        var height = 0
        var frameRate: Double?
        /// Codec of each subtitle stream, in order.
        var subtitleCodecs: [String] = []
    }

    static func probe(_ url: URL) async -> Info {
        var info = Info()
        guard let ffprobe = ToolLocator.find("ffprobe"),
              let result = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-show_entries", "format=duration:stream=codec_type,codec_name,channels,width,height,avg_frame_rate:stream_disposition=attached_pic",
                  "-of", "json", url.path,
              ]),
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        else { return info }
        info.probed = true

        if let format = json["format"] as? [String: Any], let duration = format["duration"] as? String {
            info.duration = Double(duration)
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "audio":
                if !info.hasAudio { info.audioChannels = stream["channels"] as? Int ?? 0 }
                info.hasAudio = true
            case "video":
                // Cover art in audio files shows up as a single-frame "attached picture" video stream.
                let attached = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
                if !attached && !info.hasVideo {
                    info.hasVideo = true
                    info.width = stream["width"] as? Int ?? 0
                    info.height = stream["height"] as? Int ?? 0
                    let rate = (stream["avg_frame_rate"] as? String ?? "").split(separator: "/").compactMap { Double($0) }
                    if rate.count == 2, rate[0] > 0, rate[1] > 0 { info.frameRate = rate[0] / rate[1] }
                }
            case "subtitle":
                info.subtitleCodecs.append(stream["codec_name"] as? String ?? "")
            default:
                break
            }
        }
        return info
    }

    /// Probes `url`, throwing for empty files or ones with no audio or video (and, if `needsVideo`, no video).
    static func readable(_ url: URL, needsVideo: Bool = false) async throws -> Info {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if size == 0 { throw ClementineError.unreadable(url) }
        let info = await probe(url)
        guard info.probed else { return info }
        if !info.hasAudio && !info.hasVideo { throw ClementineError.unreadable(url) }
        if needsVideo && !info.hasVideo { throw ClementineError.message("\(url.lastPathComponent) has no video track.") }
        return info
    }

    /// Runs ffmpeg, reporting progress as the fraction of `duration` seconds written so far.
    static func run(_ args: [String], duration: Double?, progress: @escaping (Double) -> Void) async throws {
        let ffmpeg = try ToolLocator.require("ffmpeg")
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + args
        try await ProcessRunner.run(ffmpeg, full) { line in
            guard let duration, duration > 0,
                  line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                  let micros = Double(line.split(separator: "=").last ?? "")
            else { return }
            progress(min(max(micros / 1_000_000 / duration, 0), 1))
        }
    }

    /// `ffmpeg [inputArgs] -i input [args] output`, deleting the output on failure.
    @discardableResult
    static func transcode(
        _ input: URL,
        to output: URL,
        inputArgs: [String] = [],
        args: [String],
        duration: Double? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        var expected = duration
        if expected == nil { expected = await probe(input).duration }
        try await Output.produce(output) {
            try await run(inputArgs + ["-i", input.path] + args + [output.path], duration: expected, progress: progress)
        }
        return output
    }

    /// Encoder settings for an output container, merging any extra video/audio filters.
    /// Pass `streams` to keep every video, audio and (where the container allows) subtitle track instead of ffmpeg's default pick.
    static func encodeArgs(_ ext: String, streams: Info? = nil, vf: [String] = [], af: [String] = []) -> [String] {
        var video = vf
        var args: [String]
        switch ext {
        case "mp4", "m4v", "mov", "mkv":
            video.append(evenSize)
            args = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            if ext != "mkv" { args += ["-movflags", "+faststart"] }
        case "avi":
            video.append(evenSize)
            args = ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            video.append(evenSize)
            args = ["-c:v", "wmv2", "-b:v", "5M", "-c:a", "wmav2", "-b:a", "192k"]
        case "webm":
            args = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "gif":
            let chain = vf + ["fps=12", "scale='min(720,iw)':-2:flags=lanczos", "split[a][b];[a]palettegen[p];[b][p]paletteuse"]
            return ["-an", "-vf", chain.joined(separator: ","), "-loop", "0"]
        case "mp3":
            args = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac":
            args = ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav":
            args = ["-vn", "-c:a", "pcm_s16le"]
        case "flac":
            args = ["-vn", "-c:a", "flac"]
        case "ogg", "oga":
            args = ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", "192k"]
        case "opus":
            args = ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff", "aif":
            args = ["-vn", "-c:a", "pcm_s16be"]
        default:
            args = []
        }
        if let streams, !args.isEmpty, !args.contains("-vn") { args = streamMaps(ext, streams) + args }
        if !video.isEmpty && !args.contains("-vn") { args += ["-vf", video.joined(separator: ",")] }
        if !af.isEmpty { args += ["-af", af.joined(separator: ",")] }
        return args
    }

    /// Just the audio codec settings (and MP4/MOV's faststart) from `encodeArgs`, for jobs that copy the video.
    static func audioArgs(_ encodeArgs: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index + 1 < encodeArgs.count {
            let key = encodeArgs[index]
            if key.hasSuffix(":a") || key == "-movflags" || key == "-strict" { result += [key, encodeArgs[index + 1]] }
            index += 2
        }
        return result
    }

    /// Maps all video (minus cover art), audio and the subtitles `ext` can hold, converting text subtitles as needed.
    static func streamMaps(_ ext: String, _ info: Info) -> [String] {
        var args = ["-map", "0:V?", "-map", "0:a?"]
        var kept = 0
        for (index, codec) in info.subtitleCodecs.enumerated() {
            let isText = textSubtitles.contains(codec)
            let target: String? = switch ext {
            case "mp4", "m4v", "mov": isText ? "mov_text" : nil
            case "mkv": codec == "mov_text" ? "srt" : "copy"
            case "webm": isText ? "webvtt" : nil
            default: nil
            }
            guard let target else { continue }
            args += ["-map", "0:s:\(index)", "-c:s:\(kept)", target]
            kept += 1
        }
        return args
    }

    private static let textSubtitles: Set = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]

    /// Most encoders need even frame dimensions.
    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// `atempo` only accepts 0.5…2, so larger changes are chained.
    static func atempo(_ speed: Double) -> [String] {
        var remaining = speed
        var filters: [String] = []
        while remaining > 2 { filters.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { filters.append("atempo=0.5"); remaining /= 0.5 }
        filters.append("atempo=\(remaining)")
        return filters
    }

    /// Scales down so the longer edge is at most `maxEdge`, keeping even dimensions.
    static func fitFilter(maxEdge: Int) -> String {
        "scale='if(gte(iw,ih),trunc(min(\(maxEdge),iw)/2)*2,-2)':'if(gte(iw,ih),-2,trunc(min(\(maxEdge),ih)/2)*2)'"
    }
}
