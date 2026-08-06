import AppKit

struct FileItem {
    let url: URL
    let name: String
    /// True for real directories and for symlinks that resolve to directories.
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    /// Byte size for files; -1 for directories.
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String

    var opensAsFolder: Bool { isDirectory && !isPackage }
}

enum ViewMode: String, CaseIterable {
    case list, icon, column

    var title: String {
        switch self {
        case .list: return "As List"
        case .icon: return "As Icons"
        case .column: return "As Columns"
        }
    }
}

enum SortKey: String, Codable, CaseIterable {
    case name, ext, size, kind, modified, created

    var title: String {
        switch self {
        case .name: return "Name"
        case .ext: return "Extension"
        case .size: return "Size"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        }
    }

    /// Table column identifier, where the column exists.
    var columnID: String { rawValue }
}

struct SortDescriptorSpec: Codable, Equatable {
    var key: SortKey
    var ascending: Bool
}

/// An ordered list of sort keys, primary first. Files equal on the primary key
/// fall through to the next, and anything still equal ends in name order.
struct SortOrder: Codable, Equatable {
    var descriptors: [SortDescriptorSpec]

    /// Newest first. A folder is opened far more often to find what changed
    /// than to find something alphabetically, and the thing you just saved is
    /// the thing you are usually after.
    static let `default` = SortOrder(descriptors: [SortDescriptorSpec(key: .modified, ascending: false)])

    /// How many keys deep a sort may go before it stops being comprehensible.
    static let maximumDepth = 4

    var primary: SortDescriptorSpec? { descriptors.first }

    func direction(for key: SortKey) -> Bool? {
        descriptors.first { $0.key == key }?.ascending
    }

    func position(of key: SortKey) -> Int? {
        descriptors.firstIndex { $0.key == key }
    }

    /// Clicking a column: make it primary, or flip it when it already is.
    mutating func makePrimary(_ key: SortKey) {
        if descriptors.first?.key == key {
            descriptors[0].ascending.toggle()
            return
        }
        let existing = descriptors.first { $0.key == key }
        descriptors.removeAll { $0.key == key }
        descriptors.insert(SortDescriptorSpec(key: key, ascending: existing?.ascending ?? true), at: 0)
        if descriptors.count > Self.maximumDepth { descriptors.removeLast() }
    }

    /// Shift-clicking a column: keep the current sort and break its ties with
    /// this key, or flip that key if it is already part of the sort.
    mutating func addSecondary(_ key: SortKey) {
        if let index = descriptors.firstIndex(where: { $0.key == key }) {
            descriptors[index].ascending.toggle()
            return
        }
        descriptors.append(SortDescriptorSpec(key: key, ascending: true))
        if descriptors.count > Self.maximumDepth { descriptors.removeFirst() }
    }

    mutating func reverse() {
        for i in descriptors.indices { descriptors[i].ascending.toggle() }
    }

    mutating func clearSecondary() {
        if descriptors.count > 1 { descriptors = [descriptors[0]] }
    }

    /// "Name ↑, then Size ↓" — shown in the status bar so a multi-key sort is
    /// never a mystery.
    var summary: String {
        descriptors
            .map { "\($0.key.title) \($0.ascending ? "↑" : "↓")" }
            .joined(separator: ", then ")
    }
}

private func compare(_ a: FileItem, _ b: FileItem, by key: SortKey) -> ComparisonResult {
    switch key {
    case .name:
        return a.name.localizedStandardCompare(b.name)
    case .ext:
        return a.url.pathExtension.localizedStandardCompare(b.url.pathExtension)
    case .size:
        return a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
    case .kind:
        return a.kind.localizedStandardCompare(b.kind)
    case .modified:
        return a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
    case .created:
        return a.created == b.created ? .orderedSame : (a.created < b.created ? .orderedAscending : .orderedDescending)
    }
}

func sortItems(_ items: [FileItem], order: SortOrder, foldersFirst: Bool) -> [FileItem] {
    items.sorted { a, b in
        if foldersFirst && a.opensAsFolder != b.opensAsFolder { return a.opensAsFolder }

        for descriptor in order.descriptors {
            let result = compare(a, b, by: descriptor.key)
            guard result != .orderedSame else { continue }
            return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        // Items equal on every chosen key stay in name order whichever way the
        // columns point; reversing the tiebreak too made a descending sort
        // shuffle names within each group.
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Loads directory listings off the main thread. Stale loads are dropped:
/// only the most recent load's completion fires.
final class DirectoryLoader {
    private var generation = 0
    private let queue = DispatchQueue(label: "app.soquel.dirload", qos: .userInitiated)

    /// Must be called on the main thread.
    func load(_ url: URL, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        generation += 1
        let gen = generation
        queue.async { [weak self] in
            let result: Result<[FileItem], Error>
            do {
                result = .success(try Self.read(url, showHidden: showHidden))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                completion(result)
            }
        }
    }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey,
    ]

    static func read(_ url: URL, showHidden: Bool) throws -> [FileItem] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: options)
        return urls.map { itemURL in
            let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
            let isSymlink = values?.isSymbolicLink ?? false
            var isDir = values?.isDirectory ?? false
            if isSymlink {
                var d: ObjCBool = false
                if fm.fileExists(atPath: itemURL.path, isDirectory: &d) { isDir = d.boolValue }
            }
            return FileItem(
                url: itemURL,
                name: itemURL.lastPathComponent,
                isDirectory: isDir,
                isPackage: values?.isPackage ?? false,
                isSymlink: isSymlink,
                isHidden: values?.isHidden ?? false,
                size: isDir ? -1 : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                created: values?.creationDate ?? .distantPast,
                kind: values?.localizedTypeDescription ?? (isDir ? "Folder" : "Document")
            )
        }
    }
}

/// Fires on any write/rename/delete inside the watched directory.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    /// Opens the directory off the main thread and hands back a watcher.
    ///
    /// `open()` blocks — on a protected folder it waits for the system's
    /// permission prompt, and on a stalled network mount it waits indefinitely.
    /// Doing that inline froze the app at launch before its window appeared.
    static func make(url: URL, onChange: @escaping () -> Void, ready: @escaping (DirectoryWatcher?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fd = open(url.path, O_EVTONLY)
            DispatchQueue.main.async {
                guard fd >= 0 else { return ready(nil) }
                ready(DirectoryWatcher(descriptor: fd, onChange: onChange))
            }
        }
    }

    private init(descriptor fd: Int32, onChange: @escaping () -> Void) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit {
        source?.cancel()
    }
}
