import Foundation

/// A single `.gitignore` rule.
struct IgnoreRule {
    /// The pattern as written, kept for reporting which rule excluded a path.
    let pattern: String
    /// `!pattern` re-includes something an earlier rule excluded.
    let isNegated: Bool
    /// A trailing slash restricts the rule to directories.
    let directoriesOnly: Bool
    /// A slash anywhere but the end anchors the pattern to the file's own
    /// directory; otherwise it matches a name at any depth.
    let isAnchored: Bool
    private let regex: NSRegularExpression?

    init?(line rawLine: String) {
        // A trailing backslash escapes the space before it; other trailing
        // whitespace is not part of the pattern.
        var line = rawLine
        if !line.hasSuffix("\\ ") {
            while line.hasSuffix(" ") { line.removeLast() }
        }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var body = line
        var negated = false
        if body.hasPrefix("!") {
            negated = true
            body.removeFirst()
        } else if body.hasPrefix("\\!") || body.hasPrefix("\\#") {
            // An escaped leading ! or # is a literal character.
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        var onlyDirectories = false
        if body.hasSuffix("/") {
            onlyDirectories = true
            body.removeLast()
        }
        guard !body.isEmpty else { return nil }

        // A slash anywhere except the very end makes the pattern a path.
        let anchored = body.dropLast().contains("/") || body.hasPrefix("/")
        if body.hasPrefix("/") { body.removeFirst() }

        pattern = rawLine
        isNegated = negated
        directoriesOnly = onlyDirectories
        isAnchored = anchored
        regex = try? NSRegularExpression(pattern: "^" + Self.expression(for: body) + "$")
    }

    /// Translates a gitignore glob into a regular expression.
    ///
    /// `*` stops at a slash, `**` crosses them, `?` is one non-slash character,
    /// and a bracket class passes through with its contents escaped only where
    /// a regex would read them differently.
    static func expression(for glob: String) -> String {
        var result = ""
        let characters = Array(glob)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                let isDouble = index + 1 < characters.count && characters[index + 1] == "*"
                if isDouble {
                    let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                    let precededBySlash = index > 0 && characters[index - 1] == "/"
                    if followedBySlash {
                        // "**/" matches zero or more leading directories.
                        result += "(?:.*/)?"
                        index += 3
                        continue
                    }
                    if precededBySlash {
                        // A trailing "/**" matches everything below.
                        result += ".*"
                        index += 2
                        continue
                    }
                    result += ".*"
                    index += 2
                    continue
                }
                result += "[^/]*"
                index += 1
            case "?":
                result += "[^/]"
                index += 1
            case "[":
                // Copy the class through to its closing bracket.
                var classBody = "["
                var scan = index + 1
                if scan < characters.count, characters[scan] == "!" {
                    classBody += "^"
                    scan += 1
                }
                while scan < characters.count, characters[scan] != "]" {
                    if characters[scan] == "\\", scan + 1 < characters.count {
                        classBody += "\\" + String(characters[scan + 1])
                        scan += 2
                        continue
                    }
                    classBody += String(characters[scan])
                    scan += 1
                }
                if scan < characters.count {
                    result += classBody + "]"
                    index = scan + 1
                } else {
                    // An unclosed bracket is a literal bracket, as in git.
                    result += "\\["
                    index += 1
                }
            case "\\":
                if index + 1 < characters.count {
                    result += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                    index += 2
                } else {
                    result += "\\\\"
                    index += 1
                }
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }
        return result
    }

    /// `relativePath` is relative to the directory holding the ignore file.
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if directoriesOnly && !isDirectory { return false }
        guard let regex else { return false }

        // An unanchored pattern matches the name at any depth, so every
        // trailing portion of the path is a candidate.
        let candidates: [String]
        if isAnchored {
            candidates = [relativePath]
        } else {
            let components = relativePath.split(separator: "/").map(String.init)
            candidates = (0..<components.count).map { components[$0...].joined(separator: "/") }
        }

        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil { return true }
        }
        return false
    }
}

/// The ignore rules in force for one directory tree.
///
/// Rules are gathered per directory as the walk descends, because a nested
/// `.gitignore` applies only below itself and can re-include what a parent
/// excluded.
final class IgnoreStack {
    /// One ignore file: where it sits, and what it says.
    private struct Level {
        let directory: String
        let rules: [IgnoreRule]
    }

    private var levels: [Level] = []

    /// Always ignored, in every repository, and not worth a rule.
    static let alwaysIgnored: Set<String> = [".git"]

    init() {}

    static func parse(_ contents: String) -> [IgnoreRule] {
        contents.components(separatedBy: .newlines).compactMap(IgnoreRule.init(line:))
    }

    /// Reads `.gitignore` from `directory` if there is one, and pushes it.
    @discardableResult
    func pushIgnoreFile(in directory: URL) -> Bool {
        let file = directory.appendingPathComponent(".gitignore")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return false }
        levels.append(Level(
            directory: directory.standardizedFileURL.path,
            rules: Self.parse(contents)
        ))
        return true
    }

    func push(rules: [IgnoreRule], for directory: URL) {
        levels.append(Level(directory: directory.standardizedFileURL.path, rules: rules))
    }

    var isEmpty: Bool { levels.isEmpty }

    /// Whether git would ignore this path.
    ///
    /// Every level is consulted from the outermost inwards, and within a level
    /// the last matching rule wins — which is what makes `!` re-include work.
    func ignores(_ url: URL, isDirectory: Bool) -> Bool {
        let path = url.standardizedFileURL.path
        if Self.alwaysIgnored.contains(url.lastPathComponent) { return true }

        var ignored = false
        for level in levels {
            guard path.hasPrefix(level.directory) else { continue }
            let relative = String(path.dropFirst(level.directory.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }

            for rule in level.rules where rule.matches(relativePath: relative, isDirectory: isDirectory) {
                ignored = !rule.isNegated
            }
        }
        return ignored
    }

    /// Walks up from `directory` to the repository root, collecting every
    /// `.gitignore` on the way, so a search started deep inside a repository
    /// still honours the rules above it.
    static func forTree(startingAt directory: URL) -> IgnoreStack {
        let stack = IgnoreStack()
        var chain: [URL] = []
        var current = directory.standardizedFileURL

        while true {
            chain.append(current)
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                break
            }
            guard let parent = parentDirectoryURL(of: current) else { break }
            current = parent
        }

        // Outermost first: a nested file must be able to override its parent.
        for directory in chain.reversed() {
            stack.pushIgnoreFile(in: directory)
        }
        return stack
    }
}
