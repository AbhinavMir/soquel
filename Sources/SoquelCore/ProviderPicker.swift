import AppKit

/// Choosing where Clean This Folder sends its question, by pointing at it.
///
/// A grid rather than a menu, because the choice is not really between eleven
/// services — it is between "on my machine" and "somewhere else", and a grid
/// can say that where a popup button cannot. The ones running here are marked
/// as running, live, while the sheet is open.
final class ProviderPickerController: NSWindowController {
    private var onDone: ((Bool) -> Void)?
    private var tiles: [String: ProviderTile] = [:]
    private var chosen: String = LLMProvider.chosenID

    private var keyRow: NSStackView!
    private var keyField: NSSecureTextField!
    private var keyLabel: NSTextField!
    private var keyLink: NSButton!
    private var modelField: NSComboBox!
    private var hostedApproval: NSButton!
    private var doneButton: NSButton!
    private var footnote: NSTextField!

    init(onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Where should Clean This Folder ask?"
        super.init(window: window)
        PrivacyScreen.apply(to: window)
        build()
        select(chosen)
        lookForLocal()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let content = FlippedView()

        let title = NSTextField(labelWithString: "Where should Clean This Folder ask?")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(labelWithString:
            "Local AI is recommended. The first three run on this Mac — no key, and nothing "
            + "leaves it. Use a hosted API only for data approved for that provider; protected "
            + "health information requires an executed BAA.")
        blurb.font = Theme.rowSecondary
        blurb.textColor = .secondaryLabelColor
        blurb.lineBreakMode = .byWordWrapping
        blurb.maximumNumberOfLines = 3
        // As in CleanFolderPanel: a wrapping label with no bound reports its
        // whole string as its intrinsic width and stretches the sheet.
        blurb.preferredMaxLayoutWidth = 600
        blurb.translatesAutoresizingMaskIntoConstraints = false

        // One row, scrolling. The ones that run here come first, because they
        // are the recommendation and because "no key" is the shortest path to
        // using this at all.
        let row = strip(LLMProvider.presets.sorted { ($0.isLocal ? 0 : 1) < ($1.isLocal ? 0 : 1) })

        keyLabel = NSTextField(labelWithString: "")
        keyLabel.font = Theme.rowSecondary
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        keyField = NSSecureTextField()
        keyField.placeholderString = "paste the key"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        keyLink = NSButton(title: "Get a key", target: self, action: #selector(openKeyPage))
        keyLink.bezelStyle = .inline
        keyLink.translatesAutoresizingMaskIntoConstraints = false

        modelField = NSComboBox()
        modelField.placeholderString = "model"
        modelField.isEditable = true
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        keyRow = NSStackView(views: [keyLabel, keyField, keyLink, modelField])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.translatesAutoresizingMaskIntoConstraints = false

        hostedApproval = NSButton(
            checkboxWithTitle: "This provider is approved for these files, with an executed BAA if they contain PHI",
            target: nil, action: nil)
        hostedApproval.font = Theme.status
        hostedApproval.translatesAutoresizingMaskIntoConstraints = false

        footnote = NSTextField(labelWithString: "")
        footnote.font = Theme.status
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        footnote.maximumNumberOfLines = 2
        footnote.preferredMaxLayoutWidth = 600
        footnote.translatesAutoresizingMaskIntoConstraints = false

        doneButton = NSButton(title: "Use This", target: self, action: #selector(done))
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        [title, blurb, row, keyRow!, hostedApproval!, footnote!, doneButton!, cancel].forEach(content.addSubview)
        window?.contentView = content

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            blurb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            blurb.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            blurb.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            row.topAnchor.constraint(equalTo: blurb.bottomAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            row.heightAnchor.constraint(equalToConstant: 126),

            keyRow.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 18),
            keyRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            keyRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            hostedApproval.topAnchor.constraint(equalTo: keyRow.bottomAnchor, constant: 8),
            hostedApproval.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            footnote.topAnchor.constraint(equalTo: hostedApproval.bottomAnchor, constant: 6),
            footnote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footnote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancel.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
        ])
    }

