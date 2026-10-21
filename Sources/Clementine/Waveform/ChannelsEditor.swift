import AppKit
import SwiftUI

/// Mono, stereo or swapped output with a volume per side, previewed as the output's waveform lanes and by ear.
/// Produces the action's `channels`, `left` and `right`.
@MainActor
enum ChannelsEditor {
    static func present(urls: [URL], values: ParamValues, apply: @escaping (ParamValues) -> Void) {
        let model = ChannelsModel(url: urls[0], values: values)
        EditorWindow.present(title: "Channels", onClose: model.close) { close in
            ChannelsEditorView(model: model, subtitle: editorSubtitle(urls, note: "same settings for each"),
                               onApply: { result in close(); apply(result) }, onCancel: close)
        }
    }
}

@MainActor
final class ChannelsModel: WaveformEditorModel {
    static let original = 0
    static let output = 1

    @Published var layout: MediaEngine.ChannelLayout
    @Published var left: Double
    @Published var right: Double
    @Published private(set) var preparing = false
    @Published var problem: String?
    private let values: ParamValues
    private var adjusted = false

    init(url: URL, values: ParamValues) {
        self.values = values
        layout = MediaEngine.ChannelLayout(rawValue: values.choice("channels")) ?? .mono
        left = values.storage["left"] == nil ? 1 : values.number("left")
        right = values.storage["right"] == nil ? 1 : values.number("right")
        super.init(url: url)
    }

    /// A mono file most likely wants to become stereo, so start there unless the layout was already changed.
    override func didLoad() {
        guard !adjusted, let waveform, !waveform.isStereo, layout == .mono else { return }
        adjusted = true
        layout = .stereo
    }

    func choose(_ layout: MediaEngine.ChannelLayout) {
        adjusted = true
        self.layout = layout
        stopOutput()
    }

    func setGain(left: Double? = nil, right: Double? = nil) {
        if let left { self.left = left }
        if let right { self.right = right }
        stopOutput()
    }

    /// The output's lanes, worked out from the input's peaks: one for mono, left and right otherwise.
    var outputLanes: [[Waveform.Peak]] {
        guard let waveform, let first = waveform.lanes.first else { return [] }
        let inputs = (first, waveform.lanes.count > 1 ? waveform.lanes[1] : first)
        let (l, r) = (Float(left), Float(right))
        func scaled(_ peaks: [Waveform.Peak], _ gain: Float) -> [Waveform.Peak] {
            peaks.map { Waveform.Peak(low: $0.low * gain, high: $0.high * gain) }
        }
        switch layout {
        case .stereo: return [scaled(inputs.0, l), scaled(inputs.1, r)]
        case .swap: return [scaled(inputs.1, l), scaled(inputs.0, r)]
        case .mono:
            return [zip(inputs.0, inputs.1).map { a, b in
                Waveform.Peak(low: 0.5 * (a.low * l + b.low * r), high: 0.5 * (a.high * l + b.high * r))
            }]
        }
    }

    var result: ParamValues {
        var result = values
        result.storage["channels"] = .choice(layout.rawValue)
        result.storage["left"] = .number(left)
        result.storage["right"] = .number(right)
        return result
    }

