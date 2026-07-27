import AppKit

/// Picking, saving, importing and sharing themes.
///
/// Rows are plain views in a stack, as in the other panels here: a row holds a
/// name, a description, a swatch strip and two buttons, and a single-column
/// table sizes its cells to the column rather than the panel.
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
            "A theme is one file. Keep several, switch between them, and send one to "
            + "somebody — the background image travels inside it rather than being pointed at.")
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

        let save = NSButton(title: "Save Current as Theme…", target: self, action: #selector(saveCurrent))
        let install = NSButton(title: "Install from File…", target: self, action: #selector(installFile))
        let reveal = NSButton(title: "Reveal Folder", target: self, action: #selector(revealFolder))

        let buttons = NSStackView(views: [reveal, install, save])
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
            forName: .soquelThemesChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
    }

    // MARK: - Rows

    private func reload() {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let themes = ThemeLibrary.all()
        for theme in themes {
            let row = makeRow(for: theme)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        status.stringValue = themes.isEmpty
            ? "No themes yet — save the current colours as one"
            : "\(themes.count) theme\(themes.count == 1 ? "" : "s")"
    }

    private func makeRow(for theme: Theme_File) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let isCurrent = theme.name == ThemeLibrary.currentName

        let name = NSTextField(labelWithString: theme.name + (isCurrent ? "  ✓" : ""))
        name.font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
        name.translatesAutoresizingMaskIntoConstraints = false

        let about = NSTextField(labelWithString: theme.about ?? theme.author ?? "")
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
            // A theme that leaves a slot alone shows the built-in colour, so
            // the strip always reads as what you would actually get.
            let hex = theme.dark[slot.rawValue] ?? theme.light[slot.rawValue]
            let swatch = hex.flatMap { NSColor(hexString: $0) } ?? Theme.builtIn(slot, dark: true)
            dot.layer?.backgroundColor = swatch.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 16).isActive = true
            swatches.addArrangedSubview(dot)
        }

        let use = NSButton(title: isCurrent ? "In use" : "Use", target: self, action: #selector(useTheme(_:)))
        use.identifier = NSUserInterfaceItemIdentifier(theme.name)
        use.isEnabled = !isCurrent

        let share = NSButton(title: "Export…", target: self, action: #selector(exportTheme(_:)))
        share.identifier = NSUserInterfaceItemIdentifier(theme.name)

        let remove = NSButton(title: "✕", target: self, action: #selector(deleteTheme(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(theme.name)
        remove.isBordered = false
        remove.toolTip = "Remove this theme"

        let actions = NSStackView(views: [share, use, remove])
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

    @objc private func useTheme(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let theme = ThemeLibrary.named(name) else { return }
        do {
            try ThemeLibrary.apply(theme)
            status.stringValue = "Using “\(theme.name)”"
        } catch {
            status.stringValue = error.localizedDescription
            NSSound.beep()
        }
        reload()
    }

    @objc private func deleteTheme(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let theme = ThemeLibrary.named(name),
              let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(theme.name)”?"
        alert.informativeText = "The file is deleted from the themes folder."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            ThemeLibrary.delete(theme)
        }
    }

    @objc private func exportTheme(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let theme = ThemeLibrary.named(name) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = theme.safeFileName
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(theme).write(to: url, options: .atomic)
            status.stringValue = "Exported “\(theme.name)”"
        } catch {
            status.stringValue = error.localizedDescription
            NSSound.beep()
        }
    }

    @objc private func installFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try ThemeLibrary.install(from: url)
            status.stringValue = "Installed “\(theme.name)”"
        } catch {
            status.stringValue = error.localizedDescription
            NSSound.beep()
        }
    }

    @objc private func saveCurrent() {
        guard let window else { return }
        let field = NSTextField(string: "My theme")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        let alert = NSAlert()
        alert.messageText = "Save the current colours as a theme"
        alert.informativeText = "It appears in the list and can be exported."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let theme = ThemeLibrary.capture(name: name, author: nil, about: "Saved from your own colours.")
            do {
                try ThemeLibrary.save(theme)
                ThemeLibrary.currentName = name
                self?.status.stringValue = "Saved “\(name)”"
                self?.reload()
            } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func revealFolder() {
        try? FileManager.default.createDirectory(
            at: ThemeLibrary.directoryURL, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([ThemeLibrary.directoryURL])
    }
}
