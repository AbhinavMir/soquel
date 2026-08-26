import AppKit

/// Settings → Clean.
///
/// The key, and the folders things are allowed to be filed into. Both live here
/// rather than only behind the panel, because a key somebody gave once should be
/// removable without going looking for the feature that asked for it.
final class CleanSettingsView: NSView {
    private var betaToggle: NSButton!
    private var keyStatus: NSTextField!
    private var keyButton: NSButton!
    private var removeButton: NSButton!
    private var globalsList: NSTextField!
    private var betaDetail: NSTextField!
    private var providerDetail: NSTextField!
    private var providerPicker: NSPopUpButton!
    private var endpointField: NSTextField!
    private var modelField: NSComboBox!
    private var detected: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func label(_ text: String, secondary: Bool = false, lines: Int = 5) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if secondary {
            field.font = Theme.rowSecondary
            field.textColor = .secondaryLabelColor
        }
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = lines
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func build() {
        let intro = label(
            "Clean This Folder (⇧⌘L) suggests an arrangement for the folder you are in. It is the "
            + "only part of Soquel that sends the contents of your files anywhere: the names, and "
            + "the first 4 KB of each text file, go to Anthropic's API. Everything else in Soquel "
            + "stays on this machine.",
            secondary: true)

        let promise = label(
            "Before anything is sent you can read the exact text in “Show What Would Be Sent”. "
            + "Files whose names suggest a secret — .env, id_rsa, anything ending .pem or .key — "
            + "are never opened. Anything that looks like a key, token or password is replaced "
            + "with “[removed]”. Your files on disk are never changed by any of this.",
            secondary: true)

        betaToggle = NSButton(checkboxWithTitle: "Clean This Folder (beta)",
                              target: self, action: #selector(betaChanged))
        betaToggle.state = Prefs.cleanFolder ? .on : .off
        betaToggle.translatesAutoresizingMaskIntoConstraints = false

        let betaDetail = label(
            "Off by default. With it off there is no ⌃⌘L, no menu item, no toolbar button and no "
            + "command in the palette, and no key is asked for. Turning it on adds a ✦ button you "
            + "can put in the toolbar by right-clicking it.",
            secondary: true, lines: 4)
        self.betaDetail = betaDetail

        providerPicker = NSPopUpButton()
        providerPicker.addItems(withTitles: LLMProvider.presets.map(\.name))
        providerPicker.selectItem(at: LLMProvider.presets.firstIndex { $0.id == LLMProvider.chosenID } ?? 0)
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged)
        providerPicker.translatesAutoresizingMaskIntoConstraints = false

        let providerDetail = label(
            "Anything that speaks Anthropic's API or the /chat/completions shape that OpenAI "
            + "defined — which is Ollama, LM Studio, llama.cpp, OpenRouter, GLM, DeepSeek, Groq "
            + "and most of the rest. A model on this machine needs no key and sends nothing over "
            + "a network, which for a feature that reads your files is the best answer there is.",
            secondary: true, lines: 5)
        self.providerDetail = providerDetail

        detected = label("", secondary: true, lines: 2)

        endpointField = NSTextField()
        endpointField.placeholderString = "https://…/v1/chat/completions"
        endpointField.target = self
        endpointField.action = #selector(endpointChanged)
        endpointField.translatesAutoresizingMaskIntoConstraints = false

        modelField = NSComboBox()
        modelField.placeholderString = "model name"
        modelField.isEditable = true
        modelField.completes = true
        modelField.target = self
        modelField.action = #selector(modelChanged)
        modelField.translatesAutoresizingMaskIntoConstraints = false

        keyStatus = label("")
        keyButton = NSButton(title: "Set API Key…", target: self, action: #selector(setKey))
        keyButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton = NSButton(title: "Remove Key", target: self, action: #selector(removeKey))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let globalsTitle = label("Global folders")
        let globalsDetail = label(
            "Folders things may be filed into from anywhere. A file in ~/test1 can be moved to "
            + "~/test2/abc when that folder is global, with nothing written about it — the mark is "
            + "the instruction. Mark one with “Mark as a Global Folder” in the command palette "
            + "while you are standing in it. A suggestion may never move a file anywhere except "
            + "the folder being cleaned or one of these.",
            secondary: true, lines: 6)
        globalsList = label("", secondary: true, lines: 8)

        let views = [intro, promise, betaToggle!, betaDetail,
                     providerPicker!, providerDetail, detected!,
                     endpointField!, modelField!,
                     keyStatus!, keyButton!, removeButton!,
                     globalsTitle, globalsDetail, globalsList!]
        views.forEach(addSubview)

        var constraints: [NSLayoutConstraint] = []
        var previous: NSView?
        for view in views {
            let sideBySide = view === removeButton
            if sideBySide {
                constraints += [
                    view.leadingAnchor.constraint(equalTo: keyButton.trailingAnchor, constant: 10),
                    view.centerYAnchor.constraint(equalTo: keyButton.centerYAnchor),
                ]
                continue
            }
            constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18))
            constraints.append(view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18))
            constraints.append(view.topAnchor.constraint(
                equalTo: previous?.bottomAnchor ?? topAnchor, constant: previous == nil ? 14 : 12))
            previous = view
        }
        constraints.append(previous!.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)
        refresh()
    }

    @objc private func providerChanged() {
        let provider = LLMProvider.presets[providerPicker.indexOfSelectedItem]
        LLMProvider.chosenID = provider.id
        // A preset carries its own address, so an override from a previous
        // choice must not follow it across.
        LLMProvider.customEndpoint = ""
        LLMProvider.model = ""
        refresh()
        loadModels()
    }

    @objc private func endpointChanged() {
        LLMProvider.customEndpoint = endpointField.stringValue
        refresh()
        loadModels()
    }

    @objc private func modelChanged() {
        LLMProvider.model = modelField.stringValue
        refresh()
    }

    /// Asks the server what it has, so a name can be picked instead of
    /// remembered. Servers that do not answer leave the field a plain one.
    private func loadModels() {
        modelField.removeAllItems()
        LLMProvider.models(for: LLMProvider.current) { [weak self] names in
            guard let self, !names.isEmpty else { return }
            self.modelField.addItems(withObjectValues: names)
        }
    }

    private func lookForLocal() {
        LLMProvider.findLocal { [weak self] found in
            guard let self else { return }
            self.detected.stringValue = found.isEmpty
                ? "Nothing found running on this machine."
                : "Running here now: " + found.map(\.name)
                    .map { $0.replacingOccurrences(of: " (on this machine)", with: "") }
                    .joined(separator: ", ") + "."
        }
    }

    @objc private func betaChanged() {
        Prefs.cleanFolder = betaToggle.state == .on
        // The toolbar and the menus read the setting, and both need telling.
        NotificationCenter.default.post(name: .soquelToolbarChanged, object: nil)
        refresh()
    }

    private func refresh() {
        let on = Prefs.cleanFolder
        betaToggle.state = on ? .on : .off
        for view in [keyStatus, keyButton, removeButton, providerPicker,
                     providerDetail, detected, endpointField, modelField] {
            view?.isHidden = !on
        }
        guard on else { globalsList.stringValue = ""; return }

        let provider = LLMProvider.current
        endpointField.stringValue = provider.endpoint
        modelField.stringValue = LLMProvider.currentModel
        lookForLocal()

        guard provider.needsKey else {
            keyStatus.stringValue = "No key needed — this one runs on your machine."
            keyStatus.textColor = .secondaryLabelColor
            keyButton.isHidden = true
            removeButton.isHidden = true
            return
        }
        keyButton.isHidden = false
        let set = APICredentials.isSet(for: provider.id)
        keyStatus.stringValue = set
            ? "A key for \(provider.name) is in your Keychain."
            : "No key for \(provider.name)." + (provider.keyURL.map { " Get one at \($0)" } ?? "")
        keyStatus.textColor = set ? .secondaryLabelColor : Theme.danger
        keyButton.title = set ? "Replace Key…" : "Set Key…"
        removeButton.isHidden = !set

        let destinations = FolderContext.destinations()
        globalsList.stringValue = destinations.isEmpty
            ? "None yet."
            : destinations.map { entry in
                let note = entry.note.map { " — \($0)" } ?? ""
                return "· \(entry.url.path)\(note)"
            }.joined(separator: "\n")
    }

    @objc private func setKey() {
        let alert = NSAlert()
        let provider = LLMProvider.current
        alert.messageText = "Key for \(provider.name)"
        alert.informativeText = (provider.keyURL.map { "From \($0). " } ?? "")
            + "Kept in your Keychain, never in settings.json, and used only by Clean This Folder. "
            + "One key is remembered per provider."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard APICredentials.looksLikeAKey(field.stringValue) else {
            let bad = NSAlert()
            bad.messageText = "That does not look like an API key"
            bad.informativeText = "A key has no spaces and is longer than that. Nothing was saved."
            bad.runModal()
            return
        }
        APICredentials.store(field.stringValue, for: provider.id)
        refresh()
    }

    @objc private func removeKey() {
        APICredentials.remove(for: LLMProvider.current.id)
        refresh()
    }
}
