import AppKit

/// Settings → Window: how see-through the window is, and what sits behind the
/// file list.
///
/// These were on Appearance, which had grown into a colour grid, a preview, a
/// window slider and a background picker on one scroll. They are about the
/// window rather than about colour, so they live apart from it.
final class WindowSettingsView: NSView {
    private var opacitySlider: NSSlider!
    private var opacityReadout: NSTextField!
    private var pathLabel: NSTextField!
    private var imageOpacity: NSSlider!
    private var imageReadout: NSTextField!
    private var fitControl: NSPopUpButton!
    private var imageRow: NSStackView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func text(_ string: String, weight: NSFont.Weight = .regular,
                      size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func build() {
        opacitySlider = NSSlider(value: Double(Theme.windowOpacity),
                                 minValue: ThemeConfig.minimumWindowOpacity, maxValue: 1,
                                 target: self, action: #selector(opacityChanged))
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        opacityReadout = text(Self.percent(Double(Theme.windowOpacity)))
        opacityReadout.textColor = .secondaryLabelColor
        opacityReadout.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let note = text("The whole window, the way a terminal can be. macOS draws the shadow "
            + "from the window itself, so it fades along with it.", size: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = 520

        let opacityRow = NSStackView(views: [text("Opacity"), opacitySlider, opacityReadout])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8

        pathLabel = text(Theme.background.imageURL?.lastPathComponent ?? "None")
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseImage))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearImage))
        let chooseRow = NSStackView(views: [choose, clear, pathLabel])
        chooseRow.orientation = .horizontal
        chooseRow.spacing = 8

        imageOpacity = NSSlider(value: Theme.background.opacity, minValue: 0, maxValue: 1,
                                target: self, action: #selector(imageOpacityChanged))
        imageOpacity.isContinuous = true
        imageOpacity.widthAnchor.constraint(equalToConstant: 160).isActive = true

        imageReadout = text(Self.percent(Theme.background.opacity))
        imageReadout.textColor = .secondaryLabelColor
        imageReadout.widthAnchor.constraint(equalToConstant: 44).isActive = true

        fitControl = NSPopUpButton()
        fitControl.addItems(withTitles: BackgroundFit.allCases.map(\.title))
        fitControl.selectItem(at: BackgroundFit.allCases.firstIndex(of: Theme.background.fit) ?? 0)
        fitControl.target = self
        fitControl.action = #selector(fitChanged)

        imageRow = NSStackView(views: [text("Image opacity"), imageOpacity, imageReadout,
                                       text("Fit"), fitControl])
        imageRow.orientation = .horizontal
        imageRow.spacing = 8

        let stack = NSStackView(views: [
            text("Transparency", weight: .semibold), opacityRow, note,
            text("Background image", weight: .semibold), chooseRow, imageRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
        ])
        updateImageControls()
    }

    /// Opacity and fit describe an image. With none there is nothing for them
    /// to describe, and a live control that changes nothing reads as broken.
    private func updateImageControls() {
        imageRow.isHidden = Theme.background.imageURL == nil
        pathLabel.stringValue = Theme.background.imageURL?.lastPathComponent ?? "None"
    }

    @objc private func opacityChanged() {
        Theme.setWindowOpacity(opacitySlider.doubleValue)
        opacityReadout.stringValue = Self.percent(opacitySlider.doubleValue)
    }

    @objc private func imageOpacityChanged() {
        guard Theme.background.imageURL != nil else { return }
        var background = Theme.background
        background.opacity = imageOpacity.doubleValue
        imageReadout.stringValue = Self.percent(background.opacity)
        Theme.setBackground(background)
    }

    @objc private func fitChanged() {
        var background = Theme.background
        let index = fitControl.indexOfSelectedItem
        guard BackgroundFit.allCases.indices.contains(index) else { return }
        background.fit = BackgroundFit.allCases[index]
        Theme.setBackground(background)
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick an image to show behind the file list"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var background = Theme.background
        background.imagePath = url.path
        // An image at 0% is one nobody can see, and that slider was hidden a
        // moment ago, so it cannot have been chosen deliberately.
        if background.opacity <= 0.001 { background.opacity = BackgroundConfig.none.opacity }
        Theme.setBackground(background)
        imageOpacity.doubleValue = background.opacity
        imageReadout.stringValue = Self.percent(background.opacity)
        updateImageControls()
    }

    @objc private func clearImage() {
        var background = Theme.background
        background.imagePath = nil
        Theme.setBackground(background)
        updateImageControls()
    }
}
