import Foundation

/// iCloud Drive, Google Drive, Dropbox and the rest, found rather than
/// integrated with.
///
/// None of these need a protocol implementation. Every one of them ships a
/// daemon that already presents its contents as an ordinary folder — iCloud
/// under `Mobile Documents`, everything else as a File Provider under
/// `CloudStorage`. They were reachable all along by typing the path. The only
/// thing missing was somewhere to click.
enum CloudDrives {
    struct Drive: Equatable {
        var name: String
        var url: URL
        /// An SF Symbol, since these have no icon of their own on disk.
        var symbol: String
    }

    /// Every cloud folder on this Mac, named the way its vendor names it.
    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Drive] {
        var drives: [Drive] = []
        let fm = FileManager.default

        let iCloud = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: iCloud.path, isDirectory: &isDirectory), isDirectory.boolValue {
            drives.append(Drive(name: "iCloud Drive", url: iCloud, symbol: "icloud"))
        }

        // Every File Provider puts itself here, so this finds providers that
        // did not exist when this was written without naming any of them.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let contents = (try? fm.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            drives.append(Drive(
                name: displayName(for: url.lastPathComponent),
                url: url,
                symbol: symbol(for: url.lastPathComponent)
            ))
        }
        return drives
    }

    /// `GoogleDrive-someone@gmail.com` is what the folder is called. The part
    /// after the dash is the account, and it is worth keeping when someone has
    /// two of the same service signed in.
    static func displayName(for folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let service = spaced(String(parts[0]))
        guard parts.count == 2, !parts[1].isEmpty else { return service }
        return "\(service) — \(parts[1])"
    }

    /// `GoogleDrive` and `OneDrive` are written without spaces on disk.
    static func spaced(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if index > 0, character.isUppercase, !result.hasSuffix(" ") {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    static func symbol(for folder: String) -> String {
        let name = folder.lowercased()
        if name.hasPrefix("icloud") { return "icloud" }
        if name.hasPrefix("googledrive") { return "cylinder.split.1x2" }
        if name.hasPrefix("dropbox") { return "shippingbox" }
        if name.hasPrefix("onedrive") { return "cloud" }
        if name.hasPrefix("box") { return "shippingbox" }
        return "cloud"
    }
}
