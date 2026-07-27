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

/// Reads media metadata off the main thread and remembers it per file.
final class MetadataReader {
    static let shared = MetadataReader()

    /// Values keyed by field, for one file.
    typealias Record = [MetadataField: String]

    private var cache: [URL: Record] = [:]
    private var inFlight: Set<URL> = []
    private let queue = DispatchQueue(label: "app.soquel.metadata", qos: .utility)

    var onUpdate: ((URL) -> Void)?

    func cached(_ url: URL) -> Record? { cache[url] }

    func value(_ field: MetadataField, for url: URL) -> String? {
        cache[url]?[field]
    }

    /// Starts a read unless one is cached or already running. Nothing here
    /// blocks the listing; a column shows nothing until an answer arrives.
    func read(_ url: URL) {
        guard cache[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)

        queue.async { [weak self] in
            let record = Self.extract(from: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(url)
                self.cache[url] = record
                self.onUpdate?(url)
            }
        }
    }

    func clear() {
        cache.removeAll()
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
