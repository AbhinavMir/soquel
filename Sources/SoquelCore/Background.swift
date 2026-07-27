import AppKit

/// How a background image fills the pane.
enum BackgroundFit: String, Codable, CaseIterable {
    case fill, fit, stretch, tile, center

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .tile: return "Tile"
        case .center: return "Centre"
        }
    }
}

/// A background image behind the file list, with its own opacity so text stays
/// readable. Stored beside the theme so a look can be shared as one folder.
struct BackgroundConfig: Codable, Equatable {
    /// Absolute path. Kept as a path rather than a bookmark so the JSON stays
    /// readable and portable; a missing file simply means no background.
    var imagePath: String?
    /// 0 = invisible, 1 = full strength. Defaults low because a file list has
    /// to stay legible on top of it.
    var opacity: Double
    var fit: BackgroundFit
    /// Applies the image to the sidebar too, not just the file panes.
    var includeSidebar: Bool

    static let none = BackgroundConfig(imagePath: nil, opacity: 0.15, fit: .fill, includeSidebar: false)

    var imageURL: URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)
    }

    /// Clamped so a stored value outside the range cannot make the list
    /// unreadable or the image invisible-but-present.
    var effectiveOpacity: CGFloat {
        CGFloat(min(max(opacity, 0), 1))
    }
}

/// Draws the background image, honouring the fit mode and opacity.
final class BackgroundImageView: NSView {
    private var image: NSImage?
    private var fit: BackgroundFit = .fill
    private var alpha: CGFloat = 0

    override var isFlipped: Bool { true }

    func apply(_ config: BackgroundConfig, cache: BackgroundImageCache) {
        alpha = config.effectiveOpacity
        fit = config.fit
        image = config.imageURL.flatMap { cache.image(for: $0) }
        isHidden = image == nil || alpha <= 0.001
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, alpha > 0 else { return }
        let target = bounds
        guard target.width > 0, target.height > 0 else { return }

        switch fit {
        case .stretch:
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha)
        case .tile:
            let size = image.size
            guard size.width > 1, size.height > 1 else { return }
            var y = target.minY
            while y < target.maxY {
                var x = target.minX
                while x < target.maxX {
                    image.draw(in: NSRect(x: x, y: y, width: size.width, height: size.height),
                               from: .zero, operation: .sourceOver, fraction: alpha)
                    x += size.width
                }
                y += size.height
            }
        case .center:
            let size = image.size
            let origin = NSPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
            image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha)
        case .fill, .fit:
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = fit == .fill
                ? max(target.width / size.width, target.height / size.height)
                : min(target.width / size.width, target.height / size.height)
            let scaled = NSSize(width: size.width * scale, height: size.height * scale)
            let origin = NSPoint(x: target.midX - scaled.width / 2, y: target.midY - scaled.height / 2)
            image.draw(in: NSRect(origin: origin, size: scaled), from: .zero, operation: .sourceOver, fraction: alpha)
        }
    }
}

/// Decodes each background image once. Every pane shares the same image, and
/// re-reading a large photo on every redraw would stall scrolling.
final class BackgroundImageCache {
    static let shared = BackgroundImageCache()

    private var cached: [URL: NSImage] = [:]

    func image(for url: URL) -> NSImage? {
        if let hit = cached[url] { return hit }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        cached[url] = image
        return image
    }

    func invalidate() { cached.removeAll() }
}
