import AVFoundation
import Foundation

/// A file's sound reduced to min/max peaks per time bucket, one lane per channel (at most two).
struct Waveform: Sendable {
    struct Peak: Sendable {
        var low: Float
        var high: Float

        var magnitude: Float { max(-low, high) }
    }

    /// One array of peaks per channel: `[left]` for mono, `[left, right]` otherwise.
    let lanes: [[Peak]]
    /// Length of the sound in seconds.
    let duration: Double
    /// Seconds covered by each peak (the last one may cover less).
    let bucketDuration: Double

    var isStereo: Bool { lanes.count > 1 }
    var bucketCount: Int { lanes.first?.count ?? 0 }

    /// All lanes folded into one, for single-lane drawing.
    var mixed: [Peak] {
        guard lanes.count > 1 else { return lanes.first ?? [] }
        return zip(lanes[0], lanes[1]).map { Peak(low: min($0.low, $1.low), high: max($0.high, $1.high)) }
    }

    /// Where the sound starts and stops being louder than the noise floor: -40 dB under the loudest peak,
    /// but never above -60 dBFS. Nil when it's silent throughout. Padded a little so words aren't clipped.
    func audibleRange(padding: Double = 0.1) -> ClosedRange<Double>? {
        let peaks = mixed.map(\.magnitude)
        guard let loudest = peaks.max(), loudest > 0 else { return nil }
        let threshold = max(loudest * 0.01, 0.001)
        guard let first = peaks.firstIndex(where: { $0 > threshold }),
              let last = peaks.lastIndex(where: { $0 > threshold }) else { return nil }
        let start = max(0, Double(first) * bucketDuration - padding)
        let end = min(duration, Double(last + 1) * bucketDuration + padding)
        return start...max(start, end)
    }
}

/// Extracts and caches waveforms. AVFoundation decodes what it can (audio files and the soundtrack of movies);
/// anything else (Ogg, Matroska, WMA…) goes through ffmpeg.
enum WaveformLoader {
    /// Peaks per lane; enough for a crisp ~800 pt wide view on Retina.
    static let buckets = 1600

    @MainActor private static var cache: [String: Waveform] = [:]

    @MainActor
    static func cached(_ url: URL) -> Waveform? { cache[key(url)] }

    @MainActor
    static func load(_ url: URL) async throws -> Waveform {
        let key = key(url)
        if let hit = cache[key] { return hit }
        let reading = Task.detached(priority: .userInitiated) {
            do {
                return try await readWithAVFoundation(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await readWithFFmpeg(url)
            }
        }
        let waveform = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
        cache[key] = waveform
        return waveform
    }

    /// Path plus modification date, so an edited file is read again.
    private static func key(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: AVFoundation

    private static func readWithAVFoundation(_ url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ClementineError.message("\(url.lastPathComponent) has no audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate > 0, duration.isFinite, duration > 0 else {
            throw ClementineError.unreadable(url)
        }
        let channels = Int(max(description.mChannelsPerFrame, 1))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClementineError.unreadable(url) }

        var builder = PeakBuilder(channels: channels, rate: description.mSampleRate, expectedFrames: duration * description.mSampleRate)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                builder.add(UnsafeBufferPointer(start: samples, count: length / 4))
            }
        }
        if reader.status == .failed { throw reader.error ?? ClementineError.unreadable(url) }
        return builder.finish(duration: duration)
    }

    // MARK: ffmpeg

    /// Decodes to 8 kHz float PCM on stdout, which is plenty for drawing.
    private static func readWithFFmpeg(_ url: URL) async throws -> Waveform {
        let ffmpeg = try ToolLocator.require("ffmpeg")
        let info = await FFmpeg.probe(url)
        let channels = min(max(info.audioChannels, 1), 2)
        let rate = 8000.0
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-peaks-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await ProcessRunner.run(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:a:0", "-ac", String(channels),
                                             "-ar", String(Int(rate)), "-f", "f32le", "pipe:1"], stdoutFile: raw)
        let data = try Data(contentsOf: raw, options: .alwaysMapped)
        let frames = Double(data.count / 4 / channels)
        guard frames > 0 else { throw ClementineError.unreadable(url) }
        var builder = PeakBuilder(channels: channels, rate: rate, expectedFrames: frames)
        data.withUnsafeBytes { bytes in builder.add(bytes.bindMemory(to: Float.self)) }
        return builder.finish(duration: frames / rate)
    }
}

/// Folds interleaved samples into fixed-size min/max buckets as they stream in.
private struct PeakBuilder {
    let channels: Int
    let rate: Double
    let lanes: Int
    let framesPerBucket: Int
    private var peaks: [[Waveform.Peak]]
    private var current: [Waveform.Peak]
    private var framesInBucket = 0
    private var channel = 0

    init(channels: Int, rate: Double, expectedFrames: Double) {
        self.channels = channels
        self.rate = rate
        lanes = min(channels, 2)
        framesPerBucket = max(1, Int((expectedFrames / Double(WaveformLoader.buckets)).rounded(.up)))
        peaks = Array(repeating: [], count: lanes)
        current = Array(repeating: Waveform.Peak(low: 0, high: 0), count: lanes)
        for lane in 0..<lanes { peaks[lane].reserveCapacity(WaveformLoader.buckets + 1) }
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            if channel < lanes {
                if sample < current[channel].low { current[channel].low = sample }
                if sample > current[channel].high { current[channel].high = sample }
            }
            channel += 1
            if channel == channels {
                channel = 0
                framesInBucket += 1
                if framesInBucket == framesPerBucket { flush() }
            }
        }
    }

    private mutating func flush() {
        for lane in 0..<lanes {
            peaks[lane].append(Waveform.Peak(low: max(current[lane].low, -1), high: min(current[lane].high, 1)))
            current[lane] = Waveform.Peak(low: 0, high: 0)
        }
        framesInBucket = 0
    }

    mutating func finish(duration: Double) -> Waveform {
        if framesInBucket > 0 { flush() }
        if peaks[0].isEmpty { peaks = Array(repeating: [Waveform.Peak(low: 0, high: 0)], count: lanes) }
        return Waveform(lanes: peaks, duration: duration, bucketDuration: Double(framesPerBucket) / rate)
    }
}
