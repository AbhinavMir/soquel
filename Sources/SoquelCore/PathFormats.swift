import AppKit

/// Returns the parent directory, or nil at the filesystem root.
///
/// `URL.deletingLastPathComponent()` appends ".." once it reaches "/", so a
/// naive loop over it never terminates. Every upward walk goes through here.
func parentDirectoryURL(of url: URL) -> URL? {
    let current = url.standardizedFileURL
    guard current.path != "/" else { return nil }
    let parent = current.deletingLastPathComponent().standardizedFileURL
    guard parent.path != current.path else { return nil }
    return parent
}

enum PathFormat: CaseIterable {
    case absolute, fileURL, filename, filenameNoExtension, parentDirectory, shellEscaped

    var title: String {
        switch self {
        case .absolute: return "Absolute Path"
        case .fileURL: return "File URL"
        case .filename: return "Filename"
        case .filenameNoExtension: return "Filename Without Extension"
        case .parentDirectory: return "Parent Directory Path"
        case .shellEscaped: return "Shell-Escaped Path"
        }
    }

    func string(for url: URL) -> String {
        switch self {
        case .absolute: return url.path
        case .fileURL: return url.absoluteString
        case .filename: return url.lastPathComponent
        case .filenameNoExtension: return url.deletingPathExtension().lastPathComponent
        case .parentDirectory: return (parentDirectoryURL(of: url) ?? url).path
        case .shellEscaped: return "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

func copyToPasteboard(_ urls: [URL], format: PathFormat) {
    guard !urls.isEmpty else { return }
    let text = urls.map { format.string(for: $0) }.joined(separator: "\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

/// File copy/cut clipboard on the general pasteboard. The cut flag is only
/// honoured while the pasteboard still holds what we wrote (changeCount match).
enum FileClipboard {
    private static var cutChangeCount = -1

    static func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        cutChangeCount = cut ? pb.changeCount : -1
    }

    static func read() -> [URL] {
        let pb = NSPasteboard.general
        let objs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objs as? [URL]) ?? []
    }

    static var isCut: Bool {
        NSPasteboard.general.changeCount == cutChangeCount
    }

    static func clearCut() {
        cutChangeCount = -1
    }
}
