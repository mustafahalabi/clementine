import AppKit
import SwiftUI

/// Mark bleeps by dragging across the waveform, nudge their edges, and compare the original with a bleeped preview.
/// Produces the action's `ranges`.
@MainActor
enum BleepEditor {
    static func present(urls: [URL], values: ParamValues, apply: @escaping (ParamValues) -> Void) {
        let model = BleepModel(url: urls[0], values: values)
        EditorWindow.present(title: "Bleep", onClose: model.close) { close in
            BleepEditorView(model: model, subtitle: editorSubtitle(urls, note: "same bleeps for each"),
                            onApply: { result in close(); apply(result) }, onCancel: close)
        }
    }
}

@MainActor
final class BleepModel: WaveformEditorModel {
    struct Region: Identifiable, Hashable {
        let id: UUID
        var start: Double
        var end: Double

        var range: ClosedRange<Double> { start...max(start, end) }
    }

    /// Shortest bleep, in seconds.
    static let minimumLength = 0.05
    static let original = 0
    static let bleeped = 1

    @Published var regions: [Region] = []
    @Published private(set) var preparing = false
    @Published var problem: String?
    private let values: ParamValues

    init(url: URL, values: ParamValues) {
        self.values = values
        super.init(url: url)
        regions = (TimeCode.ranges(values.text("ranges")) ?? []).map { Region(id: UUID(), start: $0.lowerBound, end: $0.upperBound) }
    }

    /// Ranges in time order with overlaps merged, as `0:05.200-0:06.100, …`.
    var spec: String {
        normalized.map { "\(TimeCode.clock($0.start, decimals: 3))-\(TimeCode.clock($0.end, decimals: 3))" }.joined(separator: ", ")
    }

    var result: ParamValues {
        var result = values
        result.storage["ranges"] = .text(spec)
        return result
    }

