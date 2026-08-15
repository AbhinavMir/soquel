import AppKit
import WebKit
import Quartz

/// The right-hand panel: a live preview of the selected file above, and its
/// details below.
///
/// Quick Look on Space already exists; this is the persistent version, so you
/// can arrow through a folder and watch the preview follow without holding a
/// panel open over the window.
final class InspectorView: NSView {
    private var previewContainer: NSView!
    private var previewView: QLPreviewView?
    private var webPreview: WKWebView?
    private var placeholder: NSTextField!
    private var titleField: NSTextField!
    private var detailStack: NSStackView!
    private var checksumButton: NSButton!

    private var current: URL?
    /// Guards against a slow checksum landing after the selection moved on.
    private var checksumToken = UUID()
    /// The finished hash for `current`, and whether one is being computed.
    /// The details are rebuilt whenever a metadata read lands, so this state
    /// must live outside the stack or the rebuild erases the computed row
    /// and re-arms the button mid-hash. Both reset when the selection moves.
    private var checksumResult: String?
    private var isComputingChecksum = false
    /// Metadata is read in the background; the panel hears about the answer
    /// through this, or the rows would only appear on a reselection.
    private var metadataObserver: NSObjectProtocol?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
    }

    private func build() {
        metadataObserver = NotificationCenter.default.addObserver(
            forName: .soquelMetadataRead, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let url = note.object as? URL, url == self.current else { return }
            // The rebuild must not request another read: for a file under
            // active writes, each read would invalidate the last one and
            // trigger the next, and the panel would churn for as long as
            // the writes continue.
            self.showDetails(of: url, startMetadataRead: false)
        }

        previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        placeholder = NSTextField(labelWithString: "No selection")
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        titleField = NSTextField(labelWithString: "")
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 3
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        checksumButton = NSButton(title: "Compute SHA-256", target: self, action: #selector(computeChecksum))
        checksumButton.bezelStyle = .rounded
        checksumButton.controlSize = .small
        checksumButton.isHidden = true
        checksumButton.translatesAutoresizingMaskIntoConstraints = false

        let detailScroll = NSScrollView()
        let detailDocument = FlippedClipView()
        detailScroll.contentView = detailDocument
        let detailHost = NSView()
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addSubview(titleField)
        detailHost.addSubview(detailStack)
        detailHost.addSubview(checksumButton)
        detailScroll.documentView = detailHost
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewContainer)
        addSubview(placeholder)
        addSubview(detailScroll)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewContainer.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.42),

            placeholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            detailScroll.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
            detailScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            detailHost.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            detailHost.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),

            titleField.topAnchor.constraint(equalTo: detailHost.topAnchor, constant: 4),
            titleField.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor, constant: -12),

            detailStack.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            detailStack.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor, constant: 12),
            detailStack.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor, constant: -12),

            checksumButton.topAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 10),
            checksumButton.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor, constant: 12),
            checksumButton.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor, constant: -12),
        ])
    }

    /// Shows one file. Passing nil, or more than one selection, clears it.
    func show(_ urls: [URL]) {
        checksumToken = UUID()
        checksumResult = nil
        isComputingChecksum = false

        guard urls.count == 1, let url = urls.first else {
            current = nil
            teardownPreview()
            placeholder.stringValue = urls.isEmpty ? "No selection" : "\(urls.count) items selected"
            placeholder.isHidden = false
            titleField.stringValue = ""
            clearDetails()
            checksumButton.isHidden = true
            return
        }

        current = url
        placeholder.isHidden = true
        titleField.stringValue = url.lastPathComponent
        showPreview(of: url)
        showDetails(of: url)
    }

    // MARK: - Preview

    private func teardownPreview() {
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        webPreview?.stopLoading()
        webPreview?.removeFromSuperview()
        webPreview = nil
    }

    /// A fresh QLPreviewView per file. Reusing one leaks the previous document
    /// for some types, and `close()` is the documented way to release it.
    private func showPreview(of url: URL) {
        teardownPreview()

        // Quick Look shows an HTML file as its source, or as nothing at all
        // for a fragment with no <html> around it. Rendering it is what anyone
        // looking at a .html file wanted to see.
        if Self.rendersAsWeb(url) {
            showWebPreview(of: url)
            return
        }

        let preview = QLPreviewView(frame: previewContainer.bounds, style: .compact) ?? QLPreviewView()
        preview.autoresizingMask = [.width, .height]
        preview.frame = previewContainer.bounds
        preview.shouldCloseWithWindow = false
        previewContainer.addSubview(preview)
        preview.previewItem = url as QLPreviewItem
        previewView = preview
    }

    /// Whether the file is one to render rather than hand to Quick Look.
    static func rendersAsWeb(_ url: URL) -> Bool {
        ["html", "htm", "xhtml", "svg"].contains(url.pathExtension.lowercased())
    }

    /// A local renderer with nothing switched on.
    ///
    /// Reading a file must not become a way for that file to reach the
    /// network, run anything of consequence or leave something behind, so
    /// JavaScript is off, the store is non-persistent and it is granted read
    /// access to the file's own folder and no further.
    private func showWebPreview(of url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let web = WKWebView(frame: previewContainer.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        previewContainer.addSubview(web)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        webPreview = web
    }

    // MARK: - Details

    private func clearDetails() {
        for view in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func row(_ label: String, _ value: String, tooltip: String? = nil) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 10.5, weight: .semibold)
        name.textColor = .tertiaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let content = NSTextField(labelWithString: value)
        content.font = Theme.rowNumeric
        content.textColor = .labelColor
        content.lineBreakMode = .byTruncatingMiddle
        content.isSelectable = true
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [name, content])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        if let tooltip {
            name.toolTip = tooltip
            content.toolTip = tooltip
            stack.toolTip = tooltip
        }
        return stack
    }

    private func showDetails(of url: URL, startMetadataRead: Bool = true) {
        clearDetails()

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
            .localizedTypeDescriptionKey, .typeIdentifierKey, .isSymbolicLinkKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false

        detailStack.addArrangedSubview(row("Kind", values?.localizedTypeDescription ?? "—"))

        if isDirectory {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            detailStack.addArrangedSubview(row("Contains", "\(count) item\(count == 1 ? "" : "s")"))
        } else {
            let size = Int64(values?.fileSize ?? 0)
            detailStack.addArrangedSubview(row("Size", Self.byteFormatter.string(fromByteCount: size)))
            if let allocated = values?.totalFileAllocatedSize, Int64(allocated) != size {
                detailStack.addArrangedSubview(
                    row("On disk", Self.byteFormatter.string(fromByteCount: Int64(allocated)))
                )
            }
        }

        if let created = values?.creationDate {
            detailStack.addArrangedSubview(row("Created", Self.dateFormatter.string(from: created)))
        }
        if let modified = values?.contentModificationDate {
            detailStack.addArrangedSubview(row("Modified", Self.dateFormatter.string(from: modified)))
        }
        if let opened = values?.contentAccessDate {
            detailStack.addArrangedSubview(row("Last opened", Self.dateFormatter.string(from: opened)))
        }

        // POSIX permissions and ownership, which Finder shows only as a coarse
        // "read & write" popup.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let mode = attributes[.posixPermissions] as? NSNumber {
                detailStack.addArrangedSubview(row(
                    "Permissions", Self.describe(mode: mode.uint16Value),
                    tooltip: Self.explain(mode: mode.uint16Value, isDirectory: isDirectory)
                ))
            }
            let owner = attributes[.ownerAccountName] as? String
            let group = attributes[.groupOwnerAccountName] as? String
            if owner != nil || group != nil {
                detailStack.addArrangedSubview(
                    row("Owner", [owner, group].compactMap { $0 }.joined(separator: " : "))
                )
            }
        }

        if values?.isSymbolicLink == true,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            detailStack.addArrangedSubview(row("Links to", target))
        }

        if let type = values?.typeIdentifier {
            detailStack.addArrangedSubview(row("Type", type))
        }

        // Whatever media metadata has already been read. A fresh selection
        // also asks for a background check, so a file overwritten since its
        // last read shows current values; the check is skipped on the
        // notification-driven rebuild, which must not start the next read.
        if let record = MetadataReader.shared.cached(url) {
            for field in MetadataField.allCases {
                if let value = record[field] {
                    detailStack.addArrangedSubview(row(field.title, value))
                }
            }
        }
        if startMetadataRead, !isDirectory {
            MetadataReader.shared.read(url)
        }

        let extended = url.extendedAttributeNames()
        if !extended.isEmpty {
            detailStack.addArrangedSubview(row("Attributes", extended.joined(separator: ", ")))
        }

        if let root = gitRoot(for: url) {
            detailStack.addArrangedSubview(row("In repo", relativePath(of: url, from: root)))
        }

        detailStack.addArrangedSubview(row("Where", url.deletingLastPathComponent().path))
        // The checksum survives a rebuild: a metadata read landing after the
        // hash finished must not wipe the row, and one landing mid-hash must
        // not re-arm the button for a redundant second run.
        if let checksumResult {
            detailStack.addArrangedSubview(row("SHA-256", checksumResult))
            checksumButton.isHidden = true
        } else {
            checksumButton.isHidden = isDirectory
            checksumButton.title = isComputingChecksum ? "Computing…" : "Compute SHA-256"
            checksumButton.isEnabled = !isComputingChecksum
        }
    }

    /// "rwxr-xr-x (755)".
    static func describe(mode: UInt16) -> String {
        let bits = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        let owner = Int((mode >> 6) & 0o7)
        let group = Int((mode >> 3) & 0o7)
        let other = Int(mode & 0o7)
        let octal = String(format: "%03o", mode & 0o777)
        return "\(bits[owner])\(bits[group])\(bits[other]) (\(octal))"
    }

    /// What rwxr-xr-x actually means, in words.
    ///
    /// The notation is only obvious to people who already know it, and it is
    /// the one line in the panel that decides whether a file will open.
    ///
    /// The caller says whether this is a folder: the posixPermissions
    /// attribute carries the permission bits only, so the S_IFDIR bit is
    /// never in `mode` to be tested here.
    static func explain(mode: UInt16, isDirectory: Bool = false) -> String {
        let who = ["The owner", "The group", "Everyone else"]
        let values = [Int((mode >> 6) & 0o7), Int((mode >> 3) & 0o7), Int(mode & 0o7)]

        var lines: [String] = []
        for (index, value) in values.enumerated() {
            lines.append("\(who[index]) \(Self.phrase(for: value, isDirectory: isDirectory)).")
        }
        lines.append("")
        lines.append("r read · w change · x " + (isDirectory ? "open the folder" : "run it"))
        return lines.joined(separator: "\n")
    }

    /// One permission triple as a sentence. "x" means something different on a
    /// folder — it is permission to go into it, not to run it.
    static func phrase(for value: Int, isDirectory: Bool) -> String {
        var can: [String] = []
        if value & 0o4 != 0 { can.append(isDirectory ? "list it" : "read it") }
        if value & 0o2 != 0 { can.append(isDirectory ? "add and remove things" : "change it") }
        if value & 0o1 != 0 { can.append(isDirectory ? "open it" : "run it") }

        guard !can.isEmpty else { return "cannot do anything with it" }
        if can.count == 1 { return "can \(can[0])" }
        return "can " + can.dropLast().joined(separator: ", ") + " and " + can[can.count - 1]
    }

    /// Checksums are on demand: hashing a large file on selection would make
    /// arrowing through a folder unusable.
    @objc private func computeChecksum() {
        guard let url = current else { return }
        let token = UUID()
        checksumToken = token
        isComputingChecksum = true
        checksumButton.isEnabled = false
        checksumButton.title = "Computing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let digest = Checksum.sha256(of: url)
            DispatchQueue.main.async {
                guard let self, self.checksumToken == token else { return }
                let text = digest ?? "could not read file"
                self.isComputingChecksum = false
                self.checksumResult = text
                self.checksumButton.isHidden = true
                self.detailStack.addArrangedSubview(self.row("SHA-256", text))
            }
        }
    }
}

extension URL {
    /// Names of the extended attributes on this file, for the inspector.
    func extendedAttributeNames() -> [String] {
        withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let length = listxattr(path, nil, 0, 0)
            guard length > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: length)
            guard listxattr(path, &buffer, length, 0) > 0 else { return [] }
            return buffer.split(separator: 0)
                .compactMap { String(bytes: $0.map { UInt8(bitPattern: $0) }, encoding: .utf8) }
        }
    }
}
