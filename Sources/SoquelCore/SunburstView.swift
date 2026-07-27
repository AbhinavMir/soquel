import AppKit

/// The rings. Drawn with Core Graphics rather than assembled from subviews:
/// a few hundred wedges as views would be a few hundred layers to composite
/// on every hover.
final class SunburstView: NSView {
    /// Called when a folder wedge is clicked, to descend into it.
    var onDescend: ((URL) -> Void)?
    /// Called as the pointer moves, with whatever is under it.
    var onHover: ((SunburstSegment?) -> Void)?
    /// Called for a right-click, so the panel can put up a menu.
    var onContextMenu: ((SunburstSegment, NSPoint) -> Void)?

    private(set) var segments: [SunburstSegment] = []
    private var highlighted: SunburstSegment?
    private var tracking: NSTrackingArea?

    /// How many rings outwards are drawn. Past about five the wedges are
    /// thinner than the labels and the picture stops answering anything.
    static let ringCount = 5

    override var isFlipped: Bool { false }

    func show(_ root: DiskMap.Node) {
        segments = SunburstLayout.segments(for: root, rings: Self.ringCount)
        highlighted = nil
        needsDisplay = true
    }

    func clear() {
        segments = []
        highlighted = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private var outerRadius: CGFloat {
        max(20, min(bounds.width, bounds.height) / 2 - 12)
    }

    /// The hole in the middle holds the total, and gives the innermost ring a
    /// sane thickness instead of a point.
    private var holeRadius: CGFloat { outerRadius * 0.22 }

    private var ringWidth: CGFloat {
        (outerRadius - holeRadius) / CGFloat(Self.ringCount)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.chrome.setFill()
        context.fill(dirtyRect)
        guard !segments.isEmpty else { return }

        for segment in segments where segment.ring > 0 && segment.ring <= Self.ringCount {
            draw(segment, in: context)
        }
        drawCentre(in: context)
    }

    private func draw(_ segment: SunburstSegment, in context: CGContext) {
        let inner = holeRadius + CGFloat(segment.ring - 1) * ringWidth
        let outer = inner + ringWidth - 1

        // Core Graphics measures counter-clockwise from three o'clock; the
        // layout runs clockwise from twelve.
        let from = CGFloat(Double.pi / 2 - segment.start)
        let to = CGFloat(Double.pi / 2 - segment.end)

        let path = CGMutablePath()
        path.addArc(center: centre, radius: outer, startAngle: from, endAngle: to, clockwise: true)
        path.addArc(center: centre, radius: inner, startAngle: to, endAngle: from, clockwise: false)
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(color(for: segment).cgColor)
        context.fillPath()

        // A hairline between wedges, so neighbours of similar colour still read
        // as two things.
        context.addPath(path)
        context.setStrokeColor(Theme.chrome.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(segment == highlighted ? 2 : 0.5)
        if segment == highlighted {
            context.setStrokeColor(NSColor.white.cgColor)
        }
        context.strokePath()

        drawLabel(for: segment, inner: inner, outer: outer, in: context)
    }

    /// Labels only where one fits: a name in a two-degree wedge is a smear.
    private func drawLabel(
        for segment: SunburstSegment, inner: CGFloat, outer: CGFloat, in context: CGContext
    ) {
        let midRadius = (inner + outer) / 2
        let arcLength = CGFloat(segment.sweep) * midRadius
        guard arcLength > 44, segment.sweep > 0.28 else { return }

        let midAngle = Double.pi / 2 - (segment.start + segment.sweep / 2)
        let point = CGPoint(
            x: centre.x + cos(midAngle) * Double(midRadius),
            y: centre.y + sin(midAngle) * Double(midRadius)
        )

        let text = segment.name as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        guard size.width < arcLength, size.width < (outer - inner) * 4 else { return }

        context.saveGState()
        // A soft shadow keeps the name readable over any wedge colour.
        context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        text.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                  withAttributes: attributes)
        context.restoreGState()
    }

    private func drawCentre(in context: CGContext) {
        guard let root = segments.first(where: { $0.ring == 0 }) else { return }

        context.setFillColor(Theme.chrome.cgColor)
        context.fillEllipse(in: CGRect(
            x: centre.x - holeRadius, y: centre.y - holeRadius,
            width: holeRadius * 2, height: holeRadius * 2
        ))

        let shown = highlighted ?? root
        let size = ByteCountFormatter.string(fromByteCount: shown.bytes, countStyle: .file)
        let text = size as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let measured = text.size(withAttributes: attributes)
        guard measured.width < holeRadius * 1.9 else { return }
        text.draw(at: CGPoint(x: centre.x - measured.width / 2, y: centre.y - measured.height / 2),
                  withAttributes: attributes)
    }

    /// Hue by position around the circle, brightness by depth, so siblings are
    /// distinguishable and a folder's own children read as belonging to it.
    private func color(for segment: SunburstSegment) -> NSColor {
        let midAngle = (segment.start + segment.end) / 2
        let hue = CGFloat(midAngle / (2 * .pi))
        let depth = CGFloat(segment.ring)
        let saturation: CGFloat = segment.isAggregate ? 0.05 : max(0.30, 0.72 - depth * 0.07)
        let brightness: CGFloat = min(0.95, 0.55 + depth * 0.08)
        let base = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        return segment == highlighted ? base.blended(withFraction: 0.25, of: .white) ?? base : base
    }

    // MARK: - Pointing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    private func segment(at point: NSPoint) -> SunburstSegment? {
        SunburstLayout.segment(
            at: point, centre: centre, ringWidth: ringWidth,
            holeRadius: holeRadius, segments: segments
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = segment(at: point)
        guard found != highlighted else { return }
        highlighted = found
        onHover?(found)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        onHover?(nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let found = segment(at: point), found.isDirectory else { return }
        // The aggregate wedge is a sum, not a folder, so there is nothing to
        // enter. It is recognised by its flag: matching on the name "smaller
        // items" also caught a folder genuinely called that, which then could
        // not be opened at all.
        guard !found.isAggregate else { return }
        onDescend?(found.url)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let found = segment(at: point) else { return }
        onContextMenu?(found, event.locationInWindow)
    }
}
