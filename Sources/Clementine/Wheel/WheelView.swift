import AppKit
import SwiftUI

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = model.canvasSize
        let outer = model.outerRadius
        ZStack {
            if model.actions.isEmpty {
                EmptyNotice(mode: model.mode)
                    .offset(y: model.innerRadius + 26)
                if model.interactive {
                    ModeChip(mode: model.mode, switchable: true, hovered: model.chipHovered)
                        .offset(y: outer + 24)
                }
            } else {
                Backdrop(radius: outer + 8)
                Ring(model: model, size: size)
                    .id("\(model.mode)-\(model.session)")
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.86).combined(with: .opacity),
                        removal: .scale(scale: 1.08).combined(with: .opacity)))
                ModeChip(mode: model.mode, switchable: model.interactive, hovered: model.chipHovered)
                    .offset(y: outer + 24)
            }
            Hub(model: model)
        }
        .frame(width: size, height: size)
        // Reduce Motion: a plain fade, no zoom or blur.
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.8)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible || reduceMotion ? 0 : 8)
        .animation(reduceMotion ? Theme.ease : Theme.spring, value: model.visible)
        .animation(reduceMotion ? Theme.ease : Theme.spring, value: model.mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.mode.title) wheel")
    }
}

/// Frosted disc behind the slices, warmed by a faint tangerine glow.
private struct Backdrop: View {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle().fill(RadialGradient(colors: [Theme.tangerine.opacity(scheme == .dark ? 0.16 : 0.12), .clear],
                                             center: .center, startRadius: radius * 0.35, endRadius: radius)))
            .overlay(Circle().strokeBorder(Theme.hairline(scheme), lineWidth: 1).allowsHitTesting(false))
            .frame(width: radius * 2, height: radius * 2)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 26, y: 12)
    }
}

/// All slices for the current mode. Rebuilt (and cross-faded) when the mode changes.
private struct Ring: View {
    @ObservedObject var model: WheelModel
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                SliceView(model: model, index: index, action: action, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SliceView: View {
    @ObservedObject var model: WheelModel
    let index: Int
    let action: Action
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var hovered: Bool { model.hovered == index }
    private var angle: Double { Double(index) * model.segmentAngle }

    var body: some View {
        let slice = Slice(index: index, count: model.actions.count, inner: model.innerRadius, outer: model.outerRadius)
        // Hovered slices slide outward along their own direction (not under Reduce Motion).
        let pop: CGFloat = hovered && !reduceMotion ? 7 : 0
        let offset = CGSize(width: pop * CGFloat(sin(angle)), height: -pop * CGFloat(cos(angle)))
        let dimmed = model.hovered != nil && !hovered

        ZStack {
            Group {
                if hovered {
                    // Lighter by the hub, deeper at the rim, the same for every slice. Deep enough for white text.
                    let fill = RadialGradient(colors: [Theme.accentTop, Theme.accentBottom], center: .center,
                                              startRadius: model.innerRadius, endRadius: model.outerRadius)
                    slice.fill(fill)
                    slice.stroke(fill, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                } else {
                    slice.fill(Theme.surface(scheme))
                    slice.stroke(Theme.surface(scheme), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                }
            }
            .shadow(color: hovered ? Theme.glow : .clear, radius: 14, y: 4)
            slice.stroke(hovered ? Color.white.opacity(0.35) : Theme.hairline(scheme), lineWidth: 0.75)

            SliceLabel(action: action, mode: model.mode, hovered: hovered, reduceMotion: reduceMotion)
                .position(labelPosition)
        }
        .frame(width: size, height: size)
        .offset(offset)
        .opacity(dimmed ? 0.88 : 1)
        // Fan in one after another when the wheel opens.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
        .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -14))
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? Theme.ease : Theme.snappy, value: hovered)
        .animation(Theme.ease, value: dimmed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.accessibilityName)
        .accessibilityAddTraits(hovered ? [.isButton, .isSelected] : .isButton)
        .onAppear {
            withAnimation(Theme.spring.delay(reduceMotion ? 0 : Double(index) * 0.022)) { appeared = true }
        }
    }

    private var labelPosition: CGPoint {
        let radius = (model.innerRadius + model.outerRadius) / 2 + 4
        return CGPoint(x: size / 2 + radius * CGFloat(sin(angle)), y: size / 2 - radius * CGFloat(cos(angle)))
    }
}

/// A ring segment centered on 12 o'clock + index × (360° / count).
struct Slice: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    /// Wider than the visible gap: the rounded stroke drawn on top eats into it and softens the corners.
    var gap: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = 2 * Double.pi / Double(count)
        let middle = Double(index) * span
        // The stroke grows the shape by 2.5pt on every side, so draw it that much smaller.
        let outerRadius = outer - 2.5, innerRadius = inner + 2.5
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
        }
        // Constant-width gaps: the angular gap shrinks as the radius grows.
        let outerHalf = span / 2 - Double(gap / 2 / outerRadius)
        let innerHalf = span / 2 - Double(gap / 2 / innerRadius)
        let steps = 24
        var path = Path()
        for step in 0...steps {
            let angle = middle - outerHalf + 2 * outerHalf * Double(step) / Double(steps)
            step == 0 ? path.move(to: point(outerRadius, angle)) : path.addLine(to: point(outerRadius, angle))
        }
        for step in 0...steps {
            path.addLine(to: point(innerRadius, middle + innerHalf - 2 * innerHalf * Double(step) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}

private struct SliceLabel: View {
    let action: Action
    let mode: WheelMode
    let hovered: Bool
    var reduceMotion = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            // Formats read best as big text; tools, presets and file actions as an icon with a caption.
            if (mode == .convert && !action.isPreset) || action.symbol == nil {
                Text(action.title)
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .tracking(0.3)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: action.symbol!)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: reduceMotion ? false : hovered)
                        .foregroundStyle(hovered ? Color.white : Theme.accentText)
                    Text(action.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded)) // was 8.5; long names wrap
                        .tracking(0.3)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 62) // narrow enough to stay inside the slice when the hover scales it up
            }
        }
        .foregroundStyle(hovered ? Color.white : (scheme == .dark ? Color(hex: 0xF4E9DF) : Color(hex: 0x4A3628)))
        .shadow(color: hovered ? .black.opacity(0.18) : .clear, radius: 2, y: 1)
        .scaleEffect(hovered && !reduceMotion ? 1.1 : 1)
    }
}

