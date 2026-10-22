#if DEBUG
import AppKit
import SwiftUI

extension UITest {
    /// Presets (Save as Preset… in the sheet, Settings › Wheel › Presets) and the ⌃ file actions wheel.
    static var presets: [Suite] {
        [presetSheet, presetSettings, fileWheel]
    }

    /// Points the preset store at a scratch support folder for the suite, so real presets are never touched.
    @MainActor
    private static func isolatedSupport(_ t: UITestContext, _ body: () -> Void) {
        let key = "CLEMENTINE_SUPPORT_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        let folder = t.scratch.appendingPathComponent("support-\(UUID().uuidString)")
        setenv(key, folder.path, 1)
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        body()
    }

    /// Return and Esc belong to the naming row while it's open; outside it they still Apply and Cancel.
    private static var presetSheet: Suite {
        Suite(name: "preset sheet") { t in
            // Suggested names fit a slice's caption without being cut short.
            let withSettings = ActionRegistry.all.filter { !$0.parameters.isEmpty && $0.editor == nil }
            let names = withSettings.map { ($0.id, PresetStore.suggestedName(for: $0, values: $0.defaults)) }
            let long = names.filter { !SliceCaption.fits($0.1) }
            t.check(long.isEmpty, "suggested preset names fit a slice's caption (too long: \(long))")
            t.check(names.first { $0.0 == "tool.compress" }?.1 == "Compress · Balanced", "a name that fits keeps its action")
            if let fit = ActionRegistry.find("tool.fit") {
                var small = fit.defaults
                small.storage["megabytes"] = .number(0.05)
                let name = PresetStore.suggestedName(for: fit, values: small)
                t.check(name == "0.05 MB", "one too long for a slice drops the action (\(name))")
            }

            isolatedSupport(t) {
                guard let fit = ActionRegistry.find("tool.fit") else { return t.check(false, "tool.fit exists") }
                var values = fit.defaults
                values.storage["megabytes"] = .number(10)
                var applied = 0, cancelled = 0
                let form = ParameterForm(action: fit, urls: [t.scratch.appendingPathComponent("clip.mov")], values: values,
                                         onApply: { _ in applied += 1 }, onCancel: { cancelled += 1 })
                let window = t.open(form, size: NSSize(width: 440, height: 260))

                t.click(id: "param.savePreset", in: window)
                t.check(t.wait(2) { t.frame(id: "param.presetName", in: window) != nil }, "Save as Preset… opens a name field")
                t.pressReturn(in: window)
                t.wait(2) { !PresetStore.shared.presets.isEmpty }
                let saved = PresetStore.shared.presets
                t.check(saved.count == 1 && saved.first?.name == "Target Size · 10 MB", "Return saves under the suggested name (\(saved.map(\.name)))")
                t.check(saved.first?.values["megabytes"] == "10", "the sheet's values are saved")
                t.check(applied == 0, "Return while naming doesn't apply the sheet")
                t.check(t.wait(2) { t.frame(id: "param.presetNote", in: window) != nil }, "the sheet says it saved")

                t.click(id: "param.savePreset", in: window)
                t.wait(2) { t.frame(id: "param.presetName", in: window) != nil }
                t.click(id: "param.presetSave", in: window)
                t.check(PresetStore.shared.presets.count == 1, "the same name isn't saved twice")
                t.check(t.frame(id: "param.presetName", in: window) != nil, "the name field stays open to fix the name")
                t.pressEscape(in: window)
                t.check(t.wait(2) { t.frame(id: "param.presetName", in: window) == nil }, "Esc closes the name field")
                t.check(cancelled == 0 && window.isVisible, "…without closing the sheet")

                t.pressReturn(in: window)
                t.check(t.wait(2) { applied == 1 }, "Return applies again once the name field is closed")

                let slices = ActionRegistry.actions(for: [t.makeImage("photo.png", width: 64, height: 64)], mode: .tools).map(\.id)
                if let base = slices.firstIndex(of: "tool.fit"), let id = saved.first?.id {
                    t.check(slices.indices.contains(base + 1) && slices[base + 1] == id, "the preset is a slice right after Target Size")
                } else {
                    t.check(false, "Target Size and its preset are on the image tools wheel (\(slices))")
                }
            }
        }
    }

