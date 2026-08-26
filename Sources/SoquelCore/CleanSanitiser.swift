import Foundation

/// Deciding what a folder may say about itself to a server.
///
/// Clean This Folder is the only feature that sends the contents of files
/// anywhere. Everything else in Soquel stays on the machine. So the rule here
/// is the opposite of the rest of the application: nothing goes unless it has
/// been looked at, and what is sent is shown before it is sent.
///
/// Nothing in this file writes to disk. Redaction changes the copy in the
/// request and never the file — a feature that edited somebody's source to
/// make a request safer would be doing the damage it exists to avoid.
enum CleanSanitiser {
    /// How much of any one file is read. A structure suggestion needs to know
    /// what a file is, not everything it says.
    static let headBytes = 4_000
    /// The ceiling on a whole request, so a large folder cannot quietly become
    /// a large upload.
    static let totalBytes = 400_000

    /// Files that are never opened, whatever is in them, matched on the name
    /// alone. A key would be redacted by the rules below, but not reading the
    /// file at all is a shorter path to the same promise.
    static let neverRead: [String] = [
        ".env", ".env.local", ".env.production", ".netrc", ".pgpass",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials",
        ".htpasswd", "shadow", "secring.gpg", ".git-credentials"
    ]

    static let neverReadExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "kdbx", "keychain", "ppk"
    ]

    /// What a file contributes to the request.
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let size: Int64
        /// Nil when nothing was read, with `skipped` saying why.
        let head: String?
        let skipped: String?
    }

    struct Payload: Equatable {
        let entries: [Entry]
        /// What was left out, and why, so the panel can say so before sending.
        let notes: [String]
        var bytes: Int { entries.reduce(0) { $0 + ($1.head?.utf8.count ?? 0) } }
    }

    static func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if neverRead.contains(where: { lower == $0 }) { return true }
        if neverReadExtensions.contains((lower as NSString).pathExtension) { return true }
        // "prod.env" and ".env.staging" are the same promise as ".env".
        if lower.hasPrefix(".env") || lower.hasSuffix(".env") { return true }
        return false
    }

    /// Replaces anything that looks like a secret with a marker.
    ///
    /// Deliberately eager. A false positive costs a line of context in a
    /// structure suggestion; a false negative sends somebody's key to a server.
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "[removed]")
        }
        return result
    }

    private static let patterns: [String] = [
        // Whole private key blocks, first — before the line rules can cut one
        // in half and leave the rest looking like ordinary base64.
        "-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----",
        // key = value, where the name says what the value is.
        "(?:api[_-]?key|secret|passwd|password|token|bearer|auth|credential|private[_-]?key)"
            + "\\s*[:=]\\s*[\"']?[^\\s\"',;]{6,}[\"']?",
        // Shapes that identify themselves whatever they are called.
        "sk-ant-[A-Za-z0-9_-]{10,}",
        "sk-[A-Za-z0-9]{20,}",
        "gh[pousr]_[A-Za-z0-9]{20,}",
        "AKIA[0-9A-Z]{16}",
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        "AIza[0-9A-Za-z_-]{30,}",
        "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",
        // A URL carrying credentials.
        "[a-z][a-z0-9+.-]*://[^\\s/@]+:[^\\s/@]+@",
    ]

    /// Reads a folder into what may be sent, one level deep.
    ///
    /// One level on purpose: the suggestion is about how this folder should be
    /// arranged, and walking the whole tree would multiply what leaves the
    /// machine for context that is not being asked about.
    static func gather(_ folder: URL, fileManager: FileManager = .default) -> Payload {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else {
            return Payload(entries: [], notes: ["The folder could not be read."])
        }

        var entries: [Entry] = []
        var notes: [String] = []
        var sensitive = 0, binary = 0, unread = 0, budgeted = 0
        var used = 0

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            let size = Int64(values?.fileSize ?? 0)
            let name = url.lastPathComponent

            if isDirectory {
                entries.append(Entry(name: name, isDirectory: true, size: size,
                                     head: nil, skipped: nil))
                continue
            }
            if isSensitiveName(name) {
                sensitive += 1
                entries.append(Entry(name: name, isDirectory: false, size: size,
                                     head: nil, skipped: "not read — may hold a secret"))
                continue
            }
            if used >= totalBytes {
                budgeted += 1
                entries.append(Entry(name: name, isDirectory: false, size: size,
                                     head: nil, skipped: "not read — request full"))
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                unread += 1
                entries.append(Entry(name: name, isDirectory: false, size: size,
                                     head: nil, skipped: "could not be read"))
                continue
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: headBytes)) ?? Data()
            if data.contains(0) {
                binary += 1
                entries.append(Entry(name: name, isDirectory: false, size: size,
                                     head: nil, skipped: "not text"))
                continue
            }
            let head = redact(String(decoding: data, as: UTF8.self))
            used += head.utf8.count
            entries.append(Entry(name: name, isDirectory: false, size: size,
                                 head: head, skipped: nil))
        }

        if sensitive > 0 { notes.append("\(sensitive) file\(sensitive == 1 ? "" : "s") not opened, because the name says it may hold a secret.") }
        if binary > 0 { notes.append("\(binary) file\(binary == 1 ? "" : "s") not read, because they are not text. The names are still sent.") }
        if unread > 0 { notes.append("\(unread) file\(unread == 1 ? "" : "s") could not be read.") }
        if budgeted > 0 { notes.append("\(budgeted) file\(budgeted == 1 ? "" : "s") not read, because the request was already full at \(totalBytes / 1000) KB.") }
        notes.append("Anything that looked like a key, token or password was replaced with “[removed]” before sending. Your files are not changed.")
        return Payload(entries: entries, notes: notes)
    }

    /// Exactly what will be sent, for the panel to show before it is sent.
    static func preview(_ payload: Payload) -> String {
        var lines: [String] = []
        for entry in payload.entries {
            if entry.isDirectory {
                lines.append("\(entry.name)/")
            } else if let skipped = entry.skipped {
                lines.append("\(entry.name)  (\(skipped))")
            } else {
                lines.append("\(entry.name)")
                if let head = entry.head, !head.isEmpty {
                    lines.append(contentsOf: head
                        .components(separatedBy: "\n").prefix(40)
                        .map { "    " + $0 })
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
