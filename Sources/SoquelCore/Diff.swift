import Foundation

/// Comparing two files, and reading a patch somebody sent you.
///
/// The folder comparison answers "which files differ". This answers the
/// question that follows it, which until now meant leaving for a terminal or
/// an editor: differ *how*.
enum Diff {
    /// One line of a unified diff, tagged with what it means so the view can
    /// colour it without parsing the text a second time.
    struct Line: Equatable {
        enum Kind: Equatable {
            case context
            case added
            case removed
            /// `@@ -1,7 +1,9 @@` — where the next run of lines sits.
            case hunk
            /// `--- a/file` and `+++ b/file`.
            case header
        }

        let kind: Kind
        let text: String
        /// Line numbers in the old and new file. Nil where the line does not
        /// exist on that side, which is what makes an added line addable.
        let oldNumber: Int?
        let newNumber: Int?
    }

    struct Result {
        let lines: [Line]
        /// Set when there is nothing to show, and why: identical, binary, or
        /// too large. A blank window with no explanation reads as a failure.
        let note: String?
        var isEmpty: Bool { lines.isEmpty }

        var added: Int { lines.filter { $0.kind == .added }.count }
        var removed: Int { lines.filter { $0.kind == .removed }.count }
    }

    /// Files past this are not diffed. `diff` on two gigabyte files would
    /// hold the whole comparison in memory and hand back more lines than any
    /// window can draw.
    static let sizeLimit = 8 * 1024 * 1024

    /// Whether a file can be compared as text. The same rule content search
    /// uses, so what the two features refuse is the same set.
    static func isComparable(_ url: URL) -> (ok: Bool, reason: String?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return (false, "Not a file") }
        let size = values?.fileSize ?? 0
        if size > sizeLimit {
            return (false, "Larger than 8 MB")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (false, "Could not be read")
        }
        defer { try? handle.close() }
        // A NUL byte in the first block is the oldest and still the most
        // reliable test for "this is not text".
        let sample = (try? handle.read(upToCount: 8000)) ?? Data()
        return sample.contains(0) ? (false, "Not a text file") : (true, nil)
    }

    /// Compares two files. Runs off the main thread; the completion is on it.
    static func compare(_ left: URL, _ right: URL, completion: @escaping (Result) -> Void) {
        for url in [left, right] {
            let check = isComparable(url)
            if !check.ok {
                let note = "\(url.lastPathComponent): \(check.reason ?? "cannot be compared")"
                DispatchQueue.main.async { completion(Result(lines: [], note: note)) }
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            // -u for unified, -N so a missing file reads as empty rather than
            // as an error, and the labels put the real names in the header
            // instead of the paths of whatever was passed in.
            task.arguments = ["-u", "-N",
                              "--label", left.lastPathComponent,
                              "--label", right.lastPathComponent,
                              left.path, right.path]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = Pipe()

            var text = ""
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
            } catch {
                let note = "Could not run diff: \(error.localizedDescription)"
                DispatchQueue.main.async { completion(Result(lines: [], note: note)) }
                return
            }

            // diff exits 0 when the files match, 1 when they differ, and 2 on
            // a real failure. Only 2 is a problem.
            let result: Result
            if task.terminationStatus > 1 {
                result = Result(lines: [], note: "diff could not compare these files")
            } else if text.isEmpty {
                result = Result(lines: [], note: "The files are identical")
            } else {
                result = Result(lines: parse(unified: text), note: nil)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Reads a unified diff into lines, tracking the line numbers each hunk
    /// header declares so both sides can be numbered.
    static func parse(unified text: String) -> [Line] {
        var lines: [Line] = []
        var oldNumber = 0
        var newNumber = 0

        // Split once. This used to re-split the whole text inside the loop to
        // find the last element, which made the parse quadratic: a
        // 16,000-line patch took 8.3 seconds, and it is parsed on the main
        // thread.
        var rows = text.components(separatedBy: "\n")
        // A text ending in a newline leaves one empty string behind. Only that
        // one is dropped. The old test compared every line against it, so a
        // blank line anywhere in the patch was thrown away — and because the
        // skip also missed the counter increments below, every line number
        // after it was reported one too low, and one more per blank line.
        if rows.last == "" { rows.removeLast() }

        for raw in rows {
            if raw.hasPrefix("@@") {
                (oldNumber, newNumber) = hunkStart(raw) ?? (oldNumber, newNumber)
                lines.append(Line(kind: .hunk, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            if raw.hasPrefix("---") || raw.hasPrefix("+++") || raw.hasPrefix("diff ")
                || raw.hasPrefix("index ") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") {
                lines.append(Line(kind: .header, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            switch raw.first {
            case "+":
                lines.append(Line(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            case "-":
                lines.append(Line(kind: .removed, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            case "\\":
                // "\ No newline at end of file" belongs to the line above it.
                lines.append(Line(kind: .header, text: raw, oldNumber: nil, newNumber: nil))
            default:
                let body = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                lines.append(Line(kind: .context, text: body, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
        }
        return lines
    }

    /// The two starting line numbers out of `@@ -12,7 +12,9 @@`.
    static func hunkStart(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.components(separatedBy: " ")
        guard parts.count >= 3 else { return nil }
        func number(_ token: String) -> Int? {
            let digits = token.dropFirst().prefix { $0.isNumber }
            return Int(digits)
        }
        guard let old = number(parts[1]), let new = number(parts[2]) else { return nil }
        return (old, new)
    }

    /// Reads a `.diff` or `.patch` file that somebody else produced.
    static func read(patch url: URL) -> Result {
        // The same ceiling `compare` applies. Without it a 126 MB .diff was
        // read whole and parsed into a Line per line, on the main thread.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= sizeLimit else {
            return Result(lines: [], note: "\(url.lastPathComponent): Larger than 8 MB")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(lines: [], note: "Could not read \(url.lastPathComponent)")
        }
        let lines = parse(unified: text)
        return Result(lines: lines, note: lines.isEmpty ? "Nothing in this patch" : nil)
    }

    /// Whether this is a patch rather than a file to be compared.
    static func isPatch(_ url: URL) -> Bool {
        ["diff", "patch"].contains(url.pathExtension.lowercased())
    }
}
