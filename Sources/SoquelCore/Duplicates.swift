import AppKit

/// Finding files that are byte-for-byte the same, and folders whose whole
/// contents are.
enum Duplicates {
    struct Group {
        let hash: String
        let size: Int64
        var urls: [URL]
        /// Whole folders whose contents match, rather than files.
        var isFolder = false

        /// What is reclaimed by keeping one and trashing the rest.
        var reclaimable: Int64 { size * Int64(max(0, urls.count - 1)) }
    }

    struct Report {
        var groups: [Group] = []

        var fileGroups: [Group] { groups.filter { !$0.isFolder } }
        var folderGroups: [Group] { groups.filter(\.isFolder) }
        var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

        var summary: String {
            guard !groups.isEmpty else { return "No duplicates" }
            let n = groups.count == 1 ? "1 group" : "\(groups.count) groups"
            let size = ByteCountFormatter.string(fromByteCount: totalReclaimable, countStyle: .file)
            return "\(n) · \(size) reclaimable"
        }
    }

    /// Groups files by size first and only hashes where sizes collide. Hashing
    /// every file in a large tree is the slow way to learn that most of them
    /// are unique.
    static func groupsBySize(_ files: [(url: URL, size: Int64)]) -> [[URL]] {
        var bySize: [Int64: [URL]] = [:]
        for file in files where file.size > 0 {
            bySize[file.size, default: []].append(file.url)
        }
        return bySize.values.filter { $0.count > 1 }.map { $0 }
    }

    /// Walks `roots` and returns the duplicate groups.
    ///
    /// Zero-length files are skipped. Every empty file matches every other
    /// empty file, which is true and useless, and would bury the real results.
    static func scan(
        roots: [URL],
        includeHidden: Bool,
        isCancelled: () -> Bool = { false },
        hash: (URL) -> String? = Checksum.sha256(of:)
    ) -> Report {
        var files: [(url: URL, size: Int64)] = []
        var folders: [URL] = []

        for root in roots {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { options.insert(.skipsHiddenFiles) }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: options
            ) else { continue }

            for case let url as URL in walker {
                if isCancelled() { return Report() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    folders.append(url)
                } else {
                    files.append((url, Int64(values.fileSize ?? 0)))
                }
            }
        }

        var report = Report()
        var hashes: [URL: String] = [:]

        for candidates in groupsBySize(files) {
            if isCancelled() { return Report() }
            var byHash: [String: [URL]] = [:]
            for url in candidates {
                guard let digest = hash(url) else { continue }
                hashes[url] = digest
                byHash[digest, default: []].append(url)
            }
            let size = files.first { $0.url == candidates[0] }?.size ?? 0
            for (digest, urls) in byHash where urls.count > 1 {
                report.groups.append(Group(hash: digest, size: size, urls: urls.sorted { $0.path < $1.path }))
            }
        }

        report.groups.append(contentsOf: folderGroups(folders, fileHashes: hashes, isCancelled: isCancelled))
        report.groups.sort { $0.reclaimable > $1.reclaimable }
        return report
    }

    /// Folders whose entire contents match. The research asks for this
    /// explicitly: two copies of a project directory show up as a hundred
    /// separate file pairs otherwise, which is the same information in a form
    /// nobody can act on.
    static func folderGroups(
        _ folders: [URL], fileHashes: [URL: String], isCancelled: () -> Bool = { false }
    ) -> [Group] {
        var byFingerprint: [String: [URL]] = [:]
        var sizes: [URL: Int64] = [:]

        for folder in folders {
            if isCancelled() { return [] }
            guard let (fingerprint, size) = fingerprint(of: folder, fileHashes: fileHashes) else { continue }
            byFingerprint[fingerprint, default: []].append(folder)
            sizes[folder] = size
        }

        var groups: [Group] = []
        for (fingerprint, urls) in byFingerprint where urls.count > 1 {
            // A folder nested inside another duplicate folder is not reported
            // separately; trashing the parent takes it anyway, and listing both
            // double-counts what would be reclaimed.
            let outermost = urls.filter { candidate in
                !urls.contains { $0 != candidate && candidate.path.hasPrefix($0.path + "/") }
            }
            guard outermost.count > 1 else { continue }
            groups.append(Group(
                hash: fingerprint,
                size: sizes[outermost[0]] ?? 0,
                urls: outermost.sorted { $0.path < $1.path },
                isFolder: true
            ))
        }
        return groups
    }

    /// A folder's fingerprint is its contents' names and hashes, sorted. nil
    /// when any file in it was never hashed — an unhashed file means the
    /// contents are not known, and guessing they match is how a duplicate
    /// finder deletes something it should not have.
    static func fingerprint(of folder: URL, fileHashes: [URL: String]) -> (String, Int64)? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return nil }

        var entries: [String] = []
        var total: Int64 = 0

        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true { return nil }
            if values.isDirectory == true { continue }
            guard let digest = fileHashes[url], let relative = relativePath(of: url, under: folder) else { return nil }
            entries.append("\(relative):\(digest)")
            total += Int64(values.fileSize ?? 0)
        }

        guard !entries.isEmpty else { return nil }
        return (entries.sorted().joined(separator: "\n"), total)
    }

    /// Which of a group to keep when nothing else says otherwise: the shortest
    /// path, then alphabetical. The copy in `~/Documents/report.pdf` outlives
    /// the one in `~/Documents/old/backup 2/report.pdf`.
    static func suggestedKeep(_ group: Group) -> URL? {
        group.urls.min {
            let a = $0.pathComponents.count, b = $1.pathComponents.count
            return a == b ? $0.path < $1.path : a < b
        }
    }

    /// What a group would have trashed: everything except the kept copy.
    static func trashable(_ group: Group, keeping keep: URL?) -> [URL] {
        guard let keep else { return [] }
        return group.urls.filter { $0 != keep }
    }
}
