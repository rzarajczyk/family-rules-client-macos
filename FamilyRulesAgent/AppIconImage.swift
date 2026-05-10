import AppKit

enum AppIconImage {
    static func load() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIconSource", withExtension: "png") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    static func loadStatusBarImage(blockingEnabled: Bool, size: NSSize) -> NSImage? {
        guard let baseImage = load() else {
            return nil
        }

        let outputImage = NSImage(size: size)
        outputImage.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage.draw(in: NSRect(origin: .zero, size: size))

        if blockingEnabled {
            let badgeDiameter = min(size.width, size.height) * 0.56
            let badgeRect = NSRect(
                x: size.width - badgeDiameter,
                y: size.height - badgeDiameter,
                width: badgeDiameter,
                height: badgeDiameter
            )

            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()

            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
        }

        outputImage.unlockFocus()
        outputImage.isTemplate = false
        return outputImage
    }
}
