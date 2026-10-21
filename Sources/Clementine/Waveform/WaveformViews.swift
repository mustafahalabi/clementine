import AVFoundation
import AppKit
import SwiftUI

// MARK: Time

extension TimeCode {
    /// `41.74` → `0:41.74`, `3723.5` → `1:02:03.50`.
    static func clock(_ seconds: Double, decimals: Int = 2) -> String {
        let value = max(seconds, 0)
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        let whole = Int(rounded)
        let fraction = decimals > 0 ? String(format: "%0\(decimals + 1).\(decimals)f", rounded - Double(whole)).dropFirst() : ""
        let (h, m, s) = (whole / 3600, whole / 60 % 60, whole % 60)
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return base + fraction
    }
}

/// Maps between seconds and points along a track.
struct TimeScale {
    let duration: Double
    let width: CGFloat

    func x(_ time: Double) -> CGFloat { duration > 0 ? CGFloat(time / duration) * width : 0 }
    func time(_ x: CGFloat) -> Double { width > 0 ? min(max(Double(x / width) * duration, 0), duration) : 0 }
    /// Seconds per point.
    var resolution: Double { width > 0 ? duration / Double(width) : 0 }
}

// MARK: Waveform drawing

/// Mirrored min/max bars. Bars whose middle falls inside `highlights` get the citrus gradient, the rest a quiet neutral.
struct WaveformBars: View {
    let peaks: [Waveform.Peak]
    let bucketDuration: Double
    let duration: Double
    var highlights: [ClosedRange<Double>] = []
    var highlightColors: [Color] = WaveformBars.citrus
    /// Colors for the other bars; nil draws them in a quiet neutral.
    var baseColors: [Color]? = nil
    var gain: Float = 1
    /// Peak that fills the full height; defaults to the loudest one so quiet recordings still read.
    var reference: Float? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, duration > 0 else { return }
            let step: CGFloat = 3
            let bar: CGFloat = 2
            let full = max(reference ?? peaks.lazy.map(\.magnitude).max() ?? 1, 0.02)
            let mid = size.height / 2
            let half = mid - 1
            var inside = Path()
            var outside = Path()
            var x: CGFloat = 0
            while x < size.width {
                let t0 = Double(x / size.width) * duration
                let t1 = Double((x + step) / size.width) * duration
                let b0 = min(Int(t0 / bucketDuration), peaks.count - 1)
                let b1 = min(max(Int(t1 / bucketDuration), b0 + 1), peaks.count)
                var low: Float = 0
                var high: Float = 0
                for peak in peaks[b0..<b1] {
                    low = min(low, peak.low)
                    high = max(high, peak.high)
                }
                let top = mid - CGFloat(min(high * gain / full, 1)) * half
                let bottom = mid - CGFloat(max(low * gain / full, -1)) * half
                let height = max(bottom - top, 1)
                let rect = CGRect(x: x, y: min(top, mid - 0.5), width: bar, height: height)
                let middle = (t0 + t1) / 2
                if highlights.contains(where: { $0.contains(middle) }) {
                    inside.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                } else {
                    outside.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                }
                x += step
            }
            func gradient(_ colors: [Color]) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            }
            context.fill(outside, with: baseColors.map(gradient) ?? .color(Color.primary.opacity(scheme == .dark ? 0.28 : 0.22)))
            context.fill(inside, with: gradient(highlightColors))
        }
    }
}

extension WaveformBars {
    /// Tangerine at the centre line fading to peach at the tips.
    static let citrus = [Theme.peach, Theme.tangerine, Theme.blood, Theme.tangerine, Theme.peach]
    /// Cherry for sound that will be covered by a bleep.
    static let cherry = [Color(hex: 0xFFB3B5), Color(hex: 0xFF7A7E), Theme.cherry, Color(hex: 0xFF7A7E), Color(hex: 0xFFB3B5)]
}

/// Stand-in bars with a light sweeping across while the real waveform is read.
struct WaveformShimmer: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Canvas { context, size in
                let step: CGFloat = 3
                let mid = size.height / 2
                let band = (phase * 1.6 - 0.3) * size.width
                var x: CGFloat = 0
                var index = 0
                while x < size.width {
                    // Deterministic speech-like envelope so the placeholder doesn't flicker between frames.
                    let i = Double(index)
                    let envelope = 0.35 + 0.3 * sin(i * 0.045) + 0.18 * sin(i * 0.31 + 1) + 0.12 * sin(i * 1.7)
                    let height = max(CGFloat(envelope) * (size.height - 8), 2)
                    let glow = max(0, 1 - abs(x - band) / 90)
                    let opacity = (scheme == .dark ? 0.10 : 0.08) + glow * (scheme == .dark ? 0.16 : 0.14)
                    context.fill(Path(roundedRect: CGRect(x: x, y: mid - height / 2, width: 2, height: height), cornerRadius: 1),
                                 with: .color(Color.primary.opacity(opacity)))
                    x += step
                    index += 1
                }
            }
        }
    }
}

/// The recessed rounded well the tracks sit in, matching the parameter sheet's preview pane.
struct TrackWell<Content: View>: View {
    var radius: CGFloat = 12
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(scheme == .dark ? Color.black.opacity(0.35) : Color(hex: 0xF1E9E0)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.edge(scheme), lineWidth: 1))
    }
}

