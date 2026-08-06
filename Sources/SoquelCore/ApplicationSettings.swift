import AppKit
import UniformTypeIdentifiers

/// Which application opens which kind of file, changed from here rather than
/// from Finder's Get Info window one file at a time.
///
/// These are Launch Services settings, not Soquel's: changing one changes it
/// for the whole system. The pane says so, because a setting that quietly
/// reaches outside the application it lives in is a nasty surprise.
final class ApplicationSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The kinds worth offering. A full list of every type Launch Services
    /// knows about runs to thousands and is unusable.
    struct Kind {
        let title: String
        let extensions: [String]
        /// Added by the user rather than shipped in the list below, and so
        /// removable.
        var isCustom = false

        var primary: String { extensions[0] }
    }

    static let kinds: [Kind] = [
        Kind(title: "Plain text", extensions: ["txt"]),
        Kind(title: "Markdown", extensions: ["md", "markdown"]),
        Kind(title: "JSON", extensions: ["json"]),
        Kind(title: "YAML", extensions: ["yaml", "yml"]),
        Kind(title: "CSV", extensions: ["csv"]),
        Kind(title: "Swift", extensions: ["swift"]),
        Kind(title: "Python", extensions: ["py"]),
        Kind(title: "JavaScript", extensions: ["js"]),
        Kind(title: "TypeScript", extensions: ["ts"]),
        Kind(title: "Shell script", extensions: ["sh"]),
        Kind(title: "HTML", extensions: ["html", "htm"]),
        Kind(title: "CSS", extensions: ["css"]),
        Kind(title: "XML", extensions: ["xml"]),
        Kind(title: "PDF", extensions: ["pdf"]),
        Kind(title: "PNG image", extensions: ["png"]),
        Kind(title: "JPEG image", extensions: ["jpg", "jpeg"]),
        Kind(title: "GIF image", extensions: ["gif"]),
        Kind(title: "SVG image", extensions: ["svg"]),
        Kind(title: "HEIC image", extensions: ["heic"]),
        Kind(title: "MP4 video", extensions: ["mp4"]),
        Kind(title: "QuickTime video", extensions: ["mov"]),
        Kind(title: "MP3 audio", extensions: ["mp3"]),
        Kind(title: "Zip archive", extensions: ["zip"]),
    ]

    /// Extensions the user added, because twenty-three curated kinds is a
    /// starting point and not an answer. `duti` will remap anything; so does
    /// this, once you name the extension.
    static var customExtensions: [String] {
        get { Settings.stringArray(forKey: "applicationKinds") ?? [] }
        set { Settings.set(newValue, forKey: "applicationKinds") }
    }

    /// The built-in kinds followed by the added ones. An extension already
    /// covered above is not added twice: two rows for `.md` would disagree
    /// with each other the moment one of them was changed.
    static var rows: [Kind] {
        kinds + customExtensions.compactMap { ext in
            guard !isBuiltIn(ext) else { return nil }
            return Kind(title: describe(ext), extensions: [ext], isCustom: true)
        }
    }

    static func isBuiltIn(_ ext: String) -> Bool {
        let wanted = normalise(ext)
        return kinds.contains { $0.extensions.contains(wanted) }
    }

    /// Accepts what people actually type: `.PNG`, `png`, `  png  `.
    static func normalise(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// "PNG image" when the system knows the type, otherwise the extension on
    /// its own. Never a guess dressed up as a description.
    static func describe(_ ext: String) -> String {
        contentType(forExtension: ext)?.localizedDescription ?? ".\(ext) files"
    }

    /// Whether an extension can be added: it has to be a real extension, one
    /// the system recognises, and not already listed.
    enum AddResult: Equatable {
        case ok(String)
        case empty
        case alreadyListed(String)
        case unknownType(String)

        var problem: String? {
            switch self {
            case .ok: return nil
            case .empty: return "Type a file extension, such as rs or toml."
            case .alreadyListed(let ext): return ".\(ext) is already in the list."
            case .unknownType(let ext):
                return "macOS does not recognise .\(ext), so there is no type to set a handler for."
            }
        }
    }

    static func validateAddition(_ raw: String) -> AddResult {
        let ext = normalise(raw)
        guard !ext.isEmpty else { return .empty }
        guard !isBuiltIn(ext), !customExtensions.map(normalise).contains(ext) else {
            return .alreadyListed(ext)
        }
        guard contentType(forExtension: ext) != nil else { return .unknownType(ext) }
        return .ok(ext)
    }

    private var table: NSTableView!
    private var status: NSTextField!
    /// Cached so the table does not ask Launch Services once per redraw.
    private var defaults: [String: URL?] = [:]
    private var confirmBox: NSButton!
    private var confirmRow: NSStackView!
    private var addKindButton: NSButton!
    /// Snapshotted per reload so the table and its actions agree on the rows
    /// even if the stored list changes underneath them.
    private var rows: [Kind] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Types and their handlers

    /// The UTI for an extension, which is what Launch Services keys on.
    static func contentType(forExtension ext: String) -> UTType? {
        UTType(filenameExtension: ext)
    }

    static func defaultApplication(forExtension ext: String) -> URL? {
        guard let type = contentType(forExtension: ext) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    static func candidates(forExtension ext: String) -> [URL] {
        guard let type = contentType(forExtension: ext) else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: type).filter { app in
            seen.insert(Bundle(url: app)?.bundleIdentifier ?? app.path).inserted
        }
    }

    /// Sets the handler for every extension of a kind, so choosing an editor
    /// for Markdown covers `.md` and `.markdown` rather than half the job.
    static func setDefault(
        _ app: URL, for kind: Kind, completion: @escaping (Error?) -> Void
    ) {
        let types = kind.extensions.compactMap(contentType(forExtension:))
        guard !types.isEmpty else {
            completion(CocoaError(.fileReadUnknown))
            return
        }

        var remaining = types.count
        var failure: Error?
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                DispatchQueue.main.async {
                    if let error { failure = error }
                    remaining -= 1
                    if remaining == 0 { completion(failure) }
                }
            }
        }
    }

    // MARK: - Building

    private func build() {
        let title = NSTextField(labelWithString:
            "Choose what opens each kind of file. These are the system's settings: "
            + "a change here applies in Finder and everywhere else too.")
        title.font = Theme.rowSecondary
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.width = 180
        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "Opens with"
        appColumn.width = 260
        table.addTableColumn(kindColumn)
        table.addTableColumn(appColumn)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        refresh.translatesAutoresizingMaskIntoConstraints = false

        let addKind = NSButton(title: "Add Kind…", target: self, action: #selector(addKind))
        addKind.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addKind)
        self.addKindButton = addKind

        confirmBox = NSButton(
            checkboxWithTitle: "Ask before opening applications that are slow to start",
            target: self, action: #selector(toggleConfirm)
        )
        confirmBox.state = AppLaunchGuard.isEnabled ? .on : .off
        confirmBox.translatesAutoresizingMaskIntoConstraints = false

        let forget = NSButton(
            title: "Ask Again About All", target: self, action: #selector(forgetAllowances)
        )
        forget.translatesAutoresizingMaskIntoConstraints = false

        let confirmRow = NSStackView(views: [confirmBox, forget])
        confirmRow.orientation = .horizontal
        confirmRow.spacing = 10
        confirmRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(confirmRow)
        self.confirmRow = confirmRow

        addSubview(title)
        addSubview(scroll)
        addSubview(status)
        addSubview(refresh)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: confirmRow.topAnchor, constant: -10),

            confirmRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            confirmRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            confirmRow.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            status.trailingAnchor.constraint(equalTo: addKind.leadingAnchor, constant: -10),

            addKind.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
            addKind.centerYAnchor.constraint(equalTo: status.centerYAnchor),

            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            refresh.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        reload()
    }

    @objc private func toggleConfirm() {
        AppLaunchGuard.isEnabled = confirmBox.state == .on
        status.stringValue = AppLaunchGuard.isEnabled
            ? "Will ask before Xcode and other slow applications"
            : "Will not ask before any application"
    }

    @objc private func forgetAllowances() {
        AppLaunchGuard.forgetAllowances()
        status.stringValue = "Will ask again about every application"
    }

    @objc private func reload() {
        rows = Self.rows
        defaults.removeAll()
        for kind in rows {
            defaults[kind.primary] = Self.defaultApplication(forExtension: kind.primary)
        }
        table.reloadData()
        let added = rows.filter(\.isCustom).count
        status.stringValue = added == 0
            ? "\(rows.count) kinds"
            : "\(rows.count) kinds, \(added) added"
    }

    /// Adds any extension the system recognises. Anything it does not is
    /// refused with the reason, rather than being stored as a row that can
    /// never be set.
    @objc private func addKind() {
        let alert = NSAlert()
        alert.messageText = "Add a file kind"
        alert.informativeText = "Type a file extension. Its handler can then be changed like any other."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "rs"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch Self.validateAddition(field.stringValue) {
        case .ok(let ext):
            Self.customExtensions.append(ext)
            reload()
            if let index = rows.firstIndex(where: { $0.isCustom && $0.primary == ext }) {
                table.scrollRowToVisible(index)
                table.selectRowIndexes([index], byExtendingSelection: false)
            }
            status.stringValue = "Added .\(ext)"
        case let result:
            status.stringValue = result.problem ?? ""
        }
    }

    @objc private func removeKind(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let kind = rows[sender.tag]
        guard kind.isCustom else { return }
        // Only the row goes. The handler it set stays set — removing a row
        // here is tidying this list, not reverting a system-wide change the
        // user asked for and may still want.
        Self.customExtensions.removeAll { Self.normalise($0) == kind.primary }
        reload()
        status.stringValue = "Removed .\(kind.primary) from the list; its handler is unchanged"
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let kind = rows[row]

        if tableColumn?.identifier.rawValue == "kind" {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString:
                "\(kind.title)  ." + kind.extensions.joined(separator: " ."))
            field.font = Theme.rowName
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            // Only an added row can be taken away. The built-in list is the
            // same in every copy of the application and stays that way.
            if kind.isCustom {
                let remove = NSButton()
                remove.image = NSImage(systemSymbolName: "minus.circle",
                                       accessibilityDescription: "Remove")
                remove.isBordered = false
                remove.tag = row
                remove.target = self
                remove.action = #selector(removeKind(_:))
                remove.toolTip = "Remove .\(kind.primary) from this list"
                remove.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(remove)
                NSLayoutConstraint.activate([
                    remove.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 6),
                    remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    remove.widthAnchor.constraint(equalToConstant: 18),
                ])
            } else {
                field.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor, constant: -2
                ).isActive = true
            }
            return cell
        }

        let cell = NSTableCellView()
        let popup = NSPopUpButton()
        popup.tag = row
        popup.target = self
        popup.action = #selector(chooseApplication(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false

        let current = defaults[kind.primary] ?? nil
        let candidates = Self.candidates(forExtension: kind.primary)

        if candidates.isEmpty {
            popup.addItem(withTitle: "Nothing registered")
            popup.isEnabled = false
        } else {
            for app in candidates {
                let name = FileManager.default.displayName(atPath: app.path)
                popup.addItem(withTitle: name)
                let item = popup.lastItem
                item?.representedObject = app
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item?.image = icon
                if app.standardizedFileURL == current?.standardizedFileURL {
                    popup.select(item)
                }
            }
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: "Other…")
        }

        cell.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func chooseApplication(_ sender: NSPopUpButton) {
        // Indexes the displayed rows, not the built-in list: an added kind
        // sits past the end of `kinds` and would otherwise set the handler for
        // whichever built-in row happened to share its index, or for nothing.
        guard rows.indices.contains(sender.tag) else { return }
        let kind = rows[sender.tag]

        var chosen = sender.selectedItem?.representedObject as? URL
        if sender.titleOfSelectedItem == "Other…" {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            guard panel.runModal() == .OK, let picked = panel.url else {
                reload()
                return
            }
            chosen = picked
        }
        guard let chosen else { return }

        let name = FileManager.default.displayName(atPath: chosen.path)
        status.stringValue = "Setting \(kind.title) to \(name)…"

        Self.setDefault(chosen, for: kind) { [weak self] error in
            guard let self else { return }
            if let error {
                self.status.stringValue = "Could not change \(kind.title): \(error.localizedDescription)"
                NSSound.beep()
            } else {
                self.status.stringValue = "\(name) now opens \(kind.title.lowercased())"
                Log.info(.app, "Default for \(kind.primary) set to \(name)")
            }
            self.reload()
        }
    }
}
