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
            return which("7z").map { ($0, ["l", "-ba", path]) }
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

    /// Extracts the whole archive beside itself, into a folder named after it.
    static func extract(_ url: URL, completion: @escaping (URL?, String?) -> Void) {
        let destination = OperationEngine.uniqueURL(
            for: url.deletingPathExtension(),
            fileManager: .default
        )

        let tool: (String, [String])?
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "ipa": tool = ("/usr/bin/unzip", ["-q", url.path, "-d", destination.path])
        case "tar", "tgz", "gz", "bz2", "tbz", "xz":
            tool = ("/usr/bin/tar", ["-xf", url.path, "-C", destination.path])
        case "7z": tool = which("7z").map { ($0, ["x", url.path, "-o" + destination.path]) }
        case "rar": tool = which("unrar").map { ($0, ["x", url.path, destination.path + "/"]) }
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
            // unrar exits 1 for warnings on an extraction that completed;
            // every other status, from any tool, means it stopped early.
            let failed = result.status != 0
                && !(tool.0.hasSuffix("unrar") && result.status == 1)
            let landed = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            DispatchQueue.main.async {
                if failed {
                    // Whatever landed before the tool died is incomplete, so
                    // remove it rather than reveal a partial folder as though
                    // it were the archive's contents.
                    try? FileManager.default.removeItem(at: destination)
                    let reason = result.stderr
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty }
                    completion(nil, reason ?? "Extraction failed")
                } else if landed.isEmpty {
                    try? FileManager.default.removeItem(at: destination)
                    completion(nil, "Nothing was extracted")
                } else {
                    completion(destination, nil)
                }
            }
        }
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

/// Lists an archive's contents in a sheet, with a button to extract it.
final class ArchiveViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private weak var owner: MainWindowController?
    private var url: URL!
    private var entries: [Archive.Entry] = []
    private var table: NSTableView!
    private var summary: NSTextField!

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    func present(for controller: MainWindowController, url: URL) {
        guard let host = controller.window, panel == nil else { return }
        owner = controller
        self.url = url

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = url.lastPathComponent

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

        let extract = NSButton(title: "Extract", target: self, action: #selector(extractArchive))
        let close = NSButton(title: "Close", target: self, action: #selector(dismiss))
        let buttons = NSStackView(views: [close, extract])
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

    @objc private func extractArchive() {
        let controller = owner
        let source = url!
        summary.stringValue = "Extracting…"
        Archive.extract(source) { [weak self] destination, error in
            guard let self else { return }
            if let error {
                self.summary.stringValue = error
                self.summary.textColor = Theme.danger
                return
            }
            self.dismiss()
            if let destination { controller?.reveal(destination) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]

        let cell = FileCellView()
        let name = NSTextField(labelWithString: entry.path)
        name.font = Theme.rowName
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let size = NSTextField(labelWithString: entry.isDirectory ? "" : Self.byteFormatter.string(fromByteCount: entry.size))
        size.font = Theme.rowNumeric
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(name)
        cell.addSubview(size)
        cell.textField = name
        cell.restingTextColor = entry.isDirectory ? .secondaryLabelColor : .labelColor

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
