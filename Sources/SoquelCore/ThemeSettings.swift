import AppKit

/// Picking a set of colours to start from.
///
/// Rows are plain views in a stack, as in the other panels here: a row holds a
/// name, a description, a swatch strip and a button.
final class ThemeSettingsView: NSView {
    private var rowStack: NSStackView!
    private var status: NSTextField!
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func build() {
        let title = NSTextField(labelWithString:
            "A starting point. Applying one writes its colours to theme.json, which you can "
            + "then edit — by hand or with the colour wells. Your background image is kept.")
        title.font = Theme.rowSecondary
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false

        rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.contentView = FlippedClipView()
        scroll.documentView = rowStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        let reveal = NSButton(title: "Reveal theme.json", target: self, action: #selector(revealFile))
        let buttons = NSStackView(views: [reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(scroll)
        addSubview(status)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            rowStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        observer = NotificationCenter.default.addObserver(
            forName: .soquelThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
    }

    // MARK: - Rows

    private func reload() {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for preset in ThemePresets.all {
            let row = makeRow(for: preset)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        status.stringValue = ThemePresets.current.map { "Using “\($0.name)”" }
            ?? "Your own colours"
    }

    private func makeRow(for preset: ThemePreset) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let isCurrent = ThemePresets.current == preset

        let name = NSTextField(labelWithString: preset.name + (isCurrent ? "  ✓" : ""))
        name.font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        name.translatesAutoresizingMaskIntoConstraints = false

        let about = NSTextField(labelWithString: preset.about)
        about.font = Theme.rowSecondary
        about.textColor = .secondaryLabelColor
        about.lineBreakMode = .byTruncatingTail
        about.translatesAutoresizingMaskIntoConstraints = false

        // A strip of the colours themselves says more than the name does.
        let swatches = NSStackView()
        swatches.orientation = .horizontal
        swatches.spacing = 3
        swatches.translatesAutoresizingMaskIntoConstraints = false
        for slot in ThemeConfig.Slot.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.separatorColor.cgColor
            // A preset that leaves a slot alone shows the built-in colour, so
            // the strip always reads as what you would actually get.
            let hex = preset.dark[slot.rawValue] ?? preset.light[slot.rawValue]
            let swatch = hex.flatMap { NSColor(hexString: $0) } ?? Theme.builtIn(slot, dark: true)
            dot.layer?.backgroundColor = swatch.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 16).isActive = true
            swatches.addArrangedSubview(dot)
        }

        let use = NSButton(title: isCurrent ? "In use" : "Use", target: self, action: #selector(usePreset(_:)))
        use.identifier = NSUserInterfaceItemIdentifier(preset.name)
        use.isEnabled = !isCurrent

        let actions = NSStackView(views: [use])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        for view in [name, about, swatches, actions] as [NSView] { container.addSubview(view) }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 54),

            name.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            name.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),

            about.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            about.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            about.trailingAnchor.constraint(lessThanOrEqualTo: swatches.leadingAnchor, constant: -10),

            swatches.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12),
            swatches.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            actions.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func usePreset(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue,
              let preset = ThemePresets.all.first(where: { $0.name == name }) else { return }
        ThemePresets.apply(preset)
        status.stringValue = "Using “\(preset.name)”"
        reload()
    }

    @objc private func revealFile() {
        // Written first, so there is something to reveal on a machine that has
        // never had the file, and so it shows every slot rather than only the
        // ones that happen to be set.
        do {
            let url = try Theme.writeTemplate()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            // Revealing the path anyway would open a Finder window on nothing.
            status.stringValue = error.localizedDescription
            NSSound.beep()
        }
    }
}
