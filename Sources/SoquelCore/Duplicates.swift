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

        let folderDupes = folderGroups(
            folders, fileHashes: hashes, includeHidden: includeHidden, isCancelled: isCancelled
        )
        // A file group whose copies sit at the same relative path across one
        // folder group's members is that folder group restated one file at a
        // time: it double-counts the reclaimable bytes, and ticking both means
        // the file trashes fail after the folder has already moved. Location
        // alone is not enough to drop a group — internal duplicates within a
        // single folder, or copies spread across two folder groups, survive
        // the folder trash and must stay in the report.
        if !folderDupes.isEmpty {
            report.groups.removeAll { group in
                folderDupes.contains { subsumes($0, fileGroup: group) }
            }
        }
        report.groups.append(contentsOf: folderDupes)
        report.groups.sort { $0.reclaimable > $1.reclaimable }
        return report
    }

    /// Folders whose entire contents match. The research asks for this
    /// explicitly: two copies of a project directory show up as a hundred
    /// separate file pairs otherwise, which is the same information in a form
    /// nobody can act on.
    static func folderGroups(
        _ folders: [URL], fileHashes: [URL: String], includeHidden: Bool,
        isCancelled: () -> Bool = { false }
    ) -> [Group] {
        var byFingerprint: [String: [URL]] = [:]
        var sizes: [URL: Int64] = [:]

        for folder in folders {
            if isCancelled() { return [] }
            guard let (fingerprint, size) = fingerprint(
                of: folder, fileHashes: fileHashes, includeHidden: includeHidden
            ) else { continue }
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
        // {A, B} identical means every subfolder of A matches its twin in B,
        // so {A/s, B/s} lands under its own fingerprint as a separate group.
        // Reporting both restates the parent: the reclaimable bytes are
        // counted twice, and ticking both trashes B first and then fails on
        // B/s, which already moved inside it. A group is dropped only when
        // its members map one-to-one onto the members of another group —
        // trashing all but one parent then resolves it completely. Containment
        // alone is not enough: with A holding identical twins s and t and B a
        // copy of A, the group {A/s, A/t, B/s, B/t} sits entirely inside
        // {A, B}, yet trashing B still leaves the real pair {A/s, A/t}, so
        // that group must stay in the report.
        return groups.filter { group in
            !groups.contains { other in
                guard other.urls != group.urls, other.urls.count == group.urls.count else {
                    return false
                }
                let parents = group.urls.compactMap { member in
                    other.urls.first { member.path.hasPrefix($0.path + "/") }
                }
                return parents.count == group.urls.count
                    && Set(parents).count == other.urls.count
            }
        }
    }

    /// Whether trashing all but one member of `folder` removes all but one
    /// copy in `fileGroup`: exactly one copy per member, all at the same
    /// relative path. Only then does the folder group make the file group
    /// redundant.
    static func subsumes(_ folder: Group, fileGroup: Group) -> Bool {
        guard fileGroup.urls.count == folder.urls.count else { return false }
        var relatives: Set<String> = []
        var members: Set<URL> = []
        for url in fileGroup.urls {
            guard let member = folder.urls.first(where: { url.path.hasPrefix($0.path + "/") }),
                  let relative = relativePath(of: url, under: member)
            else { return false }
            relatives.insert(relative)
            members.insert(member)
        }
        return relatives.count == 1 && members.count == folder.urls.count
    }

    /// Files that are Finder bookkeeping, not content. Two folders that
    /// differ only in these are duplicates for every purpose this panel
    /// serves, so they stay out of the fingerprint when hidden files are off.
    static let noiseNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    /// A folder's fingerprint is its contents' names and hashes, sorted. nil
    /// when any file in it was never hashed — an unhashed file means the
    /// contents are not known, and guessing they match is how a duplicate
    /// finder deletes something it should not have.
    ///
    /// Hidden files count even when the scan skipped them. A .git or .env
    /// that only one folder has makes the folders different, and skipping it
    /// here declared them identical and offered to trash one. Such hidden
    /// files were never hashed, so the folder comes back nil rather than
    /// grouped. Only known Finder noise is left out, which is what kept a
    /// .DS_Store the scan never saw from turning every real folder nil.
    /// Zero-length files take part by name alone — the scan never hashes
    /// them, and empty is empty — but a fingerprint needs at least one hashed
    /// file: folders whose files are all empty would otherwise group by name
    /// alone to reclaim zero bytes, a match the scan itself calls useless.
    static func fingerprint(
        of folder: URL, fileHashes: [URL: String], includeHidden: Bool
    ) -> (String, Int64)? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return nil }

        var entries: [String] = []
        var total: Int64 = 0
        var hashed = 0

        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true { return nil }
            if values.isDirectory == true { continue }
            if !includeHidden, noiseNames.contains(url.lastPathComponent) { continue }
            guard let relative = relativePath(of: url, under: folder),
                  let size = values.fileSize else { return nil }
            if size == 0 {
                entries.append("\(relative):empty")
                continue
            }
            guard let digest = fileHashes[url] else { return nil }
            entries.append("\(relative):\(digest)")
            total += Int64(size)
            hashed += 1
        }

        guard hashed > 0 else { return nil }
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
