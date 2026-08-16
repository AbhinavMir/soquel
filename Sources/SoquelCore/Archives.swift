import AppKit

/// Reading archives well enough to look inside one without unpacking it.
///
/// Finder double-clicks an archive to explode it and has no support for RAR or
/// 7z at all; the research calls browsing into archives table stakes for a
/// replacement. This lists an archive and extracts on demand, using the command
/// line tools already on the system.
enum Archive {
    struct Entry {
        let path: String
        let size: Int64
        let isDirectory: Bool

        var name: String { (path as NSString).lastPathComponent }
    }

    /// Extensions worth offering to browse.
    static let readableExtensions: Set<String> = [
        "zip", "jar", "ipa", "tar", "gz", "tgz", "bz2", "tbz", "xz", "7z", "rar",
    ]

    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "gz" || ext == "bz2" || ext == "xz" {
            // .tar.gz and friends are archives; a bare .gz is one compressed
            // file, which tar cannot list, so it gets normal file handling.
            return url.deletingPathExtension().pathExtension.lowercased() == "tar"
        }
        return readableExtensions.contains(ext)
    }

    /// The tool that can read a given archive, or nil when none is installed.
    /// Nothing is bundled: this uses what macOS ships plus anything the user
    /// already has.
    static func lister(for url: URL) -> (tool: String, arguments: [String])? {
        let path = url.path
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "ipa":
            // Plain -l: "length date time name", with a header and a footer that
            // the parser skips. -Z -1 gives names but no sizes.
            return ("/usr/bin/unzip", ["-l", path])
        case "tar", "tgz", "gz", "bz2", "tbz", "xz":
            return ("/usr/bin/tar", ["-tvf", path])
        case "7z":
            return sevenZip().map { ($0, ["l", "-ba", path]) }
        case "rar":
            return which("unrar").map { ($0, ["lb", path]) }
        default:
            return nil
        }
    }

    static func which(_ name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Homebrew's current sevenzip formula installs `7zz`; the legacy p7zip
    /// formula installs `7z`. Both take the same commands, so either serves.
    static func sevenZip() -> String? {
        which("7zz") ?? which("7z")
    }

    /// Lists an archive's contents. Returns an empty list when no tool can read
    /// it, which the caller reports rather than showing an empty archive.
    static func list(_ url: URL, completion: @escaping ([Entry], String?) -> Void) {
        guard let lister = lister(for: url) else {
            let ext = url.pathExtension.lowercased()
            let hint = ext == "rar" ? "unrar" : ext == "7z" ? "7z" : nil
            completion([], hint.map { "No tool installed to read \(ext) archives — install \($0)" }
                ?? "Cannot read \(ext) archives")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let output = run(lister.tool, lister.arguments)
            let entries = parse(output, tool: lister.tool)
            DispatchQueue.main.async {
                completion(entries, entries.isEmpty ? "Archive is empty or could not be read" : nil)
            }
        }
    }

    /// Extracts the archive beside itself, into a folder named after it. With
    /// `entry` given, only that entry comes out — for a folder, everything
    /// under it — at its own path inside that folder, so a file three levels
    /// deep lands three levels deep and nothing else is unpacked.
    static func extract(
        _ url: URL, entry: Entry? = nil, completion: @escaping (URL?, String?) -> Void
    ) {
        let destination = OperationEngine.uniqueURL(
            for: url.deletingPathExtension(),
            fileManager: .default
        )

        let tool: (String, [String])?
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "ipa":
            // Members go between the archive and -d; unzip reads them as
            // patterns, so the name is escaped first.
            tool = ("/usr/bin/unzip", ["-q", url.path] + unzipMembers(for: entry) + ["-d", destination.path])
        case "tar", "tgz", "gz", "bz2", "tbz", "xz":
            // "--" ends the options, so a member whose name starts with a
            // dash is still a member. tar extracts a named folder with
            // everything under it, and matches names as patterns like unzip.
            tool = ("/usr/bin/tar", ["-xf", url.path, "-C", destination.path] + tarMembers(for: entry))
        case "7z": tool = sevenZip().map { ($0, ["x", url.path, "-o" + destination.path] + plainMembers(for: entry)) }
        case "rar": tool = which("unrar").map { ($0, ["x", url.path] + plainMembers(for: entry) + [destination.path + "/"]) }
        default: tool = nil
        }

        guard let tool else {
            completion(nil, "No tool installed to extract this archive")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
                return
            }
            let result = runCapturing(tool.0, tool.1)
            // unzip, 7z and unrar all exit 1 for warnings on an extraction
            // that completed: unzip's manual says "processing completed
            // successfully anyway", 7z's says "Warning (Non fatal error(s))".
            // tar has no such convention; from it, and for every status above
            // 1 from any tool, the extraction stopped early.
            //
            // unzip's 11 is "a name matched nothing". A folder entry is asked
            // for as both "folder/" and "folder/*", and for an empty folder
            // the second matches nothing while the folder itself still came
            // out, so 11 with something landed is that and not a failure.
            let toolName = (tool.0 as NSString).lastPathComponent
            let landed = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            let warned = (result.status == 1
                    && ["unzip", "7z", "7zz", "unrar"].contains(toolName))
                || (result.status == 11 && toolName == "unzip" && !landed.isEmpty)
            let failed = result.status != 0 && !warned
            DispatchQueue.main.async {
                if failed {
                    // Whatever landed before the tool died is incomplete, so
                    // remove it rather than reveal a partial folder as though
                    // it were the archive's contents.
                    try? FileManager.default.removeItem(at: destination)
                    completion(nil, failureReason(result.stderr, archive: url) ?? "Extraction failed")
                } else if landed.isEmpty {
                    try? FileManager.default.removeItem(at: destination)
                    completion(nil, "Nothing was extracted")
                } else {
                    completion(destination, nil)
                }
            }
        }
    }

    /// The line of a tool's stderr worth showing when extraction fails.
    ///
    /// unzip leads with the archive's name in brackets and then wraps its
    /// message over indented lines, so the first non-empty line on its own was
    /// "[/path/to/corrupt.zip]" — the reason ("End-of-central-directory
    /// signature not found") sat on the line after. This drops the banner
    /// and reads through the indented continuation up to the end of the
    /// first sentence.
    static func failureReason(_ stderr: String, archive: URL) -> String? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rest = lines.drop(while: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty
                || trimmed == "[\(archive.path)]"
                || trimmed.hasPrefix("Archive:")
        })
        guard let first = rest.first else { return nil }
        var message = first.trimmingCharacters(in: .whitespaces)
        rest = rest.dropFirst()
        while !message.hasSuffix("."),
              let next = rest.first, next.hasPrefix(" ") || next.hasPrefix("\t") {
            message += " " + next.trimmingCharacters(in: .whitespaces)
            rest = rest.dropFirst()
        }
        if let sentenceEnd = message.range(of: ". ") {
            message = String(message[..<sentenceEnd.lowerBound]) + "."
        }
        return message.isEmpty ? nil : message
    }

    /// Escapes the characters unzip and tar read as pattern syntax, so an
    /// entry called "shot [1].png" is matched by name and not as a set.
    static func escapePattern(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// unzip takes members between the archive and -d. A folder entry is
    /// listed as "folder/", which on its own only makes the folder; with
    /// "folder/*" beside it, what is inside comes too.
    static func unzipMembers(for entry: Entry?) -> [String] {
        guard let entry else { return [] }
        let escaped = escapePattern(entry.path)
        return entry.isDirectory ? [escaped, escaped + "*"] : [escaped]
    }

    /// tar members follow "--". tar extracts a named folder with its
    /// contents, so the folder's own path is enough.
    static func tarMembers(for entry: Entry?) -> [String] {
        guard let entry else { return [] }
        return ["--", escapePattern(entry.path)]
    }

    /// 7z and unrar take the name as listed, with no escaping to offer.
    static func plainMembers(for entry: Entry?) -> [String] {
        guard let entry else { return [] }
        return [entry.path]
    }

    /// Where an entry lands under the extraction folder: its listed path,
    /// without tar's leading "./" and without a folder's trailing slash.
    static func relativePath(of entry: Entry) -> String {
        var path = entry.path
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Arguments are passed as an array, never through a shell, so a filename
    /// containing a space or a quote cannot be read as a command.
    static func run(_ tool: String, _ arguments: [String]) -> String {
        runCapturing(tool, arguments).stdout
    }

    /// Like run, but keeps stderr and the exit status, which extraction needs:
    /// a tool that dies halfway can still leave files behind, and only the
    /// status tells the two cases apart.
    static func runCapturing(
        _ tool: String, _ arguments: [String]
    ) -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch { return ("", error.localizedDescription, -1) }
        // Drain stderr on another queue: reading the pipes one after the other
        // deadlocks when the tool fills the second pipe's buffer while the
        // first is still being read.
        var errData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    /// Each tool prints a different shape, so parsing is per tool.
    static func parse(_ output: String, tool: String) -> [Entry] {
        let name = (tool as NSString).lastPathComponent
        switch name {
        case "unzip": return parseUnzip(output)
        case "tar": return parseTar(output)
        case "7z", "7zz": return parse7z(output)
        default: return parseNames(output)
        }
    }

    /// `unzip -l` prints "length date time name", wrapped in a header and a
    /// total line. Only rows whose first field is a number are entries, which
    /// skips both without having to count lines.
    static func parseUnzip(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let size = Int64(parts[0]) else { return nil }
            let path = parts[3...].joined(separator: " ")
            // The footer ("12345  3 files") splits into only three fields, so
            // the four-field minimum above already rejects it. No check on the
            // path itself: an entry really can be named "3 files".
            guard !path.isEmpty else { return nil }
            return Entry(path: path, size: size, isDirectory: path.hasSuffix("/"))
        }
    }

    /// `tar -tvf` prints "mode links owner group size month day time name" —
    /// nine fields before the path, not six.
    static func parseTar(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { return nil }
            // Find the size by walking to the last purely numeric field before
            // the date, which is robust to owner names containing digits.
            let size = Int64(parts[4]) ?? 0
            let path = parts[8...].joined(separator: " ")
            guard !path.isEmpty else { return nil }
            return Entry(path: path, size: size, isDirectory: line.hasPrefix("d") || path.hasSuffix("/"))
        }
    }

    /// `7z l -ba` prints the table body without header or footer:
    /// "date time attr size compressed name". The columns are fixed width —
    /// date and time take 19 characters, attr 5, size and compressed 12 each —
    /// and the name starts at column 53. Cutting at offsets rather than
    /// splitting on spaces matters because the compressed column is blank for
    /// some entries and names can contain spaces.
    static func parse7z(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            guard line.count > 53 else { return nil }
            let attrStart = line.index(line.startIndex, offsetBy: 20)
            let attrEnd = line.index(line.startIndex, offsetBy: 25)
            let sizeStart = line.index(line.startIndex, offsetBy: 26)
            let sizeEnd = line.index(line.startIndex, offsetBy: 38)
            let nameStart = line.index(line.startIndex, offsetBy: 53)

            let path = String(line[nameStart...])
            guard !path.isEmpty else { return nil }
            let size = Int64(line[sizeStart..<sizeEnd].trimmingCharacters(in: .whitespaces)) ?? 0
            return Entry(
                path: path, size: size,
                isDirectory: line[attrStart..<attrEnd].contains("D")
            )
        }
    }

    /// Fallback: one path per line, size unknown rather than invented.
    static func parseNames(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return Entry(path: path, size: 0, isDirectory: path.hasSuffix("/"))
        }
    }
}

