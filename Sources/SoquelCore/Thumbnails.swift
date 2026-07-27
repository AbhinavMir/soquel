import AppKit
import QuickLookThumbnailing

/// Real thumbnails for the icon view, generated off the main thread and cached.
///
/// Generation is lazy and cancellable: scrolling a folder of a few thousand
/// photos must not queue a few thousand generator requests that all outlive the
/// cells that asked for them.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// A request in flight, so a reused cell can drop the one it no longer wants.
    typealias Token = UUID

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// Tokens that were cancelled before their generator finished.
    private var cancelled: Set<Token> = []
    /// Requests still running, so cancelling one can reach the generator.
    private var inFlight: [Token: QLThumbnailGenerator.Request] = [:]
    private let generator = QLThumbnailGenerator.shared

    private init() {
        // Roughly a few hundred thumbnails; NSCache evicts under memory pressure
        // on its own, this only bounds the ordinary case.
        cache.countLimit = 512
        // 192 MB of decoded images. Without this the count limit alone allows
        // 512 full-size thumbnails, which for a folder of photographs is most
        // of a gigabyte held for as long as the application runs.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    /// Cache identity includes the size and the modification date, so a rescaled
    /// view or an edited file does not show a stale image.
    static func key(for url: URL, size: CGFloat, modified: Date?) -> NSString {
        let stamp = modified?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(size))|\(Int(stamp))" as NSString
    }

    func cached(for url: URL, size: CGFloat, modified: Date?) -> NSImage? {
        cache.object(forKey: Self.key(for: url, size: size, modified: modified))
    }

    /// Requests a thumbnail. `completion` runs on the main queue, and only if
    /// the returned token has not been cancelled.
    ///
    /// A cache hit calls back synchronously so a scrolling cell never flashes
    /// its generic icon for a frame before the real image lands.
    @discardableResult
    func thumbnail(
        for url: URL,
        size: CGFloat,
        modified: Date?,
        scale: CGFloat,
        completion: @escaping (NSImage) -> Void
    ) -> Token? {
        let key = Self.key(for: url, size: size, modified: modified)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return nil
        }

        let token = Token()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        lock.lock(); inFlight[token] = request; lock.unlock()

        generator.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let self else { return }
            self.lock.lock(); self.inFlight[token] = nil; self.lock.unlock()
            // A file with no thumbnail representation keeps its type icon; there
            // is nothing better to show and a blank tile would be worse.
            guard let representation else { return }
            let image = representation.nsImage
            // Bounded by bytes as well as by count. Six hundred thumbnails of a
            // photo library are hundreds of megabytes, and a count limit alone
            // does not notice.
            let pixels = size * scale
            self.cache.setObject(image, forKey: key, cost: Int(pixels * pixels * 4))

            DispatchQueue.main.async {
                guard !self.isCancelled(token) else { return }
                completion(image)
            }
        }
        return token
    }

    /// Stops work on a thumbnail whose cell has scrolled away.
    ///
    /// Recording the token was not cancelling anything: the generator ran every
    /// request it had been given to completion and the result was thrown away
    /// at the end. Scrolling through a large folder therefore paid for a
    /// thumbnail of every file it passed, which is what made scrolling stutter
    /// and memory climb. Telling the generator is what actually stops it.
    func cancel(_ token: Token?) {
        guard let token else { return }
        lock.lock()
        cancelled.insert(token)
        let request = inFlight.removeValue(forKey: token)
        // Bounded, but only by dropping the oldest — clearing the whole set
        // would un-cancel everything still running.
        if cancelled.count > 4096 {
            cancelled = Set(cancelled.suffix(1024))
        }
        lock.unlock()
        if let request { generator.cancel(request) }
    }

    private func isCancelled(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(token)
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// Folders, applications and symlinks are shown as their type icon.
    ///
    /// Quick Look will happily render a folder's first item as its thumbnail,
    /// which makes two folders with similar contents indistinguishable at a
    /// glance — the icon is more useful.
    static func wantsThumbnail(_ item: FileItem) -> Bool {
        !item.isDirectory && !item.isSymlink
    }
}
