import AppKit
import ServiceManagement
import SwiftUI

/// The welcome tour: shown once on first launch, and any time from "Show Welcome…" in the menu.
@MainActor
enum OnboardingWindow {
    static let seenKey = "hasSeenOnboarding"
    private static var window: FocusablePanel?

    /// Opens the tour unless it has been shown before. Marked as seen right away so it never nags twice.
    static func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        UserDefaults.standard.set(true, forKey: seenKey)
        // Let the menu bar item settle first so the window doesn't race the app's launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { show() }
    }

    static func show() {
        if window == nil {
            let window = FocusablePanel()
            window.title = "Welcome to Clementine" // hidden, but used by Mission Control and VoiceOver
            window.host(OnboardingView(onFinish: { OnboardingWindow.window?.close() }))
            window.center()
            self.window = window
        }
        window?.present()
    }
}

// MARK: - Content

struct OnboardingView: View {
    var onFinish: () -> Void = {}
    /// Rendering hooks: start on a given page, and freeze the demo instead of animating it.
    var initialStep = 0
    var live = true

    @State private var step: Int
    @State private var forward = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let pageCount = 3

    init(onFinish: @escaping () -> Void = {}, initialStep: Int = 0, live: Bool = true) {
        self.onFinish = onFinish
        self.initialStep = initialStep
        self.live = live
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(for: step)
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
                .padding(.top, 6)
        }
        .frame(width: 600, height: 600)
        .background(WindowBackdrop())
        .tint(Theme.tangerine)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let enter: Edge = forward ? .trailing : .leading
        let exit: Edge = forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: enter).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
            removal: .move(edge: exit).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
    }

    @ViewBuilder
    private func page(for step: Int) -> some View {
        switch step {
        case 0:
            OnboardingPage(
                eyebrow: "Welcome to Clementine",
                title: "Hold ⇧ while dragging a file",
                text: "Start dragging any file from Finder or the desktop, then press Shift. A wheel of formats opens under your pointer. Drop on one to convert.",
                keys: ["⇧"]
            ) {
                DemoWheel(mode: .convert, live: live)
            }
        case 1:
            OnboardingPage(
                eyebrow: "Tools",
                title: "Hold ⌥⇧ for the tools wheel",
                text: "Add Option and the wheel fills with tools for that kind of file: compress, resize, trim, merge and more. Drop on the middle to cancel.",
                keys: ["⌥", "⇧"]
            ) {
                DemoWheel(mode: .tools, live: live)
            }
        default:
            OnboardingPage(
                eyebrow: "Results",
                title: "New files land next to the original",
                text: "The converted copy appears right beside your file, and the original is never touched.",
                keys: []
            ) {
                ResultDemo(live: live)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            if step == Self.pageCount - 1 {
                FinishOptions()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Button("Back") { go(-1) }
                    .buttonStyle(SoftButtonStyle())
                    .opacity(step == 0 ? 0 : 1)
                    .disabled(step == 0)
                Spacer()
                PageDots(count: Self.pageCount, current: step) { target in
                    forward = target > step
                    withAnimation(Theme.spring) { step = target }
                }
                Spacer()
                Button {
                    if step == Self.pageCount - 1 { onFinish() } else { go(1) }
                } label: {
                    Text(step == Self.pageCount - 1 ? "Get Started" : "Next")
                        .frame(minWidth: 84)
                        .contentTransition(.interpolate)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .animation(Theme.spring, value: step)
    }

    private func go(_ delta: Int) {
        let target = min(max(step + delta, 0), Self.pageCount - 1)
        guard target != step else { return }
        forward = delta > 0
        withAnimation(Theme.spring) { step = target }
    }
}

/// One page: an illustration on top, then the copy.
private struct OnboardingPage<Hero: View>: View {
    let eyebrow: String
    let title: String
    let text: String
    let keys: [String]
    @ViewBuilder let hero: () -> Hero
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            hero()
                .frame(height: 340)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            VStack(spacing: 9) {
                HStack(spacing: 6) {
                    ForEach(keys, id: \.self) { Keycap(key: $0) }
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Theme.accent)
                }
                Text(title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
    }
}

/// Dots that stretch into a pill for the current page; click one to jump there.
private struct PageDots: View {
    let count: Int
    let current: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .frame(width: index == current ? 22 : 7, height: 7)
                    .shadow(color: index == current ? Theme.glow : .clear, radius: 4, y: 1)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { select(index) }
                    .accessibilityLabel("Page \(index + 1) of \(count)")
            }
        }
        .animation(Theme.spring, value: current)
    }
}