    /// Rename, reorder, hide and delete from Settings › Wheel.
    private static var presetSettings: Suite {
        Suite(name: "preset settings") { t in
            isolatedSupport(t) {
                let hiddenSaved = HiddenActions.ids
                defer { HiddenActions.ids = hiddenSaved }
                guard let first = try? PresetStore.shared.add(name: "Small", action: "tool.image.resize", values: ["size": "25%"]),
                      let second = try? PresetStore.shared.add(name: "Tiny", action: "tool.compress", values: ["level": "Smallest"])
                else { return t.check(false, "presets can be added") }
                let view = WheelSettingsView(kind: "image", mode: .tools).scrollDisabled(true).fixedSize(horizontal: false, vertical: true).frame(width: 520).background(WindowBackdrop())
                let window = t.open(view, size: NSSize(width: 520, height: 760))
                t.settle(0.8)

                t.click(id: "presets.down.\(first.id)", in: window)
                t.check(PresetStore.shared.presets.map(\.id) == [second.id, first.id], "moving down reorders the presets")

                t.click(id: "presets.shown.\(second.id)", in: window)
                t.check(HiddenActions.ids.contains(second.id), "the eye hides a preset from the wheel")
                let png = t.makeImage("wheel.png", width: 64, height: 64)
                t.check(!ActionRegistry.actions(for: [png], mode: .tools).contains { $0.id == second.id }, "…and the wheel drops it")

                if let field = t.frame(id: "presets.name.\(first.id)", in: window) {
                    t.click(field.center, in: window)
                    if let editor = window.firstResponder as? NSTextView {
                        editor.selectAll(nil)
                        t.type("Half size", in: window)
                        t.pressReturn(in: window)
                        t.wait(2) { PresetStore.shared.presets.contains { $0.name == "Half size" } }
                        t.check(PresetStore.shared.presets.first { $0.id == first.id }?.name == "Half size", "Return renames a preset")
                        t.settle(0.3)
                        t.check(fieldTexts(in: window).contains("Half size"), "…and the row shows the new name (\(fieldTexts(in: window)))")
                    } else {
                        t.check(false, "clicking a preset's name puts the cursor in it")
                    }
                }

                // Tab out of the field: saves like Return, and the row must keep the new name, not the old one.
                if let field = t.frame(id: "presets.name.\(first.id)", in: window) {
                    t.click(field.center, in: window)
                    if let editor = window.firstResponder as? NSTextView {
                        editor.selectAll(nil)
                        t.type("Quarter", in: window)
                        t.key("\t", keyCode: 48, in: window)
                        if window.firstResponder is NSTextView, (window.firstResponder as? NSTextView)?.string == "Quarter" {
                            window.makeFirstResponder(nil) // nothing to Tab to off-screen: leave the field directly
                        }
                        t.wait(2) { PresetStore.shared.presets.contains { $0.name == "Quarter" } }
                        t.check(PresetStore.shared.presets.first { $0.id == first.id }?.name == "Quarter", "Tab out of a name saves it")
                        t.settle(0.5)
                        let texts = fieldTexts(in: window)
                        t.check(texts.contains("Quarter") && !texts.contains("Half size"), "…and the row shows the new name (\(texts))")
                    } else {
                        t.check(false, "clicking a preset's name again puts the cursor in it")
                    }
                }

                t.click(id: "presets.delete.\(second.id)", in: window)
                t.check(PresetStore.shared.presets.map(\.id) == [first.id], "the trash button deletes a preset")
                t.check(!HiddenActions.ids.contains(second.id), "deleting forgets that it was hidden")
            }
        }
    }

