import AppKit

/// Looking inside a `.app` — or any other package — without leaving the folder
/// you are standing in.
///
/// Finder's "Show Package Contents" navigates into the bundle, which loses the
/// folder you were in and puts a directory full of `MacOS/`, `Resources/` and
/// `_CodeSignature/` where your files used to be. That is almost never a place
/// you meant to go and browse; it is somewhere you look, find one file, and
/// leave. So this opens over the window instead and closes again.
enum PackageContents {
    /// Whether an item should offer to be looked inside.
    ///
    /// Any package qualifies, not only `.app`. A `.rtfd`, an `.xcodeproj` and a
    /// `.photoslibrary` are all directories macOS presents as one file, and all
    /// of them are occasionally worth opening up.
    static func canInspect(_ item: FileItem) -> Bool {
        item.isDirectory && item.isPackage
    }

    /// One entry in the bundle tree. Children are read when a row is opened
    /// rather than up front: a `.photoslibrary` holds tens of thousands of
    /// files and walking it eagerly would hang the panel on the first draw.
    final class Node {
        let item: FileItem
        var children: [Node] = []
        var loaded = false

        init(_ item: FileItem) { self.item = item }

        var isExpandable: Bool { item.isDirectory }
    }

    /// Reads one level, folders first and then by name, so the shape of a
    /// bundle is the same every time it is opened.
    static func children(of url: URL) -> [Node] {
        let items = (try? DirectoryLoader.read(url, showHidden: true)) ?? []
        return sorted(items).map(Node.init)
    }

    /// Folders before files, then case-insensitive by name.
    static func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What the footer says about a bundle.
    ///
    /// The count is of everything underneath, not just the top level, because
    /// "4 items" under a `.app` that holds nine thousand is a useless number.
    struct Summary {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0

        var text: String {
            let f = files == 1 ? "1 file" : "\(files) files"
            let d = folders == 1 ? "1 folder" : "\(folders) folders"
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(f) in \(d) · \(size)"
        }
    }

    /// Walks the whole bundle. Called off the main thread — a large package
    /// takes long enough that doing this while the panel opens would show an
    /// empty window first.
    ///
    /// Symlinks are not followed and a hard-linked file is counted once,
    /// matching what the disk map and the folder-size column already do; a
    /// bundle that links the same framework three times is not three times
    /// the size on disk.
    static func summarise(_ url: URL, isCancelled: () -> Bool = { false }) -> Summary {
        var summary = Summary()
        var seen = Set<Inode>()

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileSizeKey, .fileResourceIdentifierKey, .isRegularFileKey,
        ]
        // No skipsPackageDescendants: the whole point is to go inside one.
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return summary }

        for case let child as URL in walker {
            if isCancelled() { return summary }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                summary.folders += 1
                continue
            }
            if let id = values.fileResourceIdentifier as? NSObject {
                let inode = Inode(id)
                if seen.contains(inode) { continue }
                seen.insert(inode)
            }
            summary.files += 1
            summary.bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return summary
    }

    /// Wraps the opaque resource identifier so it can go in a Set.
    struct Inode: Hashable {
        private let id: NSObject
        init(_ id: NSObject) { self.id = id }
        static func == (a: Inode, b: Inode) -> Bool { a.id.isEqual(b.id) }
        func hash(into hasher: inout Hasher) { hasher.combine(id.hash) }
    }
}

/// The window that shows it.
final class PackageContentsController: NSWindowController {
    private var root: URL!
    private var nodes: [PackageContents.Node] = []
    private var outline: NSOutlineView!
    private var footer: NSTextField!
    private var summaryWork: DispatchWorkItem?

    /// Set by the opener so "Open in Pane" has somewhere to send a folder.
    var onOpenInPane: ((URL) -> Void)?

    /// Everything the window keeps pointing back at this controller — the data
    /// source, the delegate, the button targets — is weak, so someone must own
    /// it strongly or it deallocates the moment show() returns and the panel
    /// goes dead. An array because several package windows can be open at
    /// once. Released again in windowWillClose(_:).
    private static var active: [PackageContentsController] = []

    static func show(_ url: URL, over parent: NSWindow?, onOpenInPane: ((URL) -> Void)? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.setFrameAutosaveName("SoquelPackageContents")

        let controller = PackageContentsController(window: window)
        controller.root = url
        controller.onOpenInPane = onOpenInPane
        window.delegate = controller
        active.append(controller)
        controller.build()
        controller.load()

        if let parent {
            window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - window.frame.width / 2,
                y: parent.frame.midY - window.frame.height / 2
            ))
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        outline = NSOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openRow)
        outline.usesAlternatingRowBackgroundColors = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: "Reading…")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        footer.translatesAutoresizingMaskIntoConstraints = false

        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealRow))
        let open = NSButton(title: "Open", target: self, action: #selector(openRow))
        for button in [reveal, open] { button.translatesAutoresizingMaskIntoConstraints = false }

        let content = window!.contentView!
        [scroll, footer, reveal, open].forEach(content.addSubview)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -10),

            reveal.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -8),
            reveal.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            open.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func load() {
        nodes = PackageContents.children(of: root)
        outline.reloadData()

        // The walk is the slow part and the list is not waiting on it.
        let target = root!
        let work = DispatchWorkItem { [weak self] in
            let summary = PackageContents.summarise(target) { self?.summaryWork?.isCancelled ?? true }
            DispatchQueue.main.async {
                guard let self, self.summaryWork?.isCancelled == false else { return }
                self.footer.stringValue = summary.text
            }
        }
        summaryWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    override func close() {
        summaryWork?.cancel()
        super.close()
    }

    private var selectedURL: URL? {
        (outline.item(atRow: outline.selectedRow) as? PackageContents.Node)?.item.url
    }

    @objc private func revealRow() {
        guard let url = selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A folder inside the bundle goes to the pane; a file opens in its
    /// application. Opening the folder here rather than descending in place
    /// keeps this window a window you look in and leave.
    @objc private func openRow() {
        guard let node = outline.item(atRow: outline.selectedRow) as? PackageContents.Node else { return }
        if node.item.isDirectory, !node.item.isPackage {
            onOpenInPane?(node.item.url)
            close()
            return
        }
        AppLaunchGuard.confirm(opening: [node.item.url], with: nil, in: window) {
            NSWorkspace.shared.open(node.item.url)
        }
    }
}

extension PackageContentsController: NSWindowDelegate {
    /// Fires for the titlebar close button too, which never goes through the
    /// close() override; the walk must stop either way.
    func windowWillClose(_ notification: Notification) {
        summaryWork?.cancel()
        // Released on the next turn, not here: dropping the last strong
        // reference while the close is still being dispatched would
        // deallocate the controller out from under AppKit.
        DispatchQueue.main.async { Self.active.removeAll { $0 === self } }
    }
}

extension PackageContentsController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? PackageContents.Node else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? PackageContents.Node else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PackageContents.Node)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? PackageContents.Node, !node.loaded else { return true }
        node.loaded = true
        node.children = PackageContents.children(of: node.item.url)
        outlineView.reloadItem(node, reloadChildren: true)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PackageContents.Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image

            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text

            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = node.item.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.item.url.path)
        return cell
    }
}
