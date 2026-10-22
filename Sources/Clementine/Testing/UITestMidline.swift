#if DEBUG
import AppKit
import SwiftUI

extension UITest {
    /// Clicks on a control's exact vertical center must land (whole-point clicks on 1× displays hit it often).
    static var midline: [Suite] {
        [Suite(name: "midline") { t in
            final class Hits: ObservableObject { var ids: [String] = [] }
            let hits = Hits()
            struct Row: View {
                let hits: Hits
                @State private var chip = 0
                var body: some View {
                    VStack(alignment: .leading, spacing: 18) {
                        Button("default") { hits.ids.append("default") }.uiTestID("default")
                        Button("pressable") { hits.ids.append("pressable") }.buttonStyle(PressableStyle()).uiTestID("pressable")
                        Button { hits.ids.append("framed") } label: {
                            Text("framed").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(minWidth: 28, minHeight: 26)
                        }
                        .buttonStyle(PressableStyle()).uiTestID("framed")
                        Button { hits.ids.append("capsule") } label: {
                            Text("capsule").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(minWidth: 28, minHeight: 26).contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle()).uiTestID("capsule")
                        Button { hits.ids.append("hstack") } label: {
                            HStack(spacing: 5) {
                                if let symbol = Optional<String>.none { Image(systemName: symbol) }
                                if let label = Optional("hstack") { Text(label).font(.system(size: 12, weight: .semibold)) }
                            }
                            .padding(.horizontal, 10).frame(minWidth: 28, minHeight: 26).contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle()).uiTestID("hstack")
                        Button { hits.ids.append("styled") } label: {
                            Text("styled").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(chip == 0 ? Color.white : Color.primary.opacity(0.8))
                                .padding(.horizontal, 10).frame(minWidth: 28, minHeight: 26).contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle()).uiTestID("styled")
                        ToolTray {
                            Button { hits.ids.append("tray") } label: {
                                Text("tray").font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).frame(minWidth: 28, minHeight: 26).contentShape(Capsule())
                            }
                            .buttonStyle(PressableStyle())
                        }
                        .uiTestID("tray")
                        ChipPicker(items: [.init(value: 0, label: "c0"), .init(value: 1, label: "c1")],
                                   selection: Binding(get: { chip }, set: { chip = $0; hits.ids.append("chip\($0)") }))
                            .uiTestID("chips")
                    }
                    .padding(30)
                }
            }
            let window = t.open(Row(hits: hits), size: NSSize(width: 420, height: 560))
            for id in ["default", "pressable", "framed", "capsule", "hstack", "styled", "tray"] {
                guard let frame = t.frame(id: id, in: window) else { t.check(false, "\(id) found"); continue }
                var results: [String] = []
                for dy in [0.0, 0.3, -0.3, 0.5] {
                    hits.ids.removeAll()
                    t.click(NSPoint(x: frame.rect.midX, y: frame.rect.midY + dy), in: window)
                    results.append(hits.ids.contains(id) ? "✓" : "·")
                }
                print("    \(id) frame \(frame.rect)  center+[0,.3,-.3,.5]: \(results.joined())")
                t.check(results[0] == "✓", "\(id): click on the exact center lands")
            }
            if let chips = t.frame(id: "chips", in: window) {
                hits.ids.removeAll()
                let point = NSPoint(x: chips.rect.maxX - 18, y: chips.rect.midY)
                t.click(point, in: window)
                print("    chips frame \(chips.rect) clicked \(point): \(hits.ids)")
                t.check(hits.ids.contains("chip1"), "chip: click on the exact center lands")
            }
        }]
    }
}
#endif