/// Launch-at-login switch and the privacy promise, on the last page.
private struct FinishOptions: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                GradientBadge(symbol: "lock.shield.fill", size: 30, fill: Theme.success, glow: Theme.leaf.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Private by design").font(.system(size: 12.5, weight: .semibold))
                    Text("Everything runs on your Mac. Nothing is uploaded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
                Spacer()
                Divider().frame(height: 28)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5, weight: .medium))
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .card(radius: 14)
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.cherry)
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Clementine in System Settings › General › Login Items." : nil
        } catch {
            loginError = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if launchAtLogin != actual { launchAtLogin = actual }
    }
}

// MARK: - Live wheel demo

/// The real WheelView with a demo model, a pointer gliding from slice to slice as if someone were choosing.
private struct DemoWheel: View {
    let mode: WheelMode
    var live = true
    @StateObject private var model = WheelModel()
    @State private var pointer = CGPoint(x: 70, y: 70)
    @State private var pressed = false

    private let scale: CGFloat = 0.8
    /// Slices to visit, with a pause over the hub (nil) now and then.
    private var tour: [Int?] {
        mode == .convert ? [2, 3, 5, nil, 0, 7, 4, nil] : [0, 2, 4, nil, 6, 1, 5, nil]
    }

    var body: some View {
        ZStack {
            WheelView(model: model)
                .scaleEffect(scale)
                .allowsHitTesting(false)
            DemoPointer(pressed: pressed)
                .offset(x: pointer.x, y: pointer.y)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: pointer)
            HoldChip(keys: mode == .convert ? ["⇧"] : ["⌥", "⇧"], pressed: pressed)
                .offset(x: -170, y: -128)
        }
        .frame(width: model.canvasSize * scale, height: model.canvasSize * scale)
        .onAppear(perform: setUp)
        .task(id: live) { await runTour() }
    }

    private func setUp() {
        model.loadDemo(actions: Self.actions(for: mode), mode: mode,
                       summary: mode == .convert ? "Lisbon.heic" : "2.4 MB", thumbnail: DemoArt.photo)
        model.visible = true
        pressed = true
        if !live { point(at: tour[0]) }
    }

    private func runTour() async {
        guard live else { return }
        try? await Task.sleep(nanoseconds: 700_000_000) // let the slices fan in first
        var index = 0
        while !Task.isCancelled {
            point(at: tour[index % tour.count])
            index += 1
            try? await Task.sleep(nanoseconds: 950_000_000)
        }
    }

    private func point(at slice: Int?) {
        model.hovered = slice
        guard let slice, !model.actions.isEmpty else {
            pointer = CGPoint(x: 18, y: 22) // resting on the hub
            return
        }
        let angle = Double(slice) * model.segmentAngle
        let radius = (model.innerRadius + model.outerRadius) / 2 * scale + 6
        pointer = CGPoint(x: radius * CGFloat(sin(angle)) + 8, y: -radius * CGFloat(cos(angle)) + 12)
    }

    /// Real catalog entries (so titles and symbols match the app), shown without any files behind them.
    static func actions(for mode: WheelMode) -> [Action] {
        let ids = mode == .convert
            ? ["convert.image.jpeg", "convert.image.png", "convert.image.webp", "convert.image.heic",
               "convert.image.avif", "convert.image.pdf", "convert.image.gif", "convert.image.tiff"]
            : ["tool.compress", "tool.image.resize", "tool.image.crop", "tool.image.rotate",
               "tool.image.adjust", "tool.image.background", "tool.fit", "tool.metadata.strip"]
        return ids.compactMap(ActionRegistry.find)
    }
}

/// A macOS-style arrow pointer carrying a little file, dipping when "pressed".
private struct DemoPointer: View {
    let pressed: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white)
                .overlay(Image(nsImage: DemoArt.photo).resizable().aspectRatio(contentMode: .fill).padding(2.5)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous)))
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .offset(x: 10, y: 14)
                .opacity(0.92)
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 22, weight: .black)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .scaleEffect(pressed ? 0.96 : 1, anchor: .topLeading)
        .frame(width: 44, height: 48, alignment: .topLeading)
        .offset(x: 22 - 4, y: 24 - 2) // put the arrow's tip at the view's center
        .allowsHitTesting(false)
    }
}

