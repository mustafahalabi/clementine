#if DEBUG
import AppKit
import SwiftUI

extension UITest {
    /// Job cards, the welcome tour's "seen" flag, accent contrast and error copy.
    static var firstRun: [Suite] {
        [jobCards, onboardingSeen, contrast, errorCopy]
    }

    /// A failed card is taller than a running one and stays open; the next card must stack below it, not on it.
    private static var jobCards: Suite {
        Suite(name: "job cards") { t in
            ProgressPanel.stackArea = NSRect(x: -8000, y: 200, width: 1200, height: 1400)
            defer { ProgressPanel.stackArea = nil }

            let failed = RunningJob(title: "First", symbol: "film", detail: "take 1.mov")
            let first = ProgressPanel.show(failed)
            let message = (1...6).map { "take \($0).mov: The file looks damaged, or isn't in a format that can be read." }
                .joined(separator: "\n")
            failed.state = .failed(message)
            t.settle(0.8)
            let running = RunningJob(title: "Second", symbol: "photo", detail: "photo.heic")
            let second = ProgressPanel.show(running)
            t.settle(0.8)

            @MainActor func screenRect(_ id: String, in window: NSWindow) -> NSRect? {
                t.frame(id: id, in: window).map { $0.rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY) }
            }
            @MainActor func checkClear(_ when: String) {
                print("    first \(first.window.frame)  second \(second.window.frame)")
                let close = screenRect("job.close.First", in: first.window)
                t.check(close != nil, "\(when): the failed card's Close button is on screen")
                if let close {
                    t.check(!second.window.frame.intersects(close), "\(when): the second card doesn't cover Close")
                }
                t.check(!second.window.frame.intersects(first.window.frame), "\(when): the cards don't overlap")
                t.check(second.window.frame.maxY < first.window.frame.minY, "\(when): the second card sits below the first")
            }
            checkClear("collapsed")
            t.check(first.window.frame.height < 260, "a long error is capped (card \(Int(first.window.frame.height)) pt tall)")

            if t.frame(id: "job.details.First", in: first.window) != nil {
                let before = first.window.frame.height
                t.click(id: "job.details.First", in: first.window)
                t.wait(2) { first.window.frame.height > before + 10 }
                t.settle(0.5)
                t.check(first.window.frame.height > before, "Show details… opens the full message")
                checkClear("expanded")
            } else {
                t.check(false, "a long error offers Show details…")
            }

            first.close()
            second.close()
            t.settle(0.6)
        }
    }

    /// The tour only counts as seen once it has been on screen and closed.
    private static var onboardingSeen: Suite {
        Suite(name: "onboarding seen") { t in
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: OnboardingWindow.seenKey)
            defer { defaults.set(saved, forKey: OnboardingWindow.seenKey) }
            defaults.removeObject(forKey: OnboardingWindow.seenKey)

            // prepare() is show() minus presenting, which would activate the app on the real screen.
            let window = OnboardingWindow.prepare()
            t.check(!OnboardingWindow.completed, "not marked seen before the tour is shown")
            t.adopt(window)
            t.check(!OnboardingWindow.completed, "not marked seen while it's open")
            t.pressEscape(in: window)
            t.wait(2) { OnboardingWindow.completed }
            t.check(OnboardingWindow.completed, "closing the tour marks it seen")
        }
    }

    /// White text on the accent fills: ≥ 3:1 (bold labels) normally, ≥ 7:1 with Increase Contrast.
    private static var contrast: Suite {
        Suite(name: "accent contrast") { t in
            func luminance(_ hex: UInt32) -> Double {
                func channel(_ byte: UInt32) -> Double {
                    let v = Double(byte & 0xFF) / 255
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
            }
            func ratio(_ a: UInt32, _ b: UInt32) -> Double {
                let (la, lb) = (luminance(a), luminance(b))
                return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
            }
            let white: UInt32 = 0xFFFFFF, cream: UInt32 = 0xFFFBF6, charcoal: UInt32 = 0x2B2420
            for (name, shade) in [("top", Theme.accentTopShade), ("bottom", Theme.accentBottomShade)] {
                for dark in [false, true] {
                    let normal = ratio(shade.hex(dark: dark, increased: false), white)
                    let high = ratio(shade.hex(dark: dark, increased: true), white)
                    let mode = dark ? "dark" : "light"
                    t.check(normal >= 3, "white on accent \(name), \(mode) (bold labels): \(String(format: "%.2f", normal)):1")
                    t.check(high >= 7, "white on accent \(name), \(mode), Increase Contrast: \(String(format: "%.2f", high)):1")
                }
            }
            let deep = ratio(Theme.accentDeepShade.hex(dark: false, increased: false), white)
            t.check(deep >= 4.5, "white regular text on the deep accent: \(String(format: "%.2f", deep)):1")
            let text = Theme.accentTextShade
            t.check(ratio(text.hex(dark: false, increased: false), cream) >= 3, "accent glyphs and bold labels on cream ≥ 3:1")
            t.check(ratio(text.hex(dark: true, increased: false), charcoal) >= 4.5, "accent text on charcoal ≥ 4.5:1")
            t.check(ratio(text.hex(dark: false, increased: true), cream) >= 7, "accent text on cream ≥ 7:1 with Increase Contrast")
            t.check(ratio(text.hex(dark: true, increased: true), charcoal) >= 7, "accent text on charcoal ≥ 7:1 with Increase Contrast")
            // The dynamic color really resolves to these values.
            var resolved: NSColor?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                resolved = NSColor(Theme.accentTop).usingColorSpace(.sRGB)
            }
            let expected = Theme.accentTopShade.hex(dark: false, increased: Theme.increaseContrast)
            t.check(resolved.map { abs($0.redComponent - CGFloat(expected >> 16) / 255) < 0.01 } ?? false,
                    "the accent resolves from its shade table")
        }
    }

    /// Brew hints only where the tools aren't bundled; ffmpeg failures lead with a plain sentence.
    private static var errorCopy: Suite {
        Suite(name: "error copy") { t in
            t.check(ClementineError.missingToolMessage("img2webp", bundled: false).contains("brew install webp"),
                    "img2webp's hint is brew install webp")
            t.check(ClementineError.missingToolMessage("ffprobe", bundled: false).contains("brew install ffmpeg"),
                    "ffprobe's hint is brew install ffmpeg")
            t.check(!ClementineError.missingToolMessage("ffmpeg", bundled: true).contains("brew"),
                    "no brew hint when the tools are bundled")
            let message = ClementineError.toolFailed("ffmpeg", "[mov @ 0x1] moov atom not found\nbroken.mp4: Invalid data found when processing input")
                .localizedDescription
            t.check(message.hasPrefix("The file looks damaged"), "ffmpeg failure leads with a plain sentence")
            t.check(message.contains("broken.mp4"), "ffmpeg's own words are kept below it")
            t.check(Action.accessibilityProbe == "Convert to Text (OCR)", "the OCR slice reads as Text (OCR)")
        }
    }
}

private extension Action {
    static var accessibilityProbe: String? { ActionRegistry.find("convert.image.txt")?.accessibilityName }
}
#endif