    private var normalized: [Region] {
        var merged: [Region] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, region.start <= last.end {
                merged[merged.count - 1].end = max(last.end, region.end)
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    func add(from a: Double, to b: Double) -> UUID {
        let region = Region(id: UUID(), start: max(min(a, b), 0), end: min(max(a, b), duration))
        regions.append(region)
        return region.id
    }

    func update(_ id: UUID, _ change: (inout Region) -> Void) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        change(&regions[index])
        regions[index].start = min(max(regions[index].start, 0), duration)
        regions[index].end = min(max(regions[index].end, 0), duration)
        stopBleeped()
    }

    func remove(_ id: UUID) {
        regions.removeAll { $0.id == id }
        stopBleeped()
    }

    /// Drops slivers and merges overlaps after a drag, keeping time order.
    func tidy() {
        regions = normalized.filter { $0.end - $0.start >= Self.minimumLength }
    }

    /// Plays the original or the bleeped version from the playhead (or just before the first bleep).
    func play(_ tag: Int) {
        if playback.isPlaying && playback.playingTag == tag { return playback.stop() }
        let from = playback.time > 0 && playback.time < duration - 0.2 ? playback.time : max((normalized.first?.start ?? 0) - 1.5, 0)
        if tag == Self.original { return playOriginal(from: from, tag: tag) }
        guard !regions.isEmpty else { return }
        let spec = self.spec
        let url = self.url
        preparing = true
        problem = nil
        Task {
            defer { preparing = false }
            do {
                let preview = try await renders.render("bleep \(spec)") { output in
                    try await MediaEngine.bleep(url, ranges: spec, to: output) { _ in }
                }
                playback.play(preview, from: from, tag: tag)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func stopBleeped() {
        if playback.isPlaying && playback.playingTag == Self.bleeped { playback.stop() }
    }
}

struct BleepEditorView: View {
    @ObservedObject var model: BleepModel
    @ObservedObject private var playback: Playback
    let subtitle: String
    let onApply: (ParamValues) -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    init(model: BleepModel, subtitle: String, onApply: @escaping (ParamValues) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        playback = model.playback
        self.subtitle = subtitle
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: "exclamationmark.bubble", title: "Bleep", subtitle: subtitle)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            BleepTrack(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            HStack(spacing: 8) {
                PreviewPlayButton(title: "Original", playing: playback.isPlaying && playback.playingTag == BleepModel.original) {
                    model.play(BleepModel.original)
                }
                PreviewPlayButton(title: "With Bleeps", playing: playback.isPlaying && playback.playingTag == BleepModel.bleeped,
                                  preparing: model.preparing, accent: true) {
                    model.play(BleepModel.bleeped)
                }
                .disabled(model.regions.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cherry)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer()
                Text(TimeCode.clock(playback.time))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .contentTransition(.numericText(value: playback.time))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            RegionList(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            Divider().opacity(0.5).padding(.top, 16)

            HStack(spacing: 10) {
                Label("Drag across the waveform to add a bleep. Drag its edges to adjust.", systemImage: "hand.draw")
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
                    .disabled(model.regions.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
        .animation(Theme.snappy, value: model.problem)
        .onAppear { model.load() }
    }
}

/// The waveform with bleep regions laid over it.
private struct BleepTrack: View {
    @ObservedObject var model: BleepModel
    @ObservedObject private var playback: Playback
    @State private var drag: Target?
    @State private var hovered: UUID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: BleepModel) {
        self.model = model
        playback = model.playback
    }

    private enum Target: Equatable {
        case create(anchor: Double, id: UUID?)
        case start(UUID), end(UUID)
        case move(UUID, grab: Double, length: Double)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = TimeScale(duration: model.duration, width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    waveform
                        .padding(.vertical, 10)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(scale))
                        .onContinuousHover { phase in hover(phase, scale) }
                    ForEach(model.regions) { region in
                        regionView(region, scale)
                    }
                    if model.duration > 0 && (playback.isPlaying || playback.time > 0) {
                        PlayheadMarker()
                            .frame(height: geo.size.height)
                            .offset(x: scale.x(playback.time) - 4)
                            .transition(.opacity)
                    }
                }
            }
            .frame(height: 136)
            .background(TrackWell(radius: 10) { Color.clear })
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(Theme.ease, value: playback.time > 0)

            TimeRuler(duration: model.duration)
                .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if let waveform = model.waveform {
            WaveformBars(peaks: waveform.mixed, bucketDuration: waveform.bucketDuration, duration: model.duration,
                         highlights: model.regions.map(\.range), highlightColors: WaveformBars.cherry, baseColors: WaveformBars.citrus)
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

    private func regionView(_ region: BleepModel.Region, _ scale: TimeScale) -> some View {
        let x0 = scale.x(region.start)
        let width = max(scale.x(region.end) - x0, 3)
        let active = hovered == region.id || drag.map { isDragging(region.id, $0) } ?? false
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            shape.fill(Theme.cherry.opacity(active ? 0.22 : 0.14))
                .overlay(shape.strokeBorder(Theme.cherry.opacity(active ? 0.95 : 0.7), lineWidth: active ? 1.5 : 1))
                .overlay(alignment: .leading) { grip }
                .overlay(alignment: .trailing) { grip }
                .allowsHitTesting(false)
            if width >= 26 {
                Button { withAnimation(Theme.spring) { model.remove(region.id) } } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 16))
                    .background(Circle().fill(Theme.card(scheme)).padding(1))
                    .padding(4)
                    .opacity(active || width >= 40 ? 1 : 0)
                    .help("Remove this bleep")
            }
        }
        .frame(width: width)
        .offset(x: x0)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .center).combined(with: .opacity))
    }

    private var grip: some View {
        Capsule().fill(Theme.cherry).frame(width: 3, height: 22).padding(.horizontal, 2)
    }

    private func isDragging(_ id: UUID, _ target: Target) -> Bool {
        switch target {
        case .create(_, let created): created == id
        case .start(let dragged), .end(let dragged), .move(let dragged, _, _): dragged == id
        }
    }

    // MARK: Dragging

    private func target(at x: CGFloat, _ scale: TimeScale) -> Target {
        let reach: CGFloat = 6
        // Edges first (nearest wins), so narrow regions can still be resized.
        var best: (Target, CGFloat)?
        for region in model.regions {
            for (edge, distance) in [(Target.start(region.id), abs(x - scale.x(region.start))),
                                     (Target.end(region.id), abs(x - scale.x(region.end)))] where distance <= reach {
                if best == nil || distance < best!.1 { best = (edge, distance) }
            }
        }
        if let best { return best.0 }
        let time = scale.time(x)
        if let region = model.regions.last(where: { $0.range.contains(time) }) {
            return .move(region.id, grab: time - region.start, length: region.end - region.start)
        }
        return .create(anchor: time, id: nil)
    }

    private func dragGesture(_ scale: TimeScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.duration > 0 else { return }
                if drag == nil { drag = target(at: value.startLocation.x, scale) }
                let time = scale.time(value.location.x)
                let moved = abs(value.translation.width) > 3
                switch drag {
                case .create(let anchor, let id):
                    guard moved else { return }
                    if let id {
                        model.update(id) { $0.start = min(anchor, time); $0.end = max(anchor, time) }
                    } else {
                        playback.stop()
                        drag = .create(anchor: anchor, id: model.add(from: anchor, to: time))
                    }
                case .start(let id):
                    NSCursor.resizeLeftRight.set()
                    model.update(id) { $0.start = min(time, $0.end - BleepModel.minimumLength) }
                case .end(let id):
                    NSCursor.resizeLeftRight.set()
                    model.update(id) { $0.end = max(time, $0.start + BleepModel.minimumLength) }
                case .move(let id, let grab, let length):
                    guard moved else { return }
                    NSCursor.closedHand.set()
                    let start = min(max(time - grab, 0), model.duration - length)
                    model.update(id) { $0.start = start; $0.end = start + length }
                case nil:
                    break
                }
            }
            .onEnded { value in
                switch drag {
                case .create(_, nil), .move:
                    // A click: move the playhead there.
                    if abs(value.translation.width) <= 3 { playback.scrub(to: scale.time(value.location.x)) }
                default:
                    break
                }
                drag = nil
                withAnimation(Theme.spring) { model.tidy() }
            }
    }

    private func hover(_ phase: HoverPhase, _ scale: TimeScale) {
        guard case .active(let point) = phase else {
            hovered = nil
            return NSCursor.arrow.set()
        }
        let target = target(at: point.x, scale)
        switch target {
        case .start(let id), .end(let id):
            hovered = id
            NSCursor.resizeLeftRight.set()
        case .move(let id, _, _):
            hovered = id
            NSCursor.openHand.set()
        case .create:
            hovered = nil
            NSCursor.crosshair.set()
        }
    }
}

/// The bleeps as a list: times, length, and a remove button. Clicking a row puts the playhead just before it.
private struct RegionList: View {
    @ObservedObject var model: BleepModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let regions = model.regions.sorted { $0.start < $1.start }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bleeps")
                    .font(.system(size: 12, weight: .semibold))
                if !regions.isEmpty {
                    Text("\(regions.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 16)
                        .background(Capsule().fill(Theme.failure))
                        .contentTransition(.numericText(value: Double(regions.count)))
                }
                Spacer()
                if !regions.isEmpty {
                    Text("\(TimeCode.clock(regions.reduce(0) { $0 + $1.end - $1.start })) bleeped")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.6)

            if regions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.tangerine)
                    Text("No bleeps yet. Drag across the waveform where a word should be covered.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                            RegionRow(index: index + 1, region: region,
                                      select: { model.playback.scrub(to: max(region.start - 1, 0)) },
                                      remove: { withAnimation(Theme.spring) { model.remove(region.id) } })
                                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                .frame(height: min(CGFloat(regions.count) * 34, 34 * 3.5))
            }
        }
        .card(radius: 12)
        .animation(Theme.spring, value: regions.map(\.id))
    }
}

private struct RegionRow: View {
    let index: Int
    let region: BleepModel.Region
    let select: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.cherry)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.cherry.opacity(0.14)))
            Text("\(TimeCode.clock(region.start)) – \(TimeCode.clock(region.end))")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            Text(String(format: "%.2f s", region.end - region.start))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.secondaryText(scheme))
            Spacer()
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(CircleIconButtonStyle(size: 18))
                .help("Remove this bleep")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.primary.opacity(hovering ? 0.04 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Theme.ease, value: hovering)
    }
}
