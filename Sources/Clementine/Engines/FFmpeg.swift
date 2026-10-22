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
        /// Colour tags of the first video stream, as ffprobe names them ("smpte2084", "bt2020"…); nil when untagged.
        var colorTransfer: String?
        var colorPrimaries: String?
        /// Degrees from the display matrix (phones store portrait video as rotated landscape).
        var rotation = 0

        /// PQ (HDR10, Dolby Vision) or HLG (iPhone) video.
        var isHDR: Bool { colorTransfer.map(FFmpeg.hdrTransfers.contains) ?? false }
        /// The frame as players show it, after the display matrix.
        var displayWidth: Int { abs(rotation) % 180 == 90 ? height : width }
        var displayHeight: Int { abs(rotation) % 180 == 90 ? width : height }
    }

    static let hdrTransfers: Set = ["smpte2084", "arib-std-b67"]

    static func probe(_ url: URL) async -> Info {
        var info = Info()
        guard let ffprobe = ToolLocator.find("ffprobe"),
              let result = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-show_entries", "format=duration:stream=codec_type,codec_name,channels,width,height,avg_frame_rate,color_transfer,color_primaries"
                      + ":stream_disposition=attached_pic:stream_side_data=rotation",
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
                    func tag(_ key: String) -> String? {
                        (stream[key] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
                    }
                    info.colorTransfer = tag("color_transfer")
                    info.colorPrimaries = tag("color_primaries")
                    for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
                        if let degrees = side["rotation"] as? Int { info.rotation = degrees }
                        else if let degrees = side["rotation"] as? Double { info.rotation = Int(degrees.rounded()) }
                    }
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
        // -n: outputs are always fresh names from Output, so an existing file there belongs to someone else.
        let full = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + args
        try await ProcessRunner.run(ffmpeg, full) { line in
            guard let duration, duration > 0,
                  line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                  let micros = Double(line.split(separator: "=").last ?? "")
            else { return }
            progress(min(max(micros / 1_000_000 / duration, 0), 1))
        }
    }

    /// `ffmpeg [inputArgs] -i input [args] output`, deleting the output on failure. With `hardware`, H.264/HEVC
    /// encodes use VideoToolbox when Settings allow it (see `encode`).
    @discardableResult
    static func transcode(
        _ input: URL,
        to output: URL,
        inputArgs: [String] = [],
        args: [String],
        duration: Double? = nil,
        hardware: Bool = false,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        var expected = duration
        if expected == nil { expected = await probe(input).duration }
        try await Output.produce(output) {
            try await encode(inputArgs + ["-i", input.path] + args, to: output, hardware: hardware, duration: expected,
                             progress: progress)
        }
        return output
    }

    /// Runs `ffmpeg args output`. With `hardware`, software x264/x265 settings are swapped for VideoToolbox first;
    /// if that fails (no media engine on virtual Macs, a size it refuses…) the software encoder runs instead.
    static func encode(_ args: [String], to output: URL, hardware: Bool, duration: Double?,
                       progress: @escaping (Double) -> Void) async throws {
        if hardware, let accelerated = Hardware.variant(of: args) {
            do {
                try await run(accelerated + [output.path], duration: duration, progress: progress)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                try? FileManager.default.removeItem(at: output)
            }
        }
        try await run(args + [output.path], duration: duration, progress: progress)
    }

    /// VideoToolbox stand-ins for the software H.264/HEVC settings. Measured on a 5 s 4K clip it's several times
    /// faster and uses a fraction of the CPU; at matched quality (VMAF) files come out ~25% bigger, so Compress
    /// and Fit, which are about size, stay on x264.
    enum Hardware {
        /// Set by the CLI's `--software`, so tests and comparisons can pin the encoder.
        static let forceSoftware = Locked(false)

        static var enabled: Bool { Prefs.hardwareEncoding && !forceSoftware.withLock { $0 } }

        /// The same encode on VideoToolbox, or nil when `args` isn't a CRF x264/x265 encode or hardware is off.
        static func variant(of args: [String]) -> [String]? {
            guard enabled, !args.contains("-pass"),
                  let codec = args.firstIndex(of: "-c:v"), codec + 1 < args.count,
                  let crfKey = args.firstIndex(of: "-crf"), crfKey + 1 < args.count, let crf = Double(args[crfKey + 1])
            else { return nil }
            let encoder: String
            let base: Double
            switch args[codec + 1] {
            case "libx264": (encoder, base) = ("h264_videotoolbox", 20)
            case "libx265": (encoder, base) = ("hevc_videotoolbox", 22)
            default: return nil
            }
            var result: [String] = []
            var index = 0
            while index < args.count {
                let key = args[index]
                let value = index + 1 < args.count ? args[index + 1] : ""
                switch key {
                case "-preset", "-crf", "-x265-params":
                    index += 2
                    continue
                case "-c:v":
                    result += ["-c:v", encoder, "-q:v", String(quality(crf: crf, base: base))]
                    index += 2
                    continue
                case "-pix_fmt" where value == "yuv420p10le":
                    result += ["-pix_fmt", "p010le", "-profile:v", "main10"]
                    index += 2
                    continue
                default:
                    result.append(key)
                    index += 1
                }
            }
            return result
        }

        /// VideoToolbox's constant-quality scale (1–100) for an x264/x265 CRF. Calibrated with VMAF on 1080p
        /// camera-like footage: x264 CRF 20 ≈ q 65, and each CRF step ≈ 2.3 points.
        static func quality(crf: Double, base: Double) -> Int {
            Int(min(max(65 - (crf - base) * 2.3, 1), 100).rounded())
        }
    }

    // MARK: Colour

    /// What an output does with an HDR source.
    enum Color: Equatable {
        /// SDR source, or no video.
        case unchanged
        /// Into an 8-bit format: these filters tone-map to BT.709, and the output is tagged BT.709.
        case toneMap([String])
        /// Kept HDR as 10-bit HEVC with this transfer (MP4/MOV only).
        case hdr(transfer: String, primaries: String)
    }

    /// Containers where an edit keeps HDR as 10-bit HEVC (what iPhones record).
    static let hdrContainers: Set = ["mp4", "m4v", "mov"]

    /// Without this, 10-bit PQ/HLG video squeezed into 8-bit H.264 keeps its BT.2020 tags or loses them, and
    /// either way plays washed out.
    static func color(for info: Info, ext: String, keepHDR: Bool = false) async -> Color {
        guard info.hasVideo, info.isHDR, let transfer = info.colorTransfer else { return .unchanged }
        if keepHDR && hdrContainers.contains(ext) { return .hdr(transfer: transfer, primaries: info.colorPrimaries ?? "bt2020") }
        return .toneMap(await toneMap(info))
    }

    /// HDR → SDR BT.709, 8-bit. zscale + tonemap when this ffmpeg has them (the bundled one does); otherwise
    /// per-channel curves with lutrgb and a gamut change with colorspace, which every build has.
    static func toneMap(_ info: Info) async -> [String] {
        let transfer = info.colorTransfer ?? "smpte2084"
        let primaries = info.colorPrimaries ?? "bt2020"
        if await hasFilter("zscale"), await hasFilter("tonemap") {
            // npl=100: SDR white is 100 nits. Mobius with a high knee keeps mid-tones and only bends highlights.
            return ["zscale=tin=\(transfer):pin=\(primaries):min=bt2020nc:t=linear:npl=100", "format=gbrpf32le", "zscale=p=bt709",
                    "tonemap=tonemap=mobius:param=0.8:desat=0", "zscale=t=bt709:m=bt709:r=tv", "format=yuv420p"]
        }
        let value = "clip(val/1023,0,1)"
        // Each curve gives display light relative to 100 nits.
        let light: String
        if transfer == "arib-std-b67" {
            // HLG inverse OETF to scene light, then the 1000-nit OOTF (gamma 1.2).
            let scene = "if(lte(\(value),0.5),\(value)*\(value)/3,(exp((\(value)-0.55991073)/0.17883277)+0.28466892)/12)"
            light = "(10*pow(\(scene),1.2))"
        } else {
            // SMPTE ST 2084 (PQ) EOTF.
            let e = "pow(\(value),1/78.84375)"
            light = "(pow(max(\(e)-0.8359375,0)/(18.8515625-18.6875*\(e)),1/0.1593017578125)*100)"
        }
        // Soft knee above 0.8, then the BT.709 OETF, back to 10-bit codes.
        let curve = "1023*(1.099*pow(if(lte(\(light),0.8),\(light),0.8+0.2*(1-exp(-(\(light)-0.8)/0.2))),0.45)-0.099)"
        return ["scale=in_color_matrix=bt2020:in_range=tv", "format=gbrp10le", "lutrgb=r='\(curve)':g='\(curve)':b='\(curve)'",
                "scale=out_color_matrix=bt2020:out_range=tv", "format=yuv420p10le",
                "colorspace=all=bt709:iall=bt2020:itrc=bt2020-10:format=yuv420p"]
    }

    static let bt709Tags = ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]

    private static let filterCache = Locked([String: Set<String>]())

    /// Whether the ffmpeg in use has `name`, asked once per ffmpeg path.
    static func hasFilter(_ name: String) async -> Bool {
        guard let ffmpeg = ToolLocator.find("ffmpeg") else { return false }
        if let known = filterCache.withLock({ $0[ffmpeg.path] }) { return known.contains(name) }
        let listing = (try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-filters"]))?.stdout ?? ""
        // Lines look like " TS colorspace        V->V       Convert between colorspaces."
        let names = Set(listing.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count >= 3 ? String(fields[1]) : nil
        })
        filterCache.withLock { $0[ffmpeg.path] = names }
        return names.contains(name)
    }

    // MARK: Encoder settings

    /// x264 at visually transparent quality; `encode(hardware: true)` swaps in VideoToolbox.
    static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]

    /// 10-bit HEVC that keeps HDR, tagged hvc1 so QuickTime and Photos play it.
    static func hevcHDR(transfer: String, primaries: String) -> [String] {
        ["-c:v", "libx265", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
         "-x265-params", "log-level=error:colorprim=\(primaries):transfer=\(transfer):colormatrix=bt2020nc",
         "-color_primaries", primaries, "-color_trc", transfer, "-colorspace", "bt2020nc"]
    }

    /// Encoder settings for an output container, merging any extra video/audio filters.
    /// Pass `streams` to keep every video, audio and (where the container allows) subtitle track instead of ffmpeg's default pick.
    /// `color` (from `color(for:ext:)`) tone-maps or keeps HDR sources.
    static func encodeArgs(_ ext: String, streams: Info? = nil, color: Color = .unchanged, vf: [String] = [],
                           af: [String] = []) -> [String] {
        var video = vf
        if case .toneMap(let filters) = color { video = filters + vf }
        var args: [String]
        switch ext {
        case "mp4", "m4v", "mov", "mkv", "3gp", "3g2":
            video.append(evenSize)
            if case .hdr(let transfer, let primaries) = color, hdrContainers.contains(ext) {
                args = hevcHDR(transfer: transfer, primaries: primaries)
            } else {
                args = h264
            }
            args += ["-c:a", "aac", "-b:a", "192k"]
            if ext != "mkv" { args += ["-movflags", "+faststart"] }
        case "ts", "m2ts", "mts", "flv":
            // ffmpeg's defaults here are MPEG-2/FLV1 at 200 kb/s; both containers carry H.264 + AAC.
            video.append(evenSize)
            args = h264 + ["-c:a", "aac", "-b:a", "192k"]
        case "mpg", "mpeg":
            video.append(evenSize)
            args = ["-c:v", "mpeg2video", "-q:v", "3", "-c:a", "mp2", "-b:a", "224k"]
        case "avi":
            video.append(evenSize)
            args = ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            video.append(evenSize)
            args = ["-c:v", "wmv2", "-b:v", "5M", "-c:a", "wmav2", "-b:a", "192k"]
        case "webm":
            args = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "gif":
            return gifArgs(GIFOptions(), color: color, vf: vf)
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
        if case .toneMap = color, !args.isEmpty, !args.contains("-vn") { args += bt709Tags }
        if !video.isEmpty && !args.contains("-vn") { args += ["-vf", video.joined(separator: ",")] }
        if !af.isEmpty { args += ["-af", af.joined(separator: ",")] }
        return args
    }

    /// Video → GIF settings. The defaults are what the Convert wheel's GIF slice uses.
    struct GIFOptions {
        var fps = 15
        /// Longest edge isn't the point for GIFs, width is; nil keeps the source's.
        var width: Int? = 720
    }

    /// One palette for the whole clip (weighted to what moves) and error-diffusion dithering, only redrawn
    /// where frames change so files stay small.
    static func gifArgs(_ options: GIFOptions, color: Color = .unchanged, vf: [String] = []) -> [String] {
        var chain = vf
        if case .toneMap(let filters) = color { chain = filters + vf }
        chain.append("fps=\(options.fps)")
        if let width = options.width { chain.append("scale='min(\(width),iw)':-2:flags=lanczos") }
        chain.append("split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle")
        return ["-an", "-vf", chain.joined(separator: ","), "-loop", "0"]
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