    func play(_ tag: Int) {
        if playback.isPlaying && playback.playingTag == tag { return playback.stop() }
        if tag == Self.original { return playOriginal(from: 0, tag: tag) }
        let (url, layout, left, right) = (self.url, self.layout, self.left, self.right)
        preparing = true
        problem = nil
        Task {
            defer { preparing = false }
            do {
                let preview = try await renders.render("channels \(layout.rawValue) \(left) \(right)") { output in
                    try await MediaEngine.channels(url, layout: layout, left: left, right: right, to: output) { _ in }
                }
                playback.play(preview, from: 0, tag: tag)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func stopOutput() {
        if playback.isPlaying && playback.playingTag == Self.output { playback.stop() }
    }
}

struct ChannelsEditorView: View {
    @ObservedObject var model: ChannelsModel
    @ObservedObject private var playback: Playback
    let subtitle: String
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ChannelsModel, subtitle: String, onApply: @escaping (ParamValues) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        playback = model.playback
        self.subtitle = subtitle
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private static let layouts: [(title: String, symbol: String)] = [
        ("Mono", "hifispeaker"), ("Stereo", "hifispeaker.2"), ("Swap L ⇄ R", "arrow.left.arrow.right"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: "speaker.wave.2", title: "Convert Audio Channels", subtitle: subtitle)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            CitrusSegmented(options: Self.layouts,
                            selection: Binding(get: { model.layout.rawValue },
                                               set: { index in withAnimation(Theme.spring) { model.choose(.init(rawValue: index) ?? .stereo) } }))
                .padding(.horizontal, 20)
                .padding(.top, 16)

            lanes
                .padding(.horizontal, 20)
                .padding(.top, 14)

            VStack(spacing: 0) {
                GainRow(label: "Left", detail: model.layout == .swap ? "plays the right channel" : nil, value: model.left) {
                    model.setGain(left: $0)
                }
                Divider().opacity(0.6).padding(.leading, 40)
                GainRow(label: "Right", detail: model.layout == .swap ? "plays the left channel" : nil, value: model.right) {
                    model.setGain(right: $0)
                }
            }
            .card(radius: 12)
            .padding(.horizontal, 20)
            .padding(.top, 14)

            HStack(spacing: 8) {
                PreviewPlayButton(title: "Original", playing: playback.isPlaying && playback.playingTag == ChannelsModel.original) {
                    model.play(ChannelsModel.original)
                }
                PreviewPlayButton(title: "Play Output", playing: playback.isPlaying && playback.playingTag == ChannelsModel.output,
                                  preparing: model.preparing, accent: true) {
                    model.play(ChannelsModel.output)
                }
                .keyboardShortcut(.space, modifiers: [])
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cherry)
                        .lineLimit(1)
                }
                Spacer()
                Button("Reset Volumes") { withAnimation(Theme.spring) { model.setGain(left: 1, right: 1) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tangerine)
                    .opacity(model.left != 1 || model.right != 1 ? 1 : 0)
                    .animation(Theme.ease, value: model.left != 1 || model.right != 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Divider().opacity(0.5).padding(.top, 16)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SoftButtonStyle())
                Button("Apply") { onApply(model.result) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 600)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .onAppear { model.load() }
    }

    /// The output as it will sound: one lane for mono, left over right otherwise.
    private var lanes: some View {
        let lanes = model.outputLanes
        let reference = model.waveform.map { $0.lanes.flatMap { $0 }.map(\.magnitude).max() ?? 1 }
        let tags = model.layout == .mono ? ["Mono"] : model.layout == .swap ? ["L ← R", "R ← L"] : ["L", "R"]
        return TrackWell(radius: 10) {
            ZStack {
                if let waveform = model.waveform, !lanes.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(lanes.indices, id: \.self) { index in
                            WaveformBars(peaks: lanes[index], bucketDuration: waveform.bucketDuration, duration: model.duration,
                                         highlights: [0...model.duration], reference: reference)
                                .padding(.vertical, 6)
                                .overlay(alignment: .topLeading) { LaneTag(text: tags[index]).padding(6) }
                                .overlay(alignment: .bottom) {
                                    if index < lanes.count - 1 { Rectangle().fill(Theme.edge(scheme)).frame(height: 1) }
                                }
                                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                        }
                    }
                    .transition(.opacity)
                } else if let failure = model.failure {
                    Label(failure, systemImage: "speaker.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText(scheme))
                } else {
                    WaveformShimmer().padding(.vertical, 10)
                }
                if model.duration > 0 && playback.isPlaying {
                    GeometryReader { geo in
                        PlayheadMarker()
                            .frame(height: geo.size.height)
                            .offset(x: TimeScale(duration: model.duration, width: geo.size.width).x(playback.time) - 4)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 150)
        }
        .animation(Theme.spring, value: model.layout)
        .animation(Theme.ease, value: playback.isPlaying)
    }
}

private struct GainRow: View {
    let label: String
    let detail: String?
    let value: Double
    let set: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: value == 0 ? "speaker.slash.fill" : value < 0.6 ? "speaker.wave.1.fill" : value <= 1.2 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tangerine)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText(scheme))
                        .transition(.opacity)
                }
            }
            .frame(width: 128, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 * 20).rounded() / 20) }), in: 0...2)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondaryText(scheme))
                .contentTransition(.numericText(value: value))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .animation(Theme.snappy, value: value)
        .animation(Theme.ease, value: detail)
    }
}