    /// One scrolling row of tiles. Eleven of them do not fit across a sheet
    /// anybody wants to look at, and wrapping them into a block turns a list
    /// into a puzzle.
    private func strip(_ providers: [LLMProvider]) -> NSView {
        let stack = NSStackView(views: providers.map { provider in
            let tile = ProviderTile(provider: provider) { [weak self] in self?.select(provider.id) }
            tiles[provider.id] = tile
            return tile
        })
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .top
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)

        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 116),
        ])
        return scroll
    }

    // MARK: - Choosing

    private func select(_ id: String) {
        chosen = id
        for (tileID, tile) in tiles { tile.isChosen = tileID == id }
        guard let provider = LLMProvider.preset(id: id) else { return }

        // The whole row goes, rather than a disabled field sitting there: a
        // provider that wants nothing should not look like one that wants
        // something you have not given it.
        keyRow.isHidden = !provider.needsKey
        hostedApproval.isHidden = !provider.needsKey
        hostedApproval.state = .off
        keyLink.isHidden = provider.keyURL == nil
        keyLabel.stringValue = "Key"
        if provider.needsKey, APICredentials.key(for: id) != nil {
            keyField.placeholderString = "a key is already saved — leave blank to keep it"
        } else {
            keyField.placeholderString = "paste the key"
        }
        keyField.stringValue = ""

        modelField.removeAllItems()
        modelField.stringValue = provider.suggestedModel
        LLMProvider.models(for: provider) { [weak self] names in
            guard let self, self.chosen == id, !names.isEmpty else { return }
            self.modelField.addItems(withObjectValues: names)
            if self.modelField.stringValue.isEmpty { self.modelField.stringValue = names[0] }
        }

        footnote.stringValue = provider.isLocal
            ? "Recommended: nothing is sent over a network. If it is not running, start it and press Use This again."
            : "Hosted: use only for approved data. PHI requires an executed BAA. The key is stored mode 0600 and used only here."
    }

    /// Marks the ones that answer, so somebody already running Ollama sees it
    /// said rather than having to know.
    private func lookForLocal() {
        LLMProvider.findLocal { [weak self] found in
            guard let self else { return }
            let running = Set(found.map(\.id))
            for (id, tile) in self.tiles { tile.isRunning = running.contains(id) }
        }
    }

    @objc private func openKeyPage() {
        guard let url = LLMProvider.preset(id: chosen)?.keyURL.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func done() {
        guard let provider = LLMProvider.preset(id: chosen) else { return }
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.needsKey, hostedApproval.state != .on {
            footnote.stringValue = "Confirm that this provider is approved for these files before adding or using its key."
            footnote.textColor = Theme.danger
            return
        }
        if provider.needsKey, !typed.isEmpty {
            guard APICredentials.looksLikeAKey(typed) else {
                footnote.stringValue = "That does not look like a key — it has a space in it, or is very short. Nothing was saved."
                footnote.textColor = Theme.danger
                return
            }
            APICredentials.store(typed, for: provider.id)
        }
        if provider.needsKey, APICredentials.key(for: provider.id) == nil {
            footnote.stringValue = "\(provider.name) needs a key before it can be used."
            footnote.textColor = Theme.danger
            return
        }
        LLMProvider.chosenID = provider.id
        LLMProvider.customEndpoint = ""
        LLMProvider.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(true)
    }

    @objc private func cancel() { finish(false) }

    private func finish(_ chose: Bool) {
        let callback = onDone
        onDone = nil
        if let sheetParent = window?.sheetParent, let window {
            sheetParent.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        callback?(chose)
    }
}

/// One tile: an icon, a name, a line saying what choosing it gets you, and a
/// dot when the thing is actually running.
private final class ProviderTile: NSView {
    private let provider: LLMProvider
    private let action: () -> Void
    private let box = NSBox()
    private let dot = NSView()
    private let icon = NSImageView()

    var isChosen = false { didSet { restyle() } }
    var isRunning = false { didSet { dot.isHidden = !isRunning } }

    init(provider: LLMProvider, action: @escaping () -> Void) {
        self.provider = provider
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: provider.symbol, accessibilityDescription: provider.name)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString:
            provider.name.replacingOccurrences(of: " (on this machine)", with: "")
                .replacingOccurrences(of: " (many models, one key)", with: ""))
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let tagline = NSTextField(labelWithString: provider.tagline)
        tagline.font = NSFont.systemFont(ofSize: 10)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 3
        tagline.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = true
        dot.toolTip = "Running now"
        dot.translatesAutoresizingMaskIntoConstraints = false

        addSubview(box)
        [icon, name, tagline, dot].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 140),
            heightAnchor.constraint(equalToConstant: 116),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),

            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            tagline.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            tagline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            tagline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            dot.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    private func restyle() {
        box.borderColor = isChosen ? Theme.accent : .separatorColor
        box.borderWidth = isChosen ? 2 : 1
        box.fillColor = isChosen ? Theme.accent.withAlphaComponent(0.10) : .clear
        icon.contentTintColor = isChosen ? Theme.accent : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) { action() }
    override var acceptsFirstResponder: Bool { true }
}
