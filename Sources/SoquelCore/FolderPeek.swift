import AppKit

/// What space on a folder shows.
///
/// Quick Look has nothing for a directory, so pressing space on one does
/// nothing at all. This shows the first handful of things inside it.
enum FolderPeek {
    /// How many tiles the grid draws before it stops counting them out.
    static let tileLimit = 24

    struct Contents {
        var items: [FileItem] = []
        var folders = 0
        var files = 0
        var hidden = 0
        /// Why the folder could not be read, when it could not. An unreadable
        /// folder must not present itself as an empty one.
        var error: Error?

        /// The items that get a tile. Folders first, then files.
        var shown: [FileItem] { Array(items.prefix(tileLimit)) }
        var overflow: Int { max(0, items.count - tileLimit) }

        var summary: String {
            if let error { return error.localizedDescription }
            if items.isEmpty { return hidden > 0 ? "Empty, ignoring \(hidden) hidden" : "Empty" }
            var parts: [String] = []
            if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
            if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
            return parts.joined(separator: ", ")
        }
    }

    static func read(_ url: URL, showHidden: Bool) -> Contents {
        let all: [FileItem]
        do {
            all = try DirectoryLoader.read(url, showHidden: true)
        } catch {
            var contents = Contents()
            contents.error = error
            return contents
        }
        let visible = showHidden ? all : all.filter { !$0.isHidden }

        var contents = Contents()
        contents.hidden = all.count - visible.count
        contents.folders = visible.filter(\.isDirectory).count
        contents.files = visible.count - contents.folders
        contents.items = visible.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return contents
    }
}

/// The panel itself. A panel rather than a sheet so space closes it again and
/// arrowing through a folder can keep it open.
final class FolderPeekController: NSWindowController {
    static let shared: FolderPeekController = {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.hidesOnDeactivate = false
        let controller = FolderPeekController(window: window)
        controller.build()
        return controller
    }()

    private var grid: NSCollectionView!
    private var footer: NSTextField!
    private var contents = FolderPeek.Contents()
    private var url: URL?

    var isOpen: Bool { window?.isVisible == true }

    private func build() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 108, height: 96)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        grid = NSCollectionView()
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.isSelectable = false
        grid.backgroundColors = [.clear]
        grid.register(FolderPeekTile.self,
                      forItemWithIdentifier: NSUserInterfaceItemIdentifier("tile"))

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: "")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func toggle(_ url: URL, over parent: NSWindow?) {
        if isOpen, self.url == url { close(); return }
        show(url, over: parent)
    }

    func show(_ url: URL, over parent: NSWindow?) {
        self.url = url
        window?.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        // The panel appears at once and the listing follows. Reading inline
        // blocked the key press for as long as the folder took to enumerate —
        // indefinitely on a stalled network mount.
        contents = FolderPeek.Contents()
        footer.stringValue = "Loading…"
        grid.reloadData()

        if let parent, window?.isVisible != true {
            window?.setFrameOrigin(NSPoint(
                x: parent.frame.midX - (window?.frame.width ?? 0) / 2,
                y: parent.frame.midY - (window?.frame.height ?? 0) / 2
            ))
        }
        window?.orderFront(nil)

        let showHidden = Prefs.showHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let read = FolderPeek.read(url, showHidden: showHidden)
            DispatchQueue.main.async {
                // The peek may have moved to another folder, or closed,
                // while this one was still being read.
                guard let self, self.url == url else { return }
                self.contents = read
                var text = read.summary
                if read.overflow > 0 { text += " · showing the first \(FolderPeek.tileLimit)" }
                self.footer.stringValue = text
                self.grid.reloadData()
            }
        }
    }

    override func close() {
        url = nil
        super.close()
    }
}

extension FolderPeekController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        contents.shown.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(
            withIdentifier: NSUserInterfaceItemIdentifier("tile"), for: indexPath
        )
        (tile as? FolderPeekTile)?.show(contents.shown[indexPath.item])
        return tile
    }
}

final class FolderPeekTile: NSCollectionViewItem {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(icon)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    /// What this tile is currently showing, so a late thumbnail is discarded
    /// rather than painted over a same-named file from another folder.
    private var representedURL: URL?
    /// The thumbnail request this tile is waiting on, dropped when it is reused.
    private var thumbnailToken: ThumbnailCache.Token?

    func show(_ item: FileItem) {
        label.stringValue = item.name
        ThumbnailCache.shared.cancel(thumbnailToken)
        thumbnailToken = nil
        let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
        fallback.size = NSSize(width: 52, height: 52)
        icon.image = fallback

        let wanted = item.url
        // Set before requesting: a cache hit calls back synchronously, and the
        // completion checks this to know the tile still wants the image.
        representedURL = wanted
        guard ThumbnailCache.wantsThumbnail(item) else { return }
        thumbnailToken = ThumbnailCache.shared.thumbnail(
            for: wanted, size: 52, modified: item.modified,
            scale: view.window?.backingScaleFactor ?? 2
        ) { [weak self] image in
            // The tile is reused, so a slow thumbnail must not land on whatever
            // file has since taken its place.
            guard let self, self.representedURL == wanted else { return }
            self.icon.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ThumbnailCache.shared.cancel(thumbnailToken)
        thumbnailToken = nil
        representedURL = nil
    }
}
