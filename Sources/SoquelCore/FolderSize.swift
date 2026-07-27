import Foundation

/// Computes folder sizes off the main thread, one folder at a time, and caches
/// the answer until the folder changes.
///
/// Finder's "Calculate all sizes" is off by default, per-window, and counts
/// each hard link as another copy. This counts allocated size, counts a given
/// inode once, and never blocks the listing: the column shows a dash until an
/// answer arrives.
final class FolderSizeCalculator {
    static let shared = FolderSizeCalculator()

    struct Measurement {
        let bytes: Int64
        let fileCount: Int
        /// Modification date of the folder when measured; a change invalidates.
        let stamp: Date?
    }

    private let queue = DispatchQueue(label: "app.soquel.foldersize", qos: .utility)
    private var cache: [URL: Measurement] = [:]
    private var inFlight: Set<URL> = []

    /// Called on the main thread whenever a measurement lands.
    var onUpdate: ((URL, Measurement) -> Void)?

    /// A cached size, if one is still valid.
    func cached(for url: URL) -> Measurement? {
        guard let hit = cache[url] else { return nil }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard hit.stamp == stamp else {
            cache.removeValue(forKey: url)
            return nil
        }
        return hit
    }

    /// Starts measuring unless an answer is already cached or on its way.
    func measure(_ url: URL) {
        guard cached(for: url) == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)

        queue.async { [weak self] in
            let measurement = Self.walk(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(url)
                self.cache[url] = measurement
                self.onUpdate?(url, measurement)
            }
        }
    }

    func clear() {
        cache.removeAll()
    }

    /// Walks the tree adding allocated sizes. Symlinks are not followed — a
    /// link loop would never terminate — and a hard-linked inode is counted
    /// once, which is where Finder's numbers go wrong.
    static func walk(_ url: URL) -> Measurement {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey,
        ]

        // Packages are descended into on purpose: a folder holding a 600 KB
        // app bundle occupies 600 KB, and skipping bundle contents reported it
        // as zero.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return Measurement(bytes: 0, fileCount: 0, stamp: stamp)
        }

        var total: Int64 = 0
        var files = 0
        var seen = Set<NSObject>()

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }

            // Two paths pointing at one inode are one file's worth of disk.
            if let identifier = values.fileResourceIdentifier as? NSObject {
                if seen.contains(identifier) { continue }
                seen.insert(identifier)
            }

            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
            files += 1
        }

        return Measurement(bytes: total, fileCount: files, stamp: stamp)
    }
}
