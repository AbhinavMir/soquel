import AppKit

/// One tile in the icon view: a thumbnail with its filename underneath.
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    private var label: NSTextField!
    private var thumbnail: NSImageView!
    private var badge: NSTextField!

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        label = NSTextField(labelWithString: "")
        label.font = Theme.rowName
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false

        badge = NSTextField(labelWithString: "")
        badge.font = Theme.rowNumeric
        badge.alignment = .center
        badge.textColor = Theme.accent
        badge.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(thumbnail)
        container.addSubview(label)
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            thumbnail.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            thumbnail.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.62),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor),

            label.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),

            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])

        view = container
    }

    private var restingLabelColor: NSColor = .labelColor
    /// The thumbnail request this cell is waiting on, dropped when it is reused.
    private var thumbnailToken: ThumbnailCache.Token?

    func configure(with item: FileItem, gitState: GitState) {
        _ = view  // force the view to load; loadViewIfNeeded() needs macOS 14
        label.stringValue = item.name
        restingLabelColor = item.isHidden ? .secondaryLabelColor : .labelColor
        badge.stringValue = gitState.badge
        badge.toolTip = gitState == .clean ? nil : gitState.label

        ThumbnailCache.shared.cancel(thumbnailToken)
        thumbnailToken = nil
        // The type icon is shown first and replaced when the real thumbnail
        // arrives, so scrolling never waits on a generator.
        thumbnail.image = NSWorkspace.shared.icon(forFile: item.url.path)

        let url = item.url
        // Set before requesting: a cache hit calls back synchronously, and the
        // completion checks this to know the cell still wants the image.
        representedURL = url
        guard ThumbnailCache.wantsThumbnail(item) else { return }

        let side = CGFloat(Prefs.iconSize)
        let scale = view.window?.backingScaleFactor ?? 2
        thumbnailToken = ThumbnailCache.shared.thumbnail(
            for: url, size: side, modified: item.modified, scale: scale
        ) { [weak self] image in
            // The cell may have been handed a different file by the time the
            // generator answered.
            guard let self, self.representedURL == url else { return }
            self.thumbnail.image = image
        }
    }

    /// What this cell is currently showing, so a late thumbnail is discarded
    /// rather than painted over the wrong file.
    private var representedURL: URL?

    override func prepareForReuse() {
        super.prepareForReuse()
        ThumbnailCache.shared.cancel(thumbnailToken)
        thumbnailToken = nil
        representedURL = nil
    }

    override var isSelected: Bool {
        didSet { applySelectionAppearance() }
    }

    private func applySelectionAppearance() {
        guard isViewLoaded else { return }
        view.layer?.cornerRadius = Theme.selectionCornerRadius
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = isSelected ? Theme.selectionFill.cgColor : NSColor.clear.cgColor
        }
        // The fill is solid, so the name has to invert or it is dark on dark.
        label?.textColor = isSelected ? .white : restingLabelColor
        badge?.textColor = isSelected ? .white : Theme.accent
    }
}

/// Collection view that routes the same single-key commands as the table, so
/// the two view modes behave identically from the keyboard.
final class FileCollectionView: NSCollectionView {
    weak var commandTarget: FileListViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if commandTarget?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// NSCollectionView has no doubleAction, so double-click never opened
    /// anything in icon view. Selection is updated by super first, then a
    /// second click on a tile opens what is selected.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard indexPathForItem(at: point) != nil else { return }
        commandTarget?.openSelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
                commandTarget?.collectionSelectionChanged()
            }
        } else {
            selectionIndexPaths = []
            commandTarget?.collectionSelectionChanged()
        }
        return commandTarget?.contextMenu(forRow: -1)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { commandTarget?.didBecomeFocused() }
        return ok
    }

    /// NSCollectionView's own selectAll skips the controller, so the status
    /// bar and inspector would not hear about the new selection.
    override func selectAll(_ sender: Any?) {
        commandTarget?.selectAllItems()
    }
}
