import AppKit

enum AppIconImage {
    static func load() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIconSource", withExtension: "png") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    static func loadStatusBarImage(blockingEnabled: Bool, size: NSSize) -> NSImage? {
        let resourceName = blockingEnabled ? "TrayIconBlocked" : "TrayIconActive"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png") else {
            return nil
        }

        let image = NSImage(contentsOf: url)
        image?.size = size
        image?.isTemplate = true
        return image
    }
}
