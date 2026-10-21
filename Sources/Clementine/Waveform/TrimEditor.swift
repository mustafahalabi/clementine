import AppKit
import SwiftUI

/// Trim with a waveform (and filmstrip for video): drag the handles or the whole selection, type exact times,
/// snap silent ends away, and listen to the selection before applying. Produces the action's `start` and `end`.
@MainActor
enum TrimEditor {
    static func present(urls: [URL], values: ParamValues, apply: @escaping (ParamValues) -> Void) {
        let model = TrimModel(url: urls[0], values: values)
        EditorWindow.present(title: "Trim", onClose: model.close) { close in
            TrimEditorView(model: model, subtitle: editorSubtitle(urls, note: "same times for each"),
                           onApply: { result in close(); apply(result) }, onCancel: close)
        }
    }
}

@MainActor
final class TrimModel: WaveformEditorModel {
    /// Shortest selection, in seconds.
    static let minimumLength = 0.1

    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var trimsSilence = false
    @Published var frames: [CGImage] = []
    @Published var poster: CGImage?
    private var values: ParamValues
    private var hasRange = false
    /// The range before "Trim silent ends" moved the handles, to put back when it's turned off.
    private var manualRange: ClosedRange<Double>?

    init(url: URL, values: ParamValues) {
        self.values = values
        super.init(url: url)
        if duration > 0 { didLoad() }
    }

    var length: Double { max(end - start, 0) }

    override func didLoad() {
        guard !hasRange, duration > 0 else { return }
        hasRange = true
        start = min(TimeCode.seconds(values.text("start")) ?? 0, max(duration - Self.minimumLength, 0))
        end = min(TimeCode.seconds(values.text("end")) ?? duration, duration)
        if end - start < Self.minimumLength { end = duration }
    }

    override func loadExtras() async {
        guard isVideo else { return }
        async let strip = FilmstripLoader.frames(url, count: 10, height: 92)
        poster = await FilmstripLoader.frame(url, at: start, height: 440)
        frames = await strip
    }

    func setStart(_ value: Double) {
        start = min(max(value, 0), end - Self.minimumLength)
        trimsSilence = false
    }

    func setEnd(_ value: Double) {
        end = max(min(value, duration), start + Self.minimumLength)
        trimsSilence = false
    }

    /// Slides the selection to begin at `value`, keeping its length.
    func move(to value: Double) {
        let length = self.length
        start = min(max(value, 0), duration - length)
        end = start + length
        trimsSilence = false
    }

    func setTrimsSilence(_ on: Bool) {
        if on {
            guard let audible = waveform?.audibleRange() else { NSSound.beep(); return }
            manualRange = start...end
            start = audible.lowerBound
            end = max(audible.upperBound, start + Self.minimumLength)
        } else if let manualRange {
            start = manualRange.lowerBound
            end = manualRange.upperBound
        }
        trimsSilence = on
    }

    func togglePlay() {
        if playback.isPlaying { return playback.stop() }
        playOriginal(from: start, to: end)
    }

    var result: ParamValues {
        var result = values
        result.storage["start"] = .text(start < 0.0005 ? "0:00" : TimeCode.clock(start, decimals: 3))
        result.storage["end"] = .text(end > duration - 0.0005 ? "" : TimeCode.clock(end, decimals: 3))
        return result
    }
}

struct TrimEditorView: View {
    @ObservedObject var model: TrimModel
    let subtitle: String
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: model.isVideo ? "film" : "waveform", title: model.isVideo ? "Trim Video" : "Trim Audio", subtitle: subtitle)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            if model.isVideo {
                VideoPreview(model: model)
                    .frame(height: 230)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

            TrimTrack(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            readouts
                .disabled(model.duration == 0)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Toggle("Trim silent ends automatically", isOn: Binding(get: { model.trimsSilence },
                                                                       set: { on in withAnimation(Theme.spring) { model.setTrimsSilence(on) } }))
                    .toggleStyle(.checkbox)
                    .disabled(model.waveform == nil)
                Spacer()
                PreviewPlayButton(title: model.playback.isPlaying ? "Stop" : "Play Selected Range", playing: model.playback.isPlaying,
                                  action: model.togglePlay)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.duration == 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Divider().opacity(0.5).padding(.top, 16)

            HStack(spacing: 10) {
                Label("Drag the handles or the selection; times snap to the ends and to sound.", systemImage: "hand.draw")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SoftButtonStyle())
                Button("Apply") { onApply(model.result) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(model.duration == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .onAppear { model.load() }
    }

    private var readouts: some View {
        HStack(alignment: .bottom) {
            TimeField(label: "Start", seconds: model.start) { value in withAnimation(Theme.spring) { model.setStart(value) } }
            Spacer()
            VStack(spacing: 1) {
                Text(model.duration > 0 ? TimeCode.clock(model.length) : "–:––")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: model.length))
                Text(model.duration > 0 ? "selected of \(TimeCode.clock(model.duration))" : "selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText(scheme))
            }
            .animation(Theme.snappy, value: model.length)
            Spacer()
            TimeField(label: "End", seconds: model.end, alignment: .trailing) { value in withAnimation(Theme.spring) { model.setEnd(value) } }
        }
    }
}

/// The video frame at the playhead, with a still poster underneath until the player has one.
private struct VideoPreview: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        TrackWell(radius: 14) {
            ZStack {
                Color.black
                if let poster = model.poster {
                    Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                }
                PlayerLayerView(player: model.playback.player)
            }
            .animation(Theme.ease, value: model.poster != nil)
        }
        .onAppear { model.playback.prepare(model.url) }
    }
}

