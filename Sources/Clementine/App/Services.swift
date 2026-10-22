import AppKit

/// Finder › right-click › Services › "Convert with Clementine" / "Clementine Tools" / "Clementine File Actions".
/// The entries are declared under NSServices in Info.plist; each one opens the click-mode wheel at the pointer.
@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices() // pick up new or changed NSServices entries without logging out
    }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        show(pasteboard, mode: .convert, error: error)
    }

    @objc func toolFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        show(pasteboard, mode: .tools, error: error)
    }

    @objc func fileActions(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        show(pasteboard, mode: .files, error: error)
    }

    private func show(_ pasteboard: NSPasteboard, mode: WheelMode, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were selected." as NSString
            return
        }
        WheelController.shared.showClickable(urls, mode: mode)
    }
}
