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

        styleControl = NSPopUpButton()
        styleControl.addItems(withTitles: ChromeStyle.allCases.map(\.title))
        styleControl.selectItem(at: ChromeStyle.allCases.firstIndex(of: Theme.style) ?? 0)
        styleControl.target = self
        styleControl.action = #selector(styleChanged)

        let styleRow = NSStackView(views: [
            NSTextField(labelWithString: "Edges"), styleControl,
        ])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8
        styleRow.translatesAutoresizingMaskIntoConstraints = false

        gistField = NSTextField()
        gistField.placeholderString = "Paste a gist address to install a theme"
        gistField.font = .systemFont(ofSize: 12)
        gistField.target = self
        gistField.action = #selector(installFromGist)
        gistField.translatesAutoresizingMaskIntoConstraints = false

        installButton = NSButton(title: "Install", target: self, action: #selector(installFromGist))
        let copyButton = NSButton(title: "Copy Mine", target: self, action: #selector(copyForSharing))
        copyButton.toolTip = "Puts your theme.json on the clipboard, ready to paste into a gist"

        let shareRow = NSStackView(views: [gistField, installButton, copyButton])
        shareRow.orientation = .horizontal
        shareRow.spacing = 8
        shareRow.translatesAutoresizingMaskIntoConstraints = false
        gistField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let reveal = NSButton(title: "Reveal theme.json", target: self, action: #selector(revealFile))
        let buttons = NSStackView(views: [reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(scroll)
        addSubview(styleRow)
        addSubview(shareRow)
        addSubview(status)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: styleRow.topAnchor, constant: -10),

            styleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            styleRow.bottomAnchor.constraint(equalTo: shareRow.topAnchor, constant: -10),

            shareRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            shareRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shareRow.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

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

    // MARK: - Sharing

    private var styleControl: NSPopUpButton!

    @objc private func styleChanged() {
        let index = styleControl.indexOfSelectedItem
        guard ChromeStyle.allCases.indices.contains(index) else { return }
        var config = Theme.config
        config.style = ChromeStyle.allCases[index]
        Theme.apply(config)
        status.stringValue = "Edges: \(ChromeStyle.allCases[index].title). Reopen windows to redraw them all."
    }

    private var gistField: NSTextField!
    private var installButton: NSButton!

    /// Fetches a theme from a gist and asks before applying it.
    ///
    /// It is only colours — there is nothing in a theme that can run — but it
    /// still repaints the application, so it is shown and confirmed rather than
    /// applied the moment it arrives.
    @objc private func installFromGist() {
        let text = gistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        installButton.isEnabled = false
        status.stringValue = "Fetching…"

        ThemeSharing.fetch(text) { [weak self] result in
            guard let self else { return }
            self.installButton.isEnabled = true
            switch result {
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
            case .success(let config):
                self.confirm(config)
            }
        }
    }

    private func confirm(_ config: ThemeConfig) {
        let alert = NSAlert()
        alert.messageText = "Use this theme?"
        alert.informativeText = "It sets \(ThemeSharing.summary(config)). Your background image "
            + "is kept — a theme from someone else cannot point at a picture on your disk. "
            + "Reset to Defaults puts everything back."
        alert.addButton(withTitle: "Use It")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status.stringValue = "Left alone"
            return
        }

        var updated = config
        updated.background = Theme.config.background
        updated.windowOpacity = Theme.config.windowOpacity
        Theme.apply(updated)
        gistField.stringValue = ""
        status.stringValue = "Installed"
    }

    @objc private func copyForSharing() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ThemeSharing.exportText(), forType: .string)
        status.stringValue = "Copied — paste it into a gist as theme.json"
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
