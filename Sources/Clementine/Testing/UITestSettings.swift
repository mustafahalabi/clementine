#if DEBUG
import AppKit
import SwiftUI

extension UITest {
    /// Settings on a short screen (the window stops at the cap and the tab scrolls under the header), and the
    /// parameter sheet's preview and button row.
    static var settings: [Suite] {
        [Suite(name: "settings fit") { t in
            let natural = FirstMouseHostingView(rootView: SettingsView()).fittingSize.height
            let cap: CGFloat = 560
            t.check(natural > cap + 100, "General is taller than the test cap (\(Int(natural)) pt)")
            let capped = FirstMouseHostingView(rootView: SettingsView(fit: SettingsFit(maxHeight: cap))).fittingSize.height
            t.check(abs(capped - cap) < 1, "capped Settings asks for the cap's height (\(Int(capped)) pt)")
            let roomy = FirstMouseHostingView(rootView: SettingsView(fit: SettingsFit(maxHeight: 3000))).fittingSize.height
            t.check(abs(roomy - natural) < 1, "a tall screen keeps the natural height (\(Int(roomy)) pt)")

            let window = t.open(SettingsView(fit: SettingsFit(maxHeight: cap)), size: NSSize(width: 520, height: cap))
            t.settle(0.5)
            guard let before = t.frame(id: "settings.hardwareEncoding", in: window) else {
                return t.check(false, "the hardware encoding row is laid out")
            }
            t.scroll(by: -400, at: t.point(260, cap - 80, in: window), in: window)
            t.wait(2) { (t.frame(id: "settings.hardwareEncoding", in: window)?.rect.minY ?? 0) > before.rect.minY + 50 }
            let after = t.frame(id: "settings.hardwareEncoding", in: window)?.rect.minY ?? before.rect.minY
            t.check(after > before.rect.minY + 50, "the scroll wheel scrolls the form (row moved \(Int(after - before.rect.minY)) pt)")
            t.scroll(by: -400, at: t.point(260, cap - 80, in: window), in: window)
            t.check(t.wait(2) { t.frame(id: "settings.toolsFooter", in: window).map { $0.rect.minY >= 0 } ?? false },
                    "…down to the tools footer")

            // A capped window still follows the tab: Wheel is shorter, so the window shrinks to it and grows back.
            let roomyCap: CGFloat = 900 // under General's natural height, over Wheel's
            let sized = FocusablePanel()
            sized.host(SettingsView(fit: SettingsFit(maxHeight: roomyCap), onTabChange: { SettingsWindow.refit(sized) }))
            t.adopt(sized)
            let general = sized.frame.height
            let titleBar = general - roomyCap // the hosting view adds the title bar on top of the content
            let wheel = FirstMouseHostingView(rootView: SettingsView(tab: .wheel)).fittingSize.height
            t.check(wheel < roomyCap - 50, "Wheel fits under the cap (\(Int(wheel)) pt)")
            if t.click(id: "settings.tab.Wheel", in: sized) {
                t.check(t.wait(3) { abs(sized.frame.height - wheel - titleBar) < 1 },
                        "switching to Wheel shrinks the window to it (\(Int(sized.frame.height)) pt, want \(Int(wheel + titleBar)))")
            }
            if t.click(id: "settings.tab.General", in: sized) {
                t.check(t.wait(3) { abs(sized.frame.height - general) < 1 }, "switching back restores General's height")
            }
        },
        Suite(name: "sheet fit") { t in
            // A flat picture has no subject: the preview says so instead of spinning forever.
            let flat = t.scratch.appendingPathComponent("flat.png")
            if let image = try? ImageEngine.render(width: 320, height: 240, { context in
                context.setFillColor(CGColor(srgbRed: 0.53, green: 0.6, blue: 0.67, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            }), let data = try? ImageEngine.encode(image, format: .png, quality: 1) {
                try? data.write(to: flat)
            }
            guard let cutOut = ActionRegistry.find("tool.image.removebg") else { return t.check(false, "Cut Out Subject exists") }
            let form = ParameterForm(action: cutOut, urls: [flat], values: cutOut.defaults, onApply: { _ in }, onCancel: {})
            let window = t.open(form, size: NSSize(width: 440, height: 520))
            t.check(t.wait(15) { t.frame(id: "param.previewMissing", in: window) != nil }, "Cut Out on a flat picture says no subject was found")

            // Every button in the row is inside the sheet and none overlap.
            let ids = ["param.savePreset", "param.reset"]
            let frames = ids.compactMap { t.frame(id: $0, in: window)?.rect }
            t.check(frames.count == ids.count, "Save as Preset… and Reset are shown")
            if frames.count == 2 {
                t.check(frames[0].maxX <= frames[1].minX && frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 440 },
                        "the button row fits the sheet (\(frames.map { Int($0.width) }))")
            }
        }]
    }
}
#endif