/// The middle: a thumbnail of what's being dragged. Shows what will happen when hovering a slice; dropping here cancels.
private struct Hub: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the hosting window is actually on screen; the wheel's panel lives for the app's whole life.
    @State private var onScreen = false

    private var target: Action? {
        model.hovered.flatMap { $0 < model.actions.count ? model.actions[$0] : nil }
    }

    var body: some View {
        let diameter = (model.innerRadius - 7) * 2
        ZStack {
            Circle().fill(Theme.surface(scheme))
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .scaleEffect(target == nil ? 1 : 1.06)
            }
            // Darken the thumbnail behind the "what happens" caption.
            Circle()
                .fill(.black.opacity(target == nil ? 0 : 0.45))
            caption
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(ring.padding(-3).allowsHitTesting(false))
        .background(WindowVisibilityReader(visible: $onScreen).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .animation(Theme.snappy, value: target?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target?.accessibilityName ?? model.summary)
        .accessibilityHint("Drop or click here to cancel")
    }

    /// The citrus ring slowly turns, but only while the wheel is on screen: a forever animation in the hidden
    /// panel kept the app at a few percent CPU all day. Still under Reduce Motion.
    @ViewBuilder
    private var ring: some View {
        let stroke = Circle().strokeBorder(AngularGradient(colors: [Theme.tangerine, Theme.peach, Theme.blood, Theme.tangerine],
                                                           center: .center), lineWidth: 3)
        if reduceMotion {
            stroke
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !(model.visible && onScreen))) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
                stroke.rotationEffect(.degrees(turn * 360))
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let target {
            VStack(spacing: 1) {
                // File actions name themselves ("Copy Path"), so they get no verb.
                if let verb = Self.verb(for: target) {
                    Text(verb)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .opacity(0.85)
                }
                Text(target.title)
                    .font(.system(size: target.mode == .convert && !target.isPreset ? 17 : 12.5, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .id(target.id)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            VStack {
                Spacer()
                Text(model.summary)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline(scheme), lineWidth: 0.5).allowsHitTesting(false))
                    .padding(.bottom, 11)
            }
            .transition(.opacity)
        }
    }
}

extension Hub {
    static func verb(for action: Action) -> String? {
        switch action.mode {
        case .convert: action.isPreset ? "Apply" : "Convert to"
        case .tools: "Apply"
        case .files: nil
        }
    }
}

/// Says which wheel is up, under the ring. In click mode it's also the switch to the next wheel (or Tab).
private struct ModeChip: View {
    let mode: WheelMode
    var switchable = false
    var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Label(mode == .files ? "FILE" : mode.title.uppercased(), systemImage: Self.symbol(mode))
            if switchable {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .black))
                    .opacity(hovered ? 1 : 0.7)
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.35)).frame(width: 0.75, height: 10) }
            }
        }
        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.accent, in: Capsule())
        // Hover darkens rather than lightens, so the white text keeps its contrast.
        .overlay(Capsule().fill(.black.opacity(hovered ? 0.12 : 0)).allowsHitTesting(false))
        .shadow(color: Theme.glow.opacity(hovered ? 1 : 0.8), radius: hovered ? 9 : 6, y: 2)
        .scaleEffect(hovered && !reduceMotion ? 1.06 : 1)
        .contentTransition(.interpolate)
        .animation(Theme.snappy, value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.title) wheel")
        .accessibilityHint(switchable ? "Click or press Tab to switch to the \(mode.next.title.lowercased()) wheel" : "")
    }

    static func symbol(_ mode: WheelMode) -> String {
        switch mode {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "wand.and.stars"
        case .files: "doc.on.doc"
        }
    }
}

private struct EmptyNotice: View {
    let mode: WheelMode

    var body: some View {
        Label(Self.text(mode), systemImage: "nosign")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    static func text(_ mode: WheelMode) -> String {
        switch mode {
        case .convert: "No conversions for this file"
        case .tools: "No tools for this file"
        case .files: "No file actions for this file"
        }
    }
}

/// Reports whether the hosting window is visible on screen (ordered in and not fully covered), so perpetual
/// animations can stop when nobody can see them.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { visible in
            DispatchQueue.main.async { if self.visible != visible { self.visible = visible } }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return onChange?(false) ?? () }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        self?.report(closing: note.name == NSWindow.willCloseNotification)
                    }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            onChange?(!closing && (window?.occlusionState.contains(.visible) ?? false))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension Action {
    /// What VoiceOver reads for a slice: "Convert to PNG", "Compress".
    var accessibilityName: String { mode == .convert && !isPreset ? "Convert to \(title)" : title }
}
