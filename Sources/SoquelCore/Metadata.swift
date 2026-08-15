import AppKit
import AVFoundation
import ImageIO

/// Extra columns beyond the filesystem basics: image dimensions, media
/// duration, codec, and so on.
///
/// Finder gates these behind an undocumented trick — Dimensions appears only in
/// a folder literally named "Pictures", duration only in one named "Movies" —
/// and people reject the workaround because their files are spread across many
/// folders. Here they are columns like any other, in any folder.
enum MetadataField: String, CaseIterable {
    case dimensions, resolution, duration, codec, bitRate, colourSpace, camera

    var title: String {
        switch self {
        case .dimensions: return "Dimensions"
        case .resolution: return "Resolution"
        case .duration: return "Duration"
        case .codec: return "Codec"
        case .bitRate: return "Bit Rate"
        case .colourSpace: return "Colour Space"
        case .camera: return "Camera"
        }
    }

    var columnWidth: CGFloat {
        switch self {
        case .dimensions, .duration, .resolution, .bitRate: return 100
        case .codec, .colourSpace: return 110
        case .camera: return 150
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread when a file's metadata lands; the object is
    /// the file's URL. A notification rather than a stored closure: every
    /// pane and the inspector listen, and a single closure slot meant the
    /// last one to register stole the answers from the rest.
    static let soquelMetadataRead = Notification.Name("app.soquel.metadataRead")
}

/// Reads media metadata off the main thread and remembers it per file.
final class MetadataReader {
    static let shared = MetadataReader()

    /// Values keyed by field, for one file.
    typealias Record = [MetadataField: String]

    /// A record together with the file's modification date when it was read.
    /// A re-exported video or an overwritten image gets fresh values instead
    /// of keeping the old ones for the life of the application.
    private final class Entry {
        let record: Record
        let stamp: Date?
        init(record: Record, stamp: Date?) {
            self.record = record
            self.stamp = stamp
        }
    }

    private let cache = NSCache<NSURL, Entry>()
    private var inFlight: Set<URL> = []
    private let queue = DispatchQueue(label: "app.soquel.metadata", qos: .utility)

    private init() {
        // Records are small, but the dictionary this replaced grew for as
        // long as the application ran; NSCache bounds it and also evicts
        // under memory pressure on its own.
        cache.countLimit = 4096
    }

    private static func stamp(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The cached record for a file. A plain lookup, and deliberately so: the
    /// callers are per-cell draw paths and per-file reload loops on the main
    /// thread, so this must never touch the filesystem — one synchronous stat
    /// per cell on a network mount stalls the whole UI, and a dead mount
    /// hangs it. Freshness is `read`'s job, on the background queue.
    func cached(_ url: URL) -> Record? {
        cache.object(forKey: url as NSURL)?.record
    }

    func value(_ field: MetadataField, for url: URL) -> String? {
        cached(url)?[field]
    }

    /// Checks the cache against the file and extracts when needed, entirely
    /// on the background queue. A file overwritten since its last read gets
    /// fresh values; an unchanged one costs one background stat and posts no
    /// notification. Nothing here blocks the listing.
    func read(_ url: URL) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)

        queue.async { [weak self] in
            // The stamp is read before the extraction, so a file that changes
            // mid-read stores an already-stale stamp and is read again.
            let stamp = Self.stamp(of: url)
            if let hit = self?.cache.object(forKey: url as NSURL), hit.stamp == stamp {
                DispatchQueue.main.async { self?.inFlight.remove(url) }
                return
            }
            let record = Self.extract(from: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(url)
                self.cache.setObject(Entry(record: record, stamp: stamp), forKey: url as NSURL)
                NotificationCenter.default.post(name: .soquelMetadataRead, object: url)
            }
        }
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// Reads whatever the file actually has. An unrecognised file yields an
    /// empty record rather than guesses, and the columns stay blank.
    static func extract(from url: URL) -> Record {
        var record = Record()

        // Images: read the header only, never decode the pixels.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                record[.dimensions] = "\(width) × \(height)"
            }
            if let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
                record[.resolution] = "\(Int(dpi)) dpi"
            }
            if let profile = properties[kCGImagePropertyProfileName] as? String {
                record[.colourSpace] = profile
            }
            if let exif = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = exif[kCGImagePropertyTIFFMake] as? String
                let model = exif[kCGImagePropertyTIFFModel] as? String
                let camera = [make, model].compactMap { $0 }.joined(separator: " ")
                if !camera.isEmpty { record[.camera] = camera }
            }
            if !record.isEmpty { return record }
        }

        // Audio and video.
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 {
            record[.duration] = formatDuration(seconds)

            for track in asset.tracks {
                if track.mediaType == .video {
                    let size = track.naturalSize.applying(track.preferredTransform)
                    let width = Int(abs(size.width)), height = Int(abs(size.height))
                    if width > 0, height > 0 { record[.dimensions] = "\(width) × \(height)" }
                }
                if record[.codec] == nil, let description = track.formatDescriptions.first {
                    let subtype = CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription)
                    record[.codec] = fourCharacterCode(subtype)
                }
                if record[.bitRate] == nil, track.estimatedDataRate > 0 {
                    let kbps = Int(track.estimatedDataRate / 1000)
                    record[.bitRate] = "\(kbps) kbps"
                }
            }
        }
        return record
    }

    /// "1:23:45" or "4:07" — never a bare number of seconds.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Turns a FourCC such as 'avc1' into text.
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? ""
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Which optional columns the user has switched on.
enum MetadataColumns {
    private static let key = "metadataColumns"

    static var enabled: [MetadataField] {
        get {
            let stored = Settings.stringArray(forKey: key) ?? []
            return stored.compactMap { MetadataField(rawValue: $0) }
        }
        set {
            Settings.set(newValue.map(\.rawValue), forKey: key)
            NotificationCenter.default.post(name: .soquelColumnsChanged, object: nil)
        }
    }

    static func toggle(_ field: MetadataField) {
        var current = enabled
        if let index = current.firstIndex(of: field) {
            current.remove(at: index)
        } else {
            current.append(field)
            // Keep the declared order so columns do not shuffle around.
            let order = MetadataField.allCases
            current.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        enabled = current
    }
}

extension Notification.Name {
    static let soquelColumnsChanged = Notification.Name("app.soquel.columnsChanged")
}
