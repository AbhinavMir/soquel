import AppKit

/// One tab: a rounded capsule holding the folder's name with its close button
/// inside it, the way Safari and Chrome draw one.
///
/// The close button used to be a sibling in the stack, so the row read as
/// name, cross, name, cross with nothing tying a cross to the tab it belonged
/// to. Putting it inside removes the ambiguity and the clutter in one go.
final class TabItemView: NSView {
    static let height: CGFloat = 26
    static let minWidth: CGFloat = 92
    static let maxWidth: CGFloat = 180

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var isActive = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(title: String, active: Bool, closable: Bool) {
        super.init(frame: .zero)
        isActive = active
        build(title: title, closable: closable)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(title: String, closable: Bool) {
        wantsLayer = true
        layer?.cornerRadius = Theme.style == .bevelled ? 0 : 7
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        close.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close \(title)"
        )?.withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))
        close.isBordered = true
        close.bezelStyle = .circular
        close.setButtonType(.momentaryChange)
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close “\(title)”  ⌘W"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isHidden = !closable
        // Shown on hover and on the active tab, like Safari. A cross on every
        // tab at all times is most of what made the row look busy.
        close.alphaValue = isActive ? 1 : 0

        addSubview(label)
        addSubview(close)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),

            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 15),
            close.heightAnchor.constraint(equalToConstant: 15),
        ])

        applyColours()
    }

    // MARK: - Appearance

    /// A selected tab is raised, not recoloured. Filling it with the accent
    /// made a folder name shout louder than any file in the list under it.
    private func applyColours() {
        layer?.cornerRadius = Theme.style == .bevelled ? 0 : 7
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if isActive {
                background = Theme.chrome
            } else if isHovered {
                background = Theme.hairline
            } else {
                background = .clear
            }
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = isActive ? 1 : 0
            layer?.borderColor = Theme.hairline.cgColor
        }
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        close.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColours()
        animateClose(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColours()
        animateClose(to: isActive ? 1 : 0)
    }

    private func animateClose(to alpha: CGFloat) {
        guard !close.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            close.animator().alphaValue = alpha
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { isActive ? 1 : 0 }
}

extension TabItemView {
    /// A raised edge on the tab you are on, a flat one on the rest — which is
    /// how a nineties tab strip said which one was in front.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard Theme.style == .bevelled else { return }
        Bevel.raised.draw(in: bounds)
    }
}
