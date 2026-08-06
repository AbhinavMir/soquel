import AppKit

/// Reading Finder's `.DS_Store`, never writing one.
///
/// The asymmetry is deliberate. Scattering a hidden file into every folder
/// anyone looks at is the thing people dislike about Finder, and this
/// application strips those files out of the archives it makes — writing them
/// would contradict that. But a `.DS_Store` already sitting in a folder knows
/// that folder should be in icon view, and ignoring a file that is right there
/// to preserve a principle helps nobody.
///
/// The format is a Buddy allocator holding a B-tree, reverse-engineered rather
/// than documented, so everything here fails to nil rather than trusting a
/// length it was handed.
enum DSStore {
    /// What is worth taking out of one.
    struct Settings: Equatable {
        var viewMode: ViewMode?
        var iconSize: Double?
        var sortColumn: String?
        var sortAscending: Bool?
        /// Column identifier to width, in Finder's names.
        var columnWidths: [String: Double] = [:]

        var isEmpty: Bool {
            viewMode == nil && iconSize == nil && sortColumn == nil && columnWidths.isEmpty
        }
    }

    /// One entry: which file it describes, which setting, and its value.
    struct Record {
        let filename: String
        let key: String
        let value: Value
    }

    enum Value {
        case bool(Bool)
        case int(Int64)
        case string(String)
        case type(String)
        case blob(Data)
    }

    // MARK: - Reading a folder's settings

    /// The settings Finder recorded for `directory`.
    ///
    /// A folder's own settings live in its parent's file under the folder's
    /// name; its own file describes its children. Finder also writes a "."
    /// entry into the folder's own file, so both are tried — own file first,
    /// because it is the one that travels with the folder.
    static func settings(for directory: URL) -> Settings? {
        if let own = records(in: directory.appendingPathComponent(".DS_Store")) {
            let found = settings(from: own, named: ".")
            if !found.isEmpty { return found }
        }
        let parent = directory.deletingLastPathComponent()
        guard parent != directory,
              let outer = records(in: parent.appendingPathComponent(".DS_Store"))
        else { return nil }
        let found = settings(from: outer, named: directory.lastPathComponent)
        return found.isEmpty ? nil : found
    }

    /// Turns the records naming one file into settings.
    static func settings(from records: [Record], named name: String) -> Settings {
        var settings = Settings()
        for record in records where record.filename == name {
            switch record.key {
            case "vstl":
                if case .type(let style) = record.value { settings.viewMode = viewMode(for: style) }
            case "icvp":
                if case .blob(let data) = record.value, let plist = plist(from: data) {
                    settings.iconSize = plist["iconSize"] as? Double
                }
            case "lsvp", "lsvP":
                if case .blob(let data) = record.value, let plist = plist(from: data) {
                    apply(listViewPlist: plist, to: &settings)
                }
            default:
                break
            }
        }
        return settings
    }

    /// Finder's four-character view styles.
    static func viewMode(for style: String) -> ViewMode? {
        switch style {
        case "icnv": return .icon
        case "clmv": return .column
        case "Nlsv", "lsvw": return .list
        // Cover Flow has no equivalent here, and guessing one would put someone
        // in a view they never chose.
        default: return nil
        }
    }

    /// Finder's list-view plist: which column it sorts by, which way, and how
    /// wide each column is.
    static func apply(listViewPlist plist: [String: Any], to settings: inout Settings) {
        if let sort = plist["sortColumn"] as? String { settings.sortColumn = sort }
        if let ascending = plist["ascending"] as? Bool { settings.sortAscending = ascending }

        // Two shapes exist: an array of column dictionaries in newer files, a
        // dictionary keyed by identifier in older ones.
        if let columns = plist["columns"] as? [[String: Any]] {
            for column in columns {
                guard let identifier = column["identifier"] as? String,
                      let width = column["width"] as? Double
                else { continue }
                settings.columnWidths[identifier] = width
            }
        } else if let columns = plist["columns"] as? [String: [String: Any]] {
            for (identifier, column) in columns {
                guard let width = column["width"] as? Double else { continue }
                settings.columnWidths[identifier] = width
            }
        }
    }

    /// Finder's column names, in this application's terms.
    static func columnIdentifier(forFinder name: String) -> String? {
        switch name {
        case "name": return "name"
        case "size", "ubsz": return "size"
        case "kind": return "kind"
        case "modified", "dateModified": return "modified"
        case "created", "dateCreated": return "created"
        default: return nil
        }
    }

    static func plist(from data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }

    // MARK: - The file

