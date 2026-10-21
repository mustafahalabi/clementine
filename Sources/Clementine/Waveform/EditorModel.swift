import AVFoundation
import AppKit

/// What every waveform editor needs: the file, its length and peaks (read in the background), and playback.
@MainActor
class WaveformEditorModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    @Published var waveform: Waveform?
    /// Why there's no waveform (no sound track, unreadable file), once loading gave up.
    @Published var failure: String?
    @Published var duration: Double = 0
    let playback = Playback()
    let renders = PreviewRenders()
    private var loading: Task<Void, Never>?
    #if DEBUG
    /// Keeps the shimmering placeholder up, for offscreen renders of the loading state.
    var holdsPlaceholder = false
    #endif

    init(url: URL) {
        self.url = url
        isVideo = FileItem(url: url).kind == .video
        if let cached = WaveformLoader.cached(url) {
            waveform = cached
            duration = cached.duration
        }
    }

    /// Reads the length and peaks; subclasses hook in with `didLoad`.
    func load() {
        guard loading == nil else { return }
        #if DEBUG
        if holdsPlaceholder { return }
        #endif
        loading = Task {
            if duration == 0 { duration = await Self.duration(of: url) }
            if duration > 0 { didLoad() }
            await loadExtras()
            do {
                let peaks = try await WaveformLoader.load(url)
                if duration == 0 { duration = peaks.duration }
                waveform = peaks
                didLoad()
            } catch is CancellationError {
            } catch {
                failure = isVideo ? "This video has no sound track." : "Couldn't read the sound in this file."
            }
        }
    }

    /// Called once the duration is known, and again when the waveform arrives.
    func didLoad() {}

    /// Extra loading (filmstrips) that should happen before the slower waveform pass.
    func loadExtras() async {}

    func close() {
        loading?.cancel()
        playback.tearDown()
        renders.discard()
    }

    /// Plays the file itself (or a playable copy) between two times.
    func playOriginal(from start: Double, to end: Double? = nil, tag: Int = 0) {
        Task {
            guard let source = try? await renders.playableSource(url) else { NSSound.beep(); return }
            playback.play(source, from: start, to: end, tag: tag)
        }
    }

    private static func duration(of url: URL) async -> Double {
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 { return seconds }
        return await FFmpeg.probe(url).duration ?? 0
    }
}
