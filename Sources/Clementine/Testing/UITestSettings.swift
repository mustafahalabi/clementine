#if DEBUG
import AppKit
import SwiftUI

extension UITest {
    /// Settings on a short screen: the window stops at the cap and the tab scrolls under the header.
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
        }]
    }
}
#endif
