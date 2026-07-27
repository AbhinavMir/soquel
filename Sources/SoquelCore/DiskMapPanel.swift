import AppKit

/// Where the space went: rings on the left, the biggest items on the right.
///
/// The list and the picture answer different questions. The list finds the one
/// enormous file; the rings find the folder that is enormous because of ten
/// thousand small ones, which no sorted list will ever show you.
final class DiskMapPanelController: NSWindowController {
    static let shared: DiskMapPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disk Map"
        window.setFrameAutosaveName("SoquelDiskMap")
        window.minSize = NSSize(width: 720, height: 480)
        let controller = DiskMapPanelController(window: window)
        window.delegate = controller
        controller.build()
        return controller
    }()

    private let scanner = DiskMap()
    private var root: DiskMap.Node?
    /// What the rings are centred on, which is not always the scan root.
    private var focus: DiskMap.Node?

    private var sunburst: SunburstView!
    private var breadcrumb: NSTextField!
    private var detail: NSTextField!
    private var listStack: NSStackView!
    private var spinner: NSProgressIndicator!
    private var rescanButton: NSButton!
    private var upButton: NSButton!

    /// Called when the user asks to show something in the file list.
    var onReveal: ((URL) -> Void)?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - Building

    private func build() {
        breadcrumb = NSTextField(labelWithString: "Nothing scanned")
        breadcrumb.font = Theme.path
        breadcrumb.lineBreakMode = .byTruncatingHead
        breadcrumb.translatesAutoresizingMaskIntoConstraints = false

        detail = NSTextField(labelWithString: "")
        detail.font = Theme.status
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false

        upButton = NSButton(title: "◀ Out", target: self, action: #selector(goOut))
        upButton.isEnabled = false
        rescanButton = NSButton(title: "Rescan", target: self, action: #selector(rescan))

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [upButton, breadcrumb, spinner, rescanButton])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        breadcrumb.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sunburst = SunburstView()
        sunburst.translatesAutoresizingMaskIntoConstraints = false
        sunburst.onDescend = { [weak self] url in self?.descend(to: url) }
        sunburst.onHover = { [weak self] segment in self?.describe(segment) }
        sunburst.onContextMenu = { [weak self] segment, point in
            self?.showMenu(for: segment, at: point)
        }

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let listScroll = NSScrollView()
        listScroll.contentView = FlippedClipView()
        listScroll.documentView = listStack
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let listTitle = NSTextField(labelWithString: "BIGGEST HERE")
        listTitle.font = Theme.sectionLabel
        listTitle.textColor = .secondaryLabelColor
        listTitle.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for view in [header, sunburst, listTitle, listScroll, detail] as [NSView] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            sunburst.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            sunburst.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sunburst.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),
            sunburst.trailingAnchor.constraint(equalTo: listTitle.leadingAnchor, constant: -14),

            listTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            listTitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            listTitle.widthAnchor.constraint(equalToConstant: 280),

            listScroll.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 6),
            listScroll.leadingAnchor.constraint(equalTo: listTitle.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            listScroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),

            listStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),

            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    // MARK: - Scanning

    func show(_ url: URL) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        start(url)
    }

    private var scanRoot: URL?
    /// Where the rings were pointed when a rescan started, so the same place
    /// can be found again in the tree the rescan builds.
    private var pendingTrail: [String] = []

    private func start(_ url: URL, keepingPlace: Bool = false) {
        scanRoot = url
        pendingTrail = keepingPlace ? (focus?.trail ?? []) : []
        root = nil
        focus = nil
        sunburst.clear()
        clearList()
        upButton.isEnabled = false
        rescanButton.isEnabled = false
        spinner.startAnimation(nil)
        breadcrumb.stringValue = url.path
        detail.stringValue = "Scanning…"

        scanner.scan(url) { [weak self] progress in
            self?.detail.stringValue = "Scanning — \(progress.scanned) items, "
                + "\(Self.byteFormatter.string(fromByteCount: progress.bytes)) so far"
        } finished: { [weak self] node in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.rescanButton.isEnabled = true

            guard let node else {
                self.detail.stringValue = "Scan cancelled"
                return
            }
            self.root = node
            // Back to where the rings were before the rescan, as far down as
            // the tree still goes. A rescan used to re-centre on the scan root,
            // so trashing one file five levels inside ~/Library/Caches left the
            // user back at ~/ with the drill-down thrown away.
            self.setFocus(node.descendant(along: self.pendingTrail))
            self.pendingTrail = []
        }
    }

    @objc private func rescan(_ sender: Any?) {
        guard let scanRoot else { return }
        start(scanRoot, keepingPlace: true)
    }

    @objc private func goOut(_ sender: Any?) {
        guard let parent = focus?.parent else { return }
        setFocus(parent)
    }

    private func descend(to url: URL) {
        guard let node = find(url, in: focus) else { return }
        guard node.isDirectory, !node.children.isEmpty else { return }
        setFocus(node)
    }

    private func find(_ url: URL, in node: DiskMap.Node?) -> DiskMap.Node? {
        guard let node else { return nil }
        if node.url == url { return node }
        for child in node.children {
            if let hit = find(url, in: child) { return hit }
        }
        return nil
    }

    private func setFocus(_ node: DiskMap.Node) {
        focus = node
        sunburst.show(node)
        upButton.isEnabled = node.parent != nil
        breadcrumb.stringValue = node.url.path
        detail.stringValue = Self.summary(for: node)
        rebuildList(for: node)
    }

    /// The line under the rings.
    ///
    /// A scan that could not read everything says so. Without it the total
    /// reads as the answer when it is only a floor, and it is the number
    /// someone is looking at while deciding what to throw away.
    static func summary(for node: DiskMap.Node) -> String {
        var text = "\(byteFormatter.string(fromByteCount: node.bytes)) · "
            + "\(node.fileCount) file\(node.fileCount == 1 ? "" : "s")"
        if node.unreadableCount > 0 {
            text += " · \(node.unreadableCount) item\(node.unreadableCount == 1 ? "" : "s") "
                + "could not be read, so the total is a minimum"
        }
        return text
    }

    private func describe(_ segment: SunburstSegment?) {
        guard let segment else {
            if let focus { setFocusDetailOnly(focus) }
            return
        }
        let share = focus.map { $0.bytes > 0 ? Double(segment.bytes) / Double($0.bytes) * 100 : 0 } ?? 0
        detail.stringValue = "\(segment.name) — "
            + "\(Self.byteFormatter.string(fromByteCount: segment.bytes)) "
            + String(format: "(%.1f%% of this folder)", share)
    }

    private func setFocusDetailOnly(_ node: DiskMap.Node) {
        detail.stringValue = Self.summary(for: node)
    }

    // MARK: - The list beside it

    private func clearList() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func rebuildList(for node: DiskMap.Node) {
        clearList()
        for child in node.children.prefix(40) where child.bytes > 0 {
            let row = makeRow(for: child, of: node)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(for node: DiskMap.Node, of parent: DiskMap.Node) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: node.name)
        name.font = Theme.rowName
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = node.url.path
        name.translatesAutoresizingMaskIntoConstraints = false

        let size = NSTextField(labelWithString: Self.byteFormatter.string(fromByteCount: node.bytes))
        size.font = Theme.rowNumeric
        size.textColor = .secondaryLabelColor
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false

        // A bar as well as a number: the ratio is the thing being asked about.
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)

        let button = NSButton(title: "", target: self, action: #selector(rowClicked(_:)))
        button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier(node.url.path)
        button.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, name, size, track, button] as [NSView] { container.addSubview(view) }

        let fraction = parent.bytes > 0 ? CGFloat(node.bytes) / CGFloat(parent.bytes) : 0
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),

            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(equalTo: size.leadingAnchor, constant: -8),

            size.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            size.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            size.widthAnchor.constraint(equalToConstant: 74),

            track.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: size.trailingAnchor),
            track.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            track.heightAnchor.constraint(equalToConstant: 3),

            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.004, fraction)),
        ])
        return container
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        descend(to: URL(fileURLWithPath: path))
    }

    // MARK: - Acting on what is found

    private func showMenu(for segment: SunburstSegment, at point: NSPoint) {
        // The aggregate wedge carries its parent's URL, so every item in this
        // menu would act on the parent — Move to Trash included. It is spotted
        // by its flag rather than by its name, which used to leave a folder
        // genuinely called "smaller items" with no menu at all.
        guard !segment.isAggregate else { return }
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show in Soquel", action: #selector(revealHere(_:)), keyEquivalent: "")
        show.representedObject = segment.url
        show.target = self
        menu.addItem(show)

        let finder = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        finder.representedObject = segment.url
        finder.target = self
        menu.addItem(finder)

        menu.addItem(.separator())
        let trash = NSMenuItem(title: "Move to Trash", action: #selector(trashItem(_:)), keyEquivalent: "")
        trash.representedObject = segment.url
        trash.target = self
        menu.addItem(trash)

        menu.popUp(positioning: nil, at: sunburst.convert(point, from: nil), in: sunburst)
    }

    @objc private func revealHere(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onReveal?(url)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deleting from here rescans rather than patching the tree: the numbers
    /// on screen are the reason someone is about to delete something, and a
    /// stale picture after a delete is worse than a moment's wait.
    @objc private func trashItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let window else { return }

        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                self.detail.stringValue = "Moved “\(url.lastPathComponent)” to the Trash"
                self.rescan(nil)
            } catch {
                self.detail.stringValue = error.localizedDescription
                NSSound.beep()
            }
        }
    }
}

extension DiskMapPanelController: NSWindowDelegate {
    /// Closing mid-scan stops the walk rather than leaving it reading a disk
    /// nobody is watching.
    func windowWillClose(_ notification: Notification) {
        scanner.cancel()
    }
}