/// Filmstrip and waveform under a draggable selection frame, with a time ruler below.
private struct TrimTrack: View {
    @ObservedObject var model: TrimModel
    @ObservedObject private var playback: Playback
    @State private var drag: Target?
    @State private var snapped: Double?
    @Environment(\.colorScheme) private var scheme

    init(model: TrimModel) {
        self.model = model
        playback = model.playback
    }

    private enum Target: Equatable { case start, end, selection(grab: Double), scrub }
    private static let handleWidth: CGFloat = 12

    private var trackHeight: CGFloat { model.isVideo ? 46 + 84 : 128 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = TimeScale(duration: model.duration, width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        if model.isVideo {
                            Filmstrip(frames: model.frames).frame(height: 46)
                        }
                        waveform.padding(.vertical, 8)
                    }
                    if model.duration > 0 {
                        selection(scale)
                        PlayheadMarker()
                            .frame(height: geo.size.height)
                            .offset(x: scale.x(playback.time) - 4)
                            .opacity(playback.isPlaying || drag != nil ? 1 : 0)
                            .animation(Theme.ease, value: playback.isPlaying)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(scale))
                .onContinuousHover { phase in
                    guard case .active(let point) = phase else { return NSCursor.arrow.set() }
                    switch target(at: point.x, scale) {
                    case .start, .end: NSCursor.resizeLeftRight.set()
                    case .selection: NSCursor.openHand.set()
                    default: NSCursor.arrow.set()
                    }
                }
            }
            .frame(height: trackHeight)
            .background(TrackWell(radius: 10) { Color.clear })
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            TimeRuler(duration: model.duration)
                .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if let waveform = model.waveform {
            WaveformBars(peaks: waveform.mixed, bucketDuration: waveform.bucketDuration, duration: model.duration,
                         highlights: [model.start...max(model.start, model.end)])
                .transition(.opacity)
        } else if let failure = model.failure {
            Label(failure, systemImage: "speaker.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText(scheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WaveformShimmer().transition(.opacity)
        }
    }

    private func selection(_ scale: TimeScale) -> some View {
        let x0 = scale.x(model.start)
        let x1 = max(scale.x(model.end), x0 + Self.handleWidth * 2)
        let dim = Theme.backdrop(scheme).opacity(scheme == .dark ? 0.62 : 0.58)
        return ZStack(alignment: .topLeading) {
            dim.frame(width: max(x0, 0)).allowsHitTesting(false)
            dim.frame(width: max(scale.width - x1, 0)).offset(x: x1).allowsHitTesting(false)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                HStack(spacing: 0) {
                    handle(symbol: "chevron.compact.left", leading: true)
                    Spacer(minLength: 0)
                    handle(symbol: "chevron.compact.right", leading: false)
                }
            }
            .frame(width: x1 - x0)
            .offset(x: x0)
            .shadow(color: Theme.glow.opacity(0.5), radius: drag == nil ? 3 : 6)
            .allowsHitTesting(false)
        }
    }

    private func handle(symbol: String, leading: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: leading ? 8 : 0, bottomLeadingRadius: leading ? 8 : 0,
                                           bottomTrailingRadius: leading ? 0 : 8, topTrailingRadius: leading ? 0 : 8, style: .continuous)
        return ZStack {
            shape.fill(Theme.accent)
            shape.fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
        }
        .frame(width: Self.handleWidth)
    }

    // MARK: Dragging

    private func target(at x: CGFloat, _ scale: TimeScale) -> Target {
        let x0 = scale.x(model.start)
        let x1 = max(scale.x(model.end), x0 + Self.handleWidth * 2)
        let toStart = abs(x - (x0 + Self.handleWidth / 2))
        let toEnd = abs(x - (x1 - Self.handleWidth / 2))
        if min(toStart, toEnd) <= Self.handleWidth { return toStart <= toEnd ? .start : .end }
        if x > x0 && x < x1 { return .selection(grab: scale.time(x) - model.start) }
        return .scrub
    }

    private func dragGesture(_ scale: TimeScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.duration > 0 else { return }
                if drag == nil {
                    drag = target(at: value.startLocation.x, scale)
                    if drag != .scrub { playback.stop() }
                }
                let time = scale.time(value.location.x)
                switch drag {
                case .start:
                    model.setStart(snap(time, scale))
                    playback.scrub(to: model.start)
                case .end:
                    model.setEnd(snap(time, scale))
                    playback.scrub(to: model.end)
                case .selection(let grab):
                    guard abs(value.translation.width) > 2 else { return }
                    NSCursor.closedHand.set()
                    model.move(to: snap(time - grab, scale, length: model.length))
                    playback.scrub(to: model.start)
                case .scrub, nil:
                    playback.scrub(to: time)
                }
            }
            .onEnded { value in
                if case .selection = drag, abs(value.translation.width) <= 2 {
                    playback.scrub(to: scale.time(value.location.x)) // a click inside the selection moves the playhead
                }
                drag = nil
                snapped = nil
            }
    }

    /// Pulls `time` (or, with `length`, the selection's start or end) onto the file's ends or where sound begins and stops,
    /// when within a few points, with a gentle haptic tick.
    private func snap(_ time: Double, _ scale: TimeScale, length: Double? = nil) -> Double {
        var targets = [0, model.duration]
        if let audible = model.waveform?.audibleRange() { targets += [audible.lowerBound, audible.upperBound] }
        let reach = scale.resolution * 6
        var result = time
        var hit: Double?
        if let length {
            for target in targets {
                if abs(time - target) < reach { result = target; hit = target; break }
                if abs(time + length - target) < reach { result = target - length; hit = target; break }
            }
        } else if let target = targets.min(by: { abs($0 - time) < abs($1 - time) }), abs(target - time) < reach {
            result = target
            hit = target
        }
        if let hit, hit != snapped {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snapped = hit
        return result
    }
}
