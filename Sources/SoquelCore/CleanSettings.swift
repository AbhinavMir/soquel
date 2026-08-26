import AppKit

/// Settings → Clean.
///
/// The key, and the folders things are allowed to be filed into. Both live here
/// rather than only behind the panel, because a key somebody gave once should be
/// removable without going looking for the feature that asked for it.
final class CleanSettingsView: NSView {
    private var keyStatus: NSTextField!
    private var keyButton: NSButton!
    private var removeButton: NSButton!
    private var globalsList: NSTextField!

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

        let views = [intro, promise, keyStatus!, keyButton!, removeButton!,
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

    private func refresh() {
        let set = APICredentials.isSet
        keyStatus.stringValue = set
            ? "A key is stored in your Keychain."
            : "No key. Clean This Folder will ask for one when you first use it."
        keyStatus.textColor = set ? .secondaryLabelColor : Theme.danger
        keyButton.title = set ? "Replace Key…" : "Set API Key…"
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
        alert.messageText = "API key"
        alert.informativeText = "From console.anthropic.com. Kept in your Keychain, never in "
            + "settings.json, and used only by Clean This Folder."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard APICredentials.looksLikeAKey(field.stringValue) else {
            let bad = NSAlert()
            bad.messageText = "That does not look like an API key"
            bad.informativeText = "A key starts with “sk-ant-”. Nothing was saved."
            bad.runModal()
            return
        }
        APICredentials.store(field.stringValue)
        refresh()
    }

    @objc private func removeKey() {
        APICredentials.remove()
        refresh()
    }
}
