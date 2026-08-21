import AppKit

/// One tile in the icon view: a thumbnail with its filename underneath.
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    private var label: NSTextField!
    private var thumbnail: NSImageView!
    private var badge: NSTextField!
    /// Sized from the icon setting, not from the tile: the tile is widened
    /// past small icons so the label has room for a word, and an icon that
    /// followed the tile would not have got smaller at all.
    private var thumbnailWidth: NSLayoutConstraint!

    /// The share of the icon setting the thumbnail takes; the rest of the
    /// tile is margin and label.
    static let thumbnailShare: CGFloat = 0.62

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnailWidth = thumbnail.widthAnchor.constraint(
            equalToConstant: CGFloat(Prefs.iconSize) * Self.thumbnailShare
        )

        label = NSTextField(labelWithString: "")
        label.font = Theme.rowName
        label.alignment = .center
        // Two lines, broken between words, and an ellipsis when even two are
        // not enough. `wraps` sets word wrapping itself, so a truncating line
        // break mode set beside it was overwritten and a name that ran past
        // the second line was cut off mid-word with no sign of it.
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
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
            thumbnailWidth,
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

    /// The label's frame in `view`'s coordinates, for the rename editor to
    /// sit exactly over the name.
    func labelFrame(in view: NSView) -> NSRect {
        _ = self.view
        self.view.layoutSubtreeIfNeeded()
        return label.convert(label.bounds, to: view)
    }

    func configure(with item: FileItem, gitState: GitState) {
        _ = view  // force the view to load; loadViewIfNeeded() needs macOS 14
        // A zoom changes the setting after the tile was built.
        let side = CGFloat(Prefs.iconSize)
        thumbnailWidth.constant = side * Self.thumbnailShare
        label.stringValue = item.name
        restingLabelColor = item.isHidden ? .secondaryLabelColor : .labelColor
        badge.stringValue = gitState.badge
        badge.toolTip = gitState == .clean ? nil : gitState.explanation

        // isSelected is set by the collection view before the tile is handed a
        // file, and its observer runs against the previous file's resting
        // colour — or against no view at all, when the selection was set on a
        // grid that had just been reloaded. Re-applied here, after the tile
        // knows what it is showing, so a carried-over selection is drawn.
        applySelectionAppearance()

        ThumbnailCache.shared.cancel(thumbnailToken)
        thumbnailToken = nil
        // The type icon is shown first and replaced when the real thumbnail
        // arrives, so scrolling never waits on a generator.
        thumbnail.image = FileListViewController.icon(for: item)

        let url = item.url
        // Set before requesting: a cache hit calls back synchronously, and the
        // completion checks this to know the cell still wants the image.
        representedURL = url
        guard ThumbnailCache.wantsThumbnail(item) else { return }

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