    /// Every record in a `.DS_Store`, or nil when it is missing or unreadable.
    static func records(in file: URL) -> [Record]? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return records(in: data)
    }

    static func records(in data: Data) -> [Record]? {
        let reader = Reader(data)

        // Header: an alignment word, "Bud1", then where the allocator lives.
        guard reader.u32(at: 0) == 1, reader.string(at: 4, count: 4) == "Bud1",
              let allocatorOffset = reader.u32(at: 8).map(Int.init)
        else { return nil }

        guard let blockCount = reader.u32(at: allocatorOffset + 4).map(Int.init),
              blockCount < 1_000_000
        else { return nil }

        // The addresses run after the count and one unused word. The table is
        // padded to a multiple of 256 entries, which is where the directory
        // starts.
        let addressesStart = allocatorOffset + 12
        var addresses: [UInt32] = []
        addresses.reserveCapacity(blockCount)
        for index in 0..<blockCount {
            guard let value = reader.u32(at: addressesStart + index * 4) else { return nil }
            addresses.append(value)
        }

        let padded = ((blockCount + 255) / 256) * 256
        var cursor = addressesStart + padded * 4
        guard let directoryCount = reader.u32(at: cursor).map(Int.init), directoryCount < 10_000
        else { return nil }
        cursor += 4

        var root: Int?
        for _ in 0..<directoryCount {
            guard let length = reader.u8(at: cursor).map(Int.init),
                  let name = reader.string(at: cursor + 1, count: length),
                  let block = reader.u32(at: cursor + 1 + length).map(Int.init)
            else { return nil }
            if name == "DSDB" { root = block }
            cursor += 1 + length + 4
        }

        guard let masterBlock = root, addresses.indices.contains(masterBlock),
              let masterOffset = Self.offset(of: addresses[masterBlock]),
              let rootNode = reader.u32(at: masterOffset).map(Int.init)
        else { return nil }

        var found: [Record] = []
        var visited = Set<Int>()
        walk(node: rootNode, addresses: addresses, reader: reader,
             visited: &visited, into: &found)
        return found
    }

    /// A block address packs its offset and its size: the low five bits are the
    /// power-of-two size, the rest is the offset, and everything is four bytes
    /// further into the file than it claims.
    static func offset(of address: UInt32) -> Int? {
        let offset = Int(address & ~0x1F) + 4
        return offset > 0 ? offset : nil
    }

    /// Walks one node of the tree, and its children.
    ///
    /// `visited` stops a file whose blocks point at each other from walking for
    /// ever, which a corrupt or hostile one could otherwise do.
    private static func walk(
        node: Int, addresses: [UInt32], reader: Reader,
        visited: inout Set<Int>, into found: inout [Record]
    ) {
        guard !visited.contains(node), visited.count < 10_000,
              addresses.indices.contains(node),
              let base = offset(of: addresses[node]),
              let next = reader.u32(at: base).map(Int.init),
              let count = reader.u32(at: base + 4).map(Int.init),
              count < 100_000
        else { return }
        visited.insert(node)

        var cursor = base + 8
        for _ in 0..<count {
            // An internal node puts a child block before each record.
            if next != 0 {
                guard let child = reader.u32(at: cursor).map(Int.init) else { return }
                cursor += 4
                walk(node: child, addresses: addresses, reader: reader,
                     visited: &visited, into: &found)
            }
            guard let (record, after) = readRecord(reader, at: cursor) else { return }
            found.append(record)
            cursor = after
        }
        if next != 0 {
            walk(node: next, addresses: addresses, reader: reader,
                 visited: &visited, into: &found)
        }
    }

    /// One record, and where the next one starts.
    static func readRecord(_ reader: Reader, at start: Int) -> (Record, Int)? {
        guard let units = reader.u32(at: start).map(Int.init), units < 4096 else { return nil }
        let nameBytes = units * 2
        guard let filename = reader.utf16BE(at: start + 4, bytes: nameBytes),
              let key = reader.string(at: start + 4 + nameBytes, count: 4),
              let type = reader.string(at: start + 8 + nameBytes, count: 4)
        else { return nil }

        var cursor = start + 12 + nameBytes
        let value: Value

        switch type {
        case "bool":
            guard let byte = reader.u8(at: cursor) else { return nil }
            value = .bool(byte != 0)
            cursor += 1
        case "long", "shor":
            guard let number = reader.u32(at: cursor) else { return nil }
            value = .int(Int64(number))
            cursor += 4
        case "type":
            guard let text = reader.string(at: cursor, count: 4) else { return nil }
            value = .type(text)
            cursor += 4
        case "comp", "dutc":
            guard reader.u32(at: cursor) != nil, reader.u32(at: cursor + 4) != nil else { return nil }
            value = .int(0)
            cursor += 8
        case "blob":
            guard let length = reader.u32(at: cursor).map(Int.init), length < 10_000_000,
                  let bytes = reader.data(at: cursor + 4, count: length)
            else { return nil }
            value = .blob(bytes)
            cursor += 4 + length
        case "ustr":
            guard let length = reader.u32(at: cursor).map(Int.init), length < 100_000,
                  let text = reader.utf16BE(at: cursor + 4, bytes: length * 2)
            else { return nil }
            value = .string(text)
            cursor += 4 + length * 2
        default:
            // An unknown type has an unknown length, so the rest of the node
            // cannot be walked past it.
            return nil
        }

        return (Record(filename: filename, key: key, value: value), cursor)
    }

    /// Bounds-checked reads. Every accessor returns nil rather than trapping,
    /// because the lengths come out of a file this application did not write.
    struct Reader {
        private let data: Data

        init(_ data: Data) { self.data = data }

        func u8(at offset: Int) -> UInt8? {
            guard offset >= 0, offset < data.count else { return nil }
            return data[data.startIndex + offset]
        }

        func u32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let start = data.startIndex + offset
            return (UInt32(data[start]) << 24) | (UInt32(data[start + 1]) << 16)
                | (UInt32(data[start + 2]) << 8) | UInt32(data[start + 3])
        }

        func data(at offset: Int, count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
            let start = data.startIndex + offset
            return data[start..<(start + count)]
        }

        func string(at offset: Int, count: Int) -> String? {
            guard let bytes = data(at: offset, count: count) else { return nil }
            return String(data: bytes, encoding: .ascii)
        }

        func utf16BE(at offset: Int, bytes count: Int) -> String? {
            guard let bytes = data(at: offset, count: count) else { return nil }
            return String(data: bytes, encoding: .utf16BigEndian)
        }
    }
}