/// Seconds along the bottom of a track, with labels at a spacing that suits the length.
struct TimeRuler: View {
    let duration: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let major = steps.first { CGFloat($0 / duration) * size.width >= 64 } ?? steps.last!
            let divisions = switch major {
            case 15, 30, 900, 1800: 3
            case 2, 60, 120, 3600, 7200: 4
            default: 5
            }
            let minor = major / Double(divisions)
            let scale = TimeScale(duration: duration, width: size.width)
            let tick = Color.primary.opacity(0.22)
            var index = 0
            while Double(index) * minor <= duration + 1e-6 {
                let t = Double(index) * minor
                let x = scale.x(t).rounded() + 0.5
                let isMajor = index % divisions == 0
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: isMajor ? 6 : 3)), with: .color(tick))
                if isMajor && x < size.width - 24 {
                    let label = Text(TimeCode.clock(t, decimals: major < 1 ? (major < 0.5 ? 2 : 1) : 0))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText(scheme).opacity(0.8))
                    context.draw(label, at: CGPoint(x: x + 3, y: 7), anchor: .topLeading)
                }
                index += 1
            }
        }
        .frame(height: 20)
    }
}

/// The line that follows playback.
struct PlayheadMarker: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = scheme == .dark ? Color.white : Color(hex: 0x3B2416)
        VStack(spacing: 0) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            Rectangle().fill(color).frame(width: 1.5)
        }
        .shadow(color: (scheme == .dark ? Theme.blood : Color.white).opacity(0.7), radius: 3)
        .frame(width: 8)
        .allowsHitTesting(false)
    }
}

/// A row of video frames.
struct Filmstrip: View {
    let frames: [CGImage]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { index in
                    Image(decorative: frames[index], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width / CGFloat(max(frames.count, 1)), height: geo.size.height)
                        .clipped()
                }
            }
            .transition(.opacity)
        }
        .background(Color.black.opacity(scheme == .dark ? 0.4 : 0.12))
        .animation(Theme.ease, value: frames.count)
    }
}

enum FilmstripLoader {
    /// `count` evenly spaced frames, or none when AVFoundation can't read the video.
    static func frames(_ url: URL, count: Int, height: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        let slack = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var images: [CGImage] = []
        // One at a time, in order, so a cancelled editor stops promptly.
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if Task.isCancelled { break }
            guard let image = try? await generator.image(at: time).image else { continue }
            images.append(image)
        }
        return images
    }
}

extension FilmstripLoader {
    /// A single exact frame, for the video preview's poster.
    static func frame(_ url: URL, at seconds: Double, height: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

// MARK: Controls

/// A segmented control in the app's style: a gradient capsule slides to the chosen option.
struct CitrusSegmented: View {
    let options: [(title: String, symbol: String)]
    @Binding var selection: Int
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let selected = index == selection
                Button {
                    withAnimation(Theme.snappy) { selection = index }
                } label: {
                    Label(options[index].title, systemImage: options[index].symbol)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accent)
                                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)))
                                    .shadow(color: Theme.glow.opacity(0.4), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)))
        .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1))
    }
}

/// A play/stop button for one version of the sound, showing a spinner while its preview renders.
struct PreviewPlayButton: View {
    let title: String
    let playing: Bool
    var preparing = false
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if preparing {
                        ProgressView().controlSize(.mini).tint(accent ? .white : nil)
                    } else {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 14)
                Text(title)
            }
        }
        .modifier(PlayButtonStyle(accent: accent))
        .animation(Theme.snappy, value: playing)
        .animation(Theme.snappy, value: preparing)
    }

    private struct PlayButtonStyle: ViewModifier {
        let accent: Bool

        func body(content: Content) -> some View {
            if accent { content.buttonStyle(AccentButtonStyle()) } else { content.buttonStyle(SoftButtonStyle()) }
        }
    }
}

/// A time that can be typed over: shows `0:41.74`, accepts anything `TimeCode` reads, and reverts if it can't.
struct TimeField: View {
    let label: String
    let seconds: Double
    var alignment: HorizontalAlignment = .leading
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryText(scheme))
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .focused($focused)
                .frame(width: 92)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.0 : 0.05)))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.card(scheme)).opacity(focused ? 1 : 0))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(invalid ? Theme.cherry : (focused ? Theme.tangerine : Theme.edge(scheme)), lineWidth: focused || invalid ? 1.5 : 1))
                .onSubmit(apply)
                .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
        }
        .onAppear { text = TimeCode.clock(seconds) }
        .onChange(of: seconds) { _, value in if !focused { text = TimeCode.clock(value) } }
        .animation(Theme.ease, value: focused)
        .animation(Theme.ease, value: invalid)
    }

    private func apply() {
        if let value = TimeCode.seconds(text) {
            invalid = false
            if abs(value - seconds) >= 0.005 { commit(value) }
            text = TimeCode.clock(seconds)
        } else {
            invalid = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                invalid = false
                text = TimeCode.clock(seconds)
            }
        }
    }
}

/// Small rounded caption, used for "L"/"R" lane tags and counts.
struct LaneTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(Color.black.opacity(0.32)))
    }
}

// MARK: Window

/// Opens an editor in a floating panel and runs `onClose` when it goes away (to stop playback and delete previews).
@MainActor
enum EditorWindow {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func present<Content: View>(title: String, onClose: @escaping @MainActor () -> Void,
                                       content: (_ close: @escaping () -> Void) -> Content) {
        let window = FocusablePanel()
        window.title = title
        window.host(content({ [weak window] in window?.close() }))
        window.center()
        windows.append(window)
        let id = ObjectIdentifier(window)
        observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { ObjectIdentifier($0) == id }
                if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
                onClose()
            }
        }
        window.present()
    }
}

/// Header subtitle for editors that show the first of several files.
func editorSubtitle(_ urls: [URL], note: String) -> String {
    urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) and \(urls.count - 1) more · \(note)"
}
