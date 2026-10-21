import AVFoundation
import AppKit
import SwiftUI

/// Plays a file (or a preview render of it) over a time range and publishes the playhead for the editors.
@MainActor
final class Playback: ObservableObject {
    /// The playhead, in seconds.
    @Published var time: Double = 0
    @Published private(set) var isPlaying = false
    /// Which version is playing, for editors that compare an original with a preview.
    @Published private(set) var playingTag = 0

    let player = AVPlayer()
    private var source: URL?
    private var tickObserver: Any?
    private var stopObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        tickObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, time.isNumeric else { return }
                self.time = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                             queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.finish()
            }
        }
    }

    /// Shows `url` without playing it (so a video's first frame appears).
    func prepare(_ url: URL) {
        guard source != url else { return }
        source = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    /// Plays `url` from `start`, stopping at `end` (or the end of the file).
    func play(_ url: URL, from start: Double, to end: Double? = nil, tag: Int = 0) {
        prepare(url)
        clearStop()
        playingTag = tag
        time = start
        isPlaying = true
        if let end {
            stopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                          queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.time = end
                    self?.finish()
                }
            }
        }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard done, let self, self.isPlaying else { return }
                    self.player.play()
                }
            }
        }
    }

    func stop() {
        guard isPlaying else { return }
        finish()
    }

    /// Moves the playhead (and the video frame) without playing; stops playback if it was running.
    func scrub(to seconds: Double) {
        stop()
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: CMTime(value: 1, timescale: 30), toleranceAfter: CMTime(value: 1, timescale: 30))
    }

    /// Stops for good when the editor closes.
    func tearDown() {
        stop()
        if let tickObserver { player.removeTimeObserver(tickObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        tickObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func finish() {
        player.pause()
        clearStop()
        isPlaying = false
    }

    private func clearStop() {
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }
}

/// Temporary renders for previews (bleeped audio, channel mixes, playable copies of files AVFoundation can't open),
/// kept per editor and deleted when it closes.
@MainActor
final class PreviewRenders {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clementine Previews/\(UUID().uuidString)")
    private var renders: [String: URL] = [:]
    private var playable: [URL: URL] = [:]

    /// The render stored under `key`, made with `make` into a fresh `.m4a` path if there isn't one yet.
    func render(_ key: String, make: @escaping (URL) async throws -> URL) async throws -> URL {
        if let done = renders[key] { return done }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("\(UUID().uuidString).m4a")
        let url = try await make(output)
        renders[key] = url
        return url
    }

    /// `url` itself when AVFoundation can play it, otherwise an AAC copy of its sound.
    func playableSource(_ url: URL) async throws -> URL {
        if let known = playable[url] { return known }
        let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
        let result = playable ? url : try await render("playable", make: { output in
            try await FFmpeg.transcode(url, to: output, args: ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "160k"]) { _ in }
        })
        self.playable[url] = result
        return result
    }

    func discard() {
        try? FileManager.default.removeItem(at: folder)
        renders = [:]
        playable = [:]
    }
}

/// A video frame surface for the player.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