/// Lists an archive's contents in a sheet, with a button to extract it — the
/// whole thing, or only the row that is selected.
final class ArchiveViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: ArchiveSheetPanel?
    private weak var owner: MainWindowController?
    private var url: URL!
    private var entries: [Archive.Entry] = []
    private var table: NSTableView!
    private var summary: NSTextField!
    private var extractButton: NSButton!

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    func present(for controller: MainWindowController, url: URL) {
        guard let host = controller.window, panel == nil else { return }
        owner = controller
        self.url = url
        // The new table asks this controller for rows the moment the sheet
        // first draws. Without a reset it would show the previous archive's
        // entries under the new title until the new listing returns.
        entries = []

        let panel = ArchiveSheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = url.lastPathComponent
        panel.closeSheet = { [weak self] in self?.dismiss() }

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 600
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        summary = NSTextField(labelWithString: "Reading…")
        summary.font = Theme.status
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false

        extractButton = NSButton(title: "Extract", target: self, action: #selector(extractArchive))
        let close = NSButton(title: "Close", target: self, action: #selector(dismiss))
        // Escape closes the sheet, the way Cancel does in the other panels.
        // Without a key equivalent the button was the only way out, and every
        // key pressed while the sheet was up went to the sheet and was lost.
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [close, extractButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [scroll, summary, buttons] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            summary.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        self.panel = panel

        host.beginSheet(panel) { [weak self] _ in
            self?.panel = nil
            self?.owner = nil
            self?.url = nil
        }

        Archive.list(url) { [weak self] entries, error in
            // The controller lives as long as its window, so a listing that
            // was still running when the sheet closed can land here after a
            // different archive was opened. Only the request that matches the
            // current sheet may touch the table.
            guard let self, self.url == url, self.panel != nil else { return }
            self.entries = entries
            self.table.reloadData()
            if let error {
                self.summary.stringValue = error
                self.summary.textColor = Theme.danger
            } else {
                let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
                self.summary.stringValue =
                    "\(entries.count) item\(entries.count == 1 ? "" : "s"), \(Self.byteFormatter.string(fromByteCount: bytes)) uncompressed"
            }
        }
    }

    @objc private func dismiss() {
        guard let panel, let host = panel.sheetParent else { return }
        host.endSheet(panel)
    }

    /// The row the user picked, or nil for the whole archive. Clicking a row
    /// used to change nothing: Extract unpacked everything regardless.
    private var selectedEntry: Archive.Entry? {
        let row = table.selectedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    @objc private func extractArchive() {
        let controller = owner
        let source = url!
        let entry = selectedEntry
        summary.stringValue = entry.map { "Extracting \($0.name)…" } ?? "Extracting…"
        summary.textColor = .secondaryLabelColor
        Archive.extract(source, entry: entry) { [weak self] destination, error in
            guard let self else { return }
            if let error {
                self.summary.stringValue = error
                self.summary.textColor = Theme.danger
                return
            }
            self.dismiss()
            guard let destination else { return }
            // Land on the entry itself when one was asked for. The path is
            // where the tool puts it; a tool that laid it out differently
            // still gets the folder it made shown.
            if let entry {
                let extracted = destination.appendingPathComponent(Archive.relativePath(of: entry))
                if FileManager.default.fileExists(atPath: extracted.path) {
                    controller?.reveal(extracted)
                    return
                }
            }
            controller?.reveal(destination)
        }
    }

    /// The button says what it will do, so a selection is not a surprise.
    func tableViewSelectionDidChange(_ notification: Notification) {
        extractButton.title = selectedEntry == nil ? "Extract" : "Extract Selected"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]

        // A plain cell view, not FileCellView: that one lays its text field
        // out by hand across the whole width, which put the name under the
        // size. Here the row view sets the background style, and both
        // labels follow it onto a selection.
        let cell = EntryCellView()
        let name = NSTextField(labelWithString: entry.path)
        name.font = Theme.rowName
        name.textColor = entry.isDirectory ? .secondaryLabelColor : .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let size = NSTextField(labelWithString: entry.isDirectory ? "" : Self.byteFormatter.string(fromByteCount: entry.size))
        size.font = Theme.rowNumeric
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(name)
        cell.addSubview(size)
        cell.textField = name
        cell.sizeField = size

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10),
            size.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            size.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            size.widthAnchor.constraint(equalToConstant: 80),
        ])
        return cell
    }
}

/// The sheet's own window, so that ⌘W closes it.
///
/// A sheet is not in its host window's responder chain, so the main menu's
/// ⌘W found no target and the key did nothing. The Close button carries
/// Escape as its key equivalent; a button can hold only one, so the second
/// key is answered here. A key equivalent offered to the key window is taken
/// before the menu bar sees it, and a disabled menu item hands it back, so
/// this runs whichever way round the event travels.
private final class ArchiveSheetPanel: NSPanel {
    var closeSheet: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock and the function flags ride along on ordinary key presses,
        // so they come off before the command key is compared.
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            closeSheet?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// An archive row: the name is the cell's text field, so the row view turns it
/// white on a filled selection; the size is passed the same style by hand,
/// since a cell view only forwards it to its one text field.
private final class EntryCellView: NSTableCellView {
    var sizeField: NSTextField?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { sizeField?.cell?.backgroundStyle = backgroundStyle }
    }
}
