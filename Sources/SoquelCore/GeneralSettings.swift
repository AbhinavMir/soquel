import AppKit

/// Settings → General: the switches that decide how a folder is listed.
///
/// Every one of these could already be flipped from the command palette or a
/// menu, and nowhere else. A palette is a shortcut to something, not the place
/// a setting lives: somebody looking for "should folders sort first" opens
/// Settings and expects to find it there, and a setting only reachable by
/// knowing its name is a setting most people never find.
final class GeneralSettingsView: NSView {
    /// One switch: what it says, how it reads, and what it writes.
    private struct Toggle {
        let title: String
        let note: String
        let get: () -> Bool
        let set: (Bool) -> Void
    }

    private var boxes: [(button: NSButton, toggle: Toggle)] = []
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func label(_ string: String, weight: NSFont.Weight = .regular,
                       size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private static let listing: [Toggle] = [
        Toggle(title: "Show hidden files",
               note: "Dotfiles and everything else the system keeps out of sight. ⇧⌘.",
               get: { Prefs.showHiddenFiles }, set: { Prefs.showHiddenFiles = $0 }),
        Toggle(title: "Folders first",
               note: "Folders are grouped above files instead of sorting in among them.",
               get: { Prefs.foldersFirst }, set: { Prefs.foldersFirst = $0 }),
        Toggle(title: "Show Git status",
               note: "A column and a badge for anything changed in a repository.",
               get: { Prefs.showGitStatus }, set: { Prefs.showGitStatus = $0 }),
        Toggle(title: "Calculate folder sizes",
               note: "Measured in the background. A folder of a hundred thousand files costs "
                   + "a great deal of reading to add up.",
               get: { Prefs.calculateFolderSizes }, set: { Prefs.calculateFolderSizes = $0 }),
        Toggle(title: "Fit columns automatically",
               note: "Widths follow the longest value in the folder. Dragging a column turns "
                   + "this off, since a dragged width should stay where it was put.",
               get: { Prefs.autoFitColumns }, set: { Prefs.autoFitColumns = $0 }),
        Toggle(title: "Remember the view for each folder",
               note: "A folder opens in the view and sort it was last left in, rather than "
                   + "the one global setting.",
               get: { FolderViewSettings.isEnabled }, set: { FolderViewSettings.isEnabled = $0 }),
    ]

    private static let window: [Toggle] = [
        Toggle(title: "Show the preview panel",
               note: "Kind, size, dates, permissions and a Quick Look preview. ⌥⌘I",
               get: { Prefs.showInspector }, set: { Prefs.showInspector = $0 }),
        Toggle(title: "Show the folder tree",
               note: "An expandable hierarchy in the sidebar. ⇧⌘T",
               get: { Prefs.showFolderTree }, set: { Prefs.showFolderTree = $0 }),
        Toggle(title: "Sync browsing",
               note: "Selecting a folder in one pane shows it in the next one along.",
               get: { Prefs.syncBrowsing }, set: { Prefs.syncBrowsing = $0 }),
        Toggle(title: "Keyboard-first keys",
               note: "j k h l to move, g g and G for the ends, ⌃d and ⌃u by the half page. "
                   + "Only while the file list has focus, so typing in a field is untouched.",
               get: { Prefs.keyboardFirst }, set: { Prefs.keyboardFirst = $0 }),
    ]

    private static let copying: [Toggle] = [
        Toggle(title: "Verify copies with a checksum",
               note: "Every copied file is read back and compared with its source. Slower, "
                   + "and the only way to know the bytes arrived.",
               get: { VerifiedCopy.isEnabled }, set: { VerifiedCopy.isEnabled = $0 }),
    ]

    private func section(_ title: String, _ toggles: [Toggle]) -> [NSView] {
        var views: [NSView] = [label(title, weight: .semibold)]
        for toggle in toggles {
            let box = NSButton(checkboxWithTitle: toggle.title, target: self,
                               action: #selector(toggleChanged(_:)))
            box.state = toggle.get() ? .on : .off
            box.tag = boxes.count
            boxes.append((box, toggle))

            let note = label(toggle.note, size: 11)
            note.textColor = .secondaryLabelColor
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 3
            note.preferredMaxLayoutWidth = 500

            views.append(box)
            views.append(note)
        }
        return views
    }

    private func build() {
        var views: [NSView] = []
        views += section("Listing", Self.listing)
        views += section("Window", Self.window)
        views += section("Copying", Self.copying)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])

        // The same switches are in the menus and the palette. A checkbox that
        // disagrees with what the window is doing is worse than none.
        observer = NotificationCenter.default.addObserver(
            forName: .soquelSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        for entry in boxes { entry.button.state = entry.toggle.get() ? .on : .off }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard boxes.indices.contains(sender.tag) else { return }
        boxes[sender.tag].toggle.set(sender.state == .on)
        // Everything on screen reads these directly, so the windows are told
        // to re-read rather than each switch knowing who cares about it.
        NotificationCenter.default.post(name: .soquelSettingsChanged, object: nil)
    }
}