    /// What every text field in `window` shows (the field editor's text while one is being edited).
    @MainActor
    private static func fieldTexts(in window: NSWindow) -> [String] {
        func walk(_ view: NSView) -> [String] {
            var found: [String] = []
            if let field = view as? NSTextField, field.isEditable {
                if let editor = field.currentEditor() as? NSTextView { found.append(editor.string) } else { found.append(field.stringValue) }
            }
            return found + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }

    /// The ⌃ rules, the ⌃ wheel's slices, Tab cycling through three wheels, and a copied value on the job card.
    private static var fileWheel: Suite {
        Suite(name: "file actions wheel") { t in
            let defaults = Prefs.defaults
            let saved = defaults.object(forKey: Prefs.controlWheelKey)
            defer { defaults.set(saved, forKey: Prefs.controlWheelKey) }
            defaults.removeObject(forKey: Prefs.controlWheelKey)

            let monitor = DragMonitor()
            let start = Date()
            t.check(monitor.wheel(for: [.shift], now: start) == .convert, "⇧ is the convert wheel")
            t.check(monitor.wheel(for: [.shift, .option], now: start) == .tools, "⌥⇧ is the tools wheel")
            t.check(monitor.wheel(for: [.shift, .control], now: start) == .convert, "⌃⇧ stays the convert wheel")
            t.check(monitor.wheel(for: [.control], now: start) == nil, "⌃ waits a moment (⌃-arrow switches Spaces)")
            t.check(monitor.wheel(for: [.control], now: start.addingTimeInterval(0.1)) == nil, "…still waiting at 0.1 s")
            t.check(monitor.wheel(for: [.control], now: start.addingTimeInterval(0.3)) == .files, "⌃ held 0.3 s is the file actions wheel")
            t.check(monitor.wheel(for: [], now: start.addingTimeInterval(0.4)) == nil, "no keys: no wheel change")
            t.check(monitor.wheel(for: [.control], now: start.addingTimeInterval(0.45)) == nil, "letting go of ⌃ restarts the wait")
            t.check(monitor.wheel(for: [.control, .command], now: start.addingTimeInterval(2)) == nil, "⌃⌘ is left to Finder")
            defaults.set(false, forKey: Prefs.controlWheelKey)
            t.check(monitor.wheel(for: [.control], now: start.addingTimeInterval(5)) == nil, "the Settings switch turns ⌃ off")
            defaults.removeObject(forKey: Prefs.controlWheelKey)

            let png = t.makeImage("file.png", width: 64, height: 64)
            let all = ["file.path", "file.name", "file.sha256", "file.datauri", "file.terminal", "file.reveal", "file.airdrop"]
            t.check(ActionRegistry.candidates(for: [png], mode: .files).map(\.id) == all, "a file gets every file action")
            let folder = ActionRegistry.candidates(for: [t.scratch], mode: .files).map(\.id)
            t.check(!folder.contains("file.sha256") && !folder.contains("file.datauri") && folder.contains("file.terminal"),
                    "a folder gets no hash or data URI")

            // Click mode: Tab walks convert → tools → files → convert. The panel sits off every screen.
            let panel = WheelPanel()
            t.settle(0.5) // drain clicks left from earlier suites: any mouse-down elsewhere dismisses a click-mode wheel
            panel.showClickable(urls: [png], mode: .convert, at: NSPoint(x: -6000, y: 400))
            t.settle(0.5)
            if let window = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("WheelWindow") }),
               let catcher = window.contentView?.subviews.last {
                var seen = [catcher.accessibilityLabel() ?? ""]
                for _ in 0..<3 {
                    t.key("\t", keyCode: 48, in: window)
                    seen.append(catcher.accessibilityLabel() ?? "")
                }
                let wheels = seen.map { $0.components(separatedBy: " wheel").first ?? "" }
                t.check(wheels == ["Convert", "Tools", "File actions", "Convert"], "Tab cycles the three wheels (\(wheels))")
                panel.hide()
                t.settle(0.4)
            } else {
                t.check(false, "the click-mode wheel opens")
            }

            let job = RunningJob(title: "SHA-256", symbol: "number", detail: "Copied to the clipboard")
            job.state = .done
            job.result = String(repeating: "ab", count: 32)
            let card = t.open(JobView(job: job, cancel: {}, dismiss: {}), size: NSSize(width: JobView.width, height: 140))
            t.check(t.frame(id: "job.result.SHA-256", in: card) != nil, "a copied value shows on the finished card")
        }
    }
}
#endif