/// "Hold ⇧" in keycaps, gently pulsing to say the keys stay down.
private struct HoldChip: View {
    let keys: [String]
    let pressed: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Text("Hold").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { Keycap(key: $0).scaleEffect(pulse ? 0.94 : 1).offset(y: pulse ? 1 : 0) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .card(radius: 100)
        .shadow(color: Theme.glow.opacity(0.35), radius: 10, y: 3)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Results demo

/// A Finder-ish folder: the original sits there, and its converted twin pops in beside it, on a loop.
private struct ResultDemo: View {
    var live = true
    @State private var shown = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Window chrome
                HStack(spacing: 6) {
                    ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) {
                        Circle().fill($0).frame(width: 10, height: 10)
                    }
                    Spacer()
                    Label("Holiday", systemImage: "folder.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Color.clear.frame(width: 42, height: 1)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.03))
                Divider()
                HStack(alignment: .top, spacing: 26) {
                    FileTile(name: "Lisbon.heic", size: "3.1 MB", badge: "HEIC", highlighted: false)
                    ZStack {
                        if shown {
                            FileTile(name: "Lisbon.webp", size: "640 KB", badge: "WEBP", highlighted: true)
                                .transition(.asymmetric(insertion: .scale(scale: 0.4, anchor: .leading).combined(with: .opacity),
                                                        removal: .opacity))
                        } else {
                            FileTile(name: " ", size: " ", badge: "", highlighted: false).hidden()
                        }
                    }
                    FileTile(name: "Notes.txt", size: "2 KB", badge: "TXT", highlighted: false, symbol: "doc.text.fill")
                        .opacity(0.55)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 26)
            }
            .card(radius: 14)
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 22, y: 10)
            .frame(width: 430)

            if shown {
                Label("Converted next to the original", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Theme.success, in: Capsule())
                    .shadow(color: Theme.leaf.opacity(0.5), radius: 8, y: 3)
                    .offset(y: 118)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: live) {
            guard live else { shown = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { shown = true }
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(Theme.ease) { shown = false }
            }
        }
    }
}

private struct FileTile: View {
    let name: String
    let size: String
    let badge: String
    let highlighted: Bool
    var symbol: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 46))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .frame(width: 84, height: 84)
                    } else {
                        Image(nsImage: DemoArt.photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 2).allowsHitTesting(false))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    }
                }
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.gray), in: Capsule())
                        .offset(x: 6, y: 4)
                }
            }
            VStack(spacing: 1) {
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(highlighted ? AnyShapeStyle(Theme.tangerine.opacity(0.85)) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(highlighted ? .white : .primary)
                Text(size).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 100)
    }
}

/// A little sunset "photo", drawn once, used as the demo file's thumbnail.
@MainActor
enum DemoArt {
    static let photo: NSImage = {
        let side: CGFloat = 240
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let sky = NSGradient(colors: [NSColor(Theme.blood), NSColor(Theme.tangerine), NSColor(Theme.peach)])!
            sky.draw(in: rect, angle: 90 + 180)
            NSColor(Color(hex: 0xFFF1DC)).withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: side * 0.56, y: side * 0.52, width: side * 0.24, height: side * 0.24)).fill()
            let far = NSBezierPath()
            far.move(to: NSPoint(x: 0, y: side * 0.32))
            far.line(to: NSPoint(x: side * 0.30, y: side * 0.58))
            far.line(to: NSPoint(x: side * 0.52, y: side * 0.38))
            far.line(to: NSPoint(x: side * 0.72, y: side * 0.50))
            far.line(to: NSPoint(x: side, y: side * 0.30))
            far.line(to: NSPoint(x: side, y: 0))
            far.line(to: .zero)
            NSColor(Color(hex: 0x8A3B2C)).withAlphaComponent(0.85).setFill()
            far.fill()
            let near = NSBezierPath()
            near.move(to: NSPoint(x: 0, y: side * 0.18))
            near.curve(to: NSPoint(x: side, y: side * 0.22),
                       controlPoint1: NSPoint(x: side * 0.35, y: side * 0.34), controlPoint2: NSPoint(x: side * 0.65, y: side * 0.08))
            near.line(to: NSPoint(x: side, y: 0))
            near.line(to: .zero)
            NSColor(Color(hex: 0x4A2420)).setFill()
            near.fill()
            _ = rect
            return true
        }
    }()
}
