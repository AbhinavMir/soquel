import AppKit

/// Renaming many files at once, with the result visible before anything is
/// written.
///
/// Finder has had batch rename since Yosemite but it cannot do regular
/// expressions, has no preview, cannot chain rules, and its "Name and Date"
/// inserts the current timestamp rather than the file's own.
enum RenameRule: Equatable {
    case findReplace(find: String, replace: String, regex: Bool, caseSensitive: Bool)
    case addPrefix(String)
    case addSuffix(String)
    case sequence(prefix: String, start: Int, padding: Int)
    case changeCase(Case)
    case replaceExtension(String)
    case trimWhitespace
    case insertDate(format: String, useCreated: Bool)
    /// Rewrites an existing number at the front of the name, keeping the rest
    /// of it. `01_DAVIS_$22753.20_REC` renumbered to 3 is `03_DAVIS_$22753.20_REC`.
    ///
    /// The sequence rule replaces the whole name; this one is for a batch
    /// that is already numbered and has a hole in it, or wants something
    /// inserted in the middle. Files with no leading number are left alone —
    /// a rule that invented numbers for them would renumber the wrong set.
    case resequence(start: Int, padding: Int)

    enum Case: String, CaseIterable {
        case lower, upper, title

        var title: String {
            switch self {
            case .lower: return "lower case"
            case .upper: return "UPPER CASE"
            case .title: return "Title Case"
            }
        }
    }
}

/// One file's before and after.
struct RenamePreview: Equatable {
    let url: URL
    let original: String
    let proposed: String

    var changed: Bool { original != proposed }
    /// Set when the new name cannot be used, with the reason.
    var problem: String?
}

enum BatchRename {
    /// Splits `01_DAVIS_REC` into its number and everything after it.
    ///
    /// The separator stays with the rest, so whatever joined the number to
    /// the name — an underscore, a dash, a dot, a space, or nothing — comes
    /// back untouched.
    static func leadingNumber(in stem: String) -> (digits: String, rest: String)? {
        let digits = stem.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return (String(digits), String(stem.dropFirst(digits.count)))
    }

    /// Whether a set of names looks like a numbered batch, which is what the
    /// panel uses to decide whether to offer renumbering at all.
    static func isNumberedBatch(_ names: [String]) -> Bool {
        let stems = names.map { ($0 as NSString).deletingPathExtension }
        let numbered = stems.filter { leadingNumber(in: $0) != nil }
        // Half of them is enough: a folder of records usually has a stray
        // README or an index file sitting in with the numbered ones.
        return numbered.count >= max(2, stems.count / 2)
    }

    /// Applies rules in order and returns what each file would become.
    ///
    /// Collisions are detected across the whole batch, not just against what is
    /// already on disk, because two files renamed to the same thing would
    /// silently destroy one of them.
    static func plan(
        for urls: [URL],
        rules: [RenameRule],
        now: Date = Date()
    ) -> [RenamePreview] {
        var previews: [RenamePreview] = []
        var claimed = Set<String>()

        for (index, url) in urls.enumerated() {
            let original = url.lastPathComponent
            var stem = (original as NSString).deletingPathExtension
            var ext = url.pathExtension

            var ruleProblem: String?
            for rule in rules {
                (stem, ext) = apply(rule, stem: stem, ext: ext, index: index, url: url,
                                    now: now, problem: &ruleProblem)
            }

            var proposed = ext.isEmpty ? stem : "\(stem).\(ext)"
            proposed = proposed.trimmingCharacters(in: .whitespaces)

            var preview = RenamePreview(url: url, original: original, proposed: proposed, problem: nil)

            if let ruleProblem {
                preview.problem = ruleProblem
            } else if proposed.isEmpty {
                preview.problem = "Name would be empty"
            } else if validateFileName(proposed) != nil {
                preview.problem = "Not a valid name"
            } else if proposed != original {
                // Only a name that changes can collide. A file the rules leave
                // alone goes nowhere, so it is never blocked — it used to be,
                // when another entry was renamed onto its name and the claimed
                // set then caught the unchanged file too, counting one
                // collision as two.
                //
                // An existing destination is only a collision when it is a
                // different file. A case-only rename on a case-insensitive
                // volume reports the destination as existing — it is the file
                // itself, and OperationEngine.rename allows that move. On a
                // case-sensitive volume the same spelling can be a second,
                // distinct file, so the test is file identity, not name case.
                let destination = url.deletingLastPathComponent().appendingPathComponent(proposed)
                // Identity alone is not enough: a hard link is the same inode
                // under a different name, and renaming onto it is a real
                // collision. Only a case-respelling of the same entry passes.
                let caseOnly = proposed.lowercased() == original.lowercased()
                if FileManager.default.fileExists(atPath: destination.path),
                   !(caseOnly && sameFile(url, destination)) {
                    preview.problem = "A file with this name already exists"
                } else if claimed.contains(proposed.lowercased()) {
                    preview.problem = "Two files would share this name"
                }
            }

            claimed.insert(proposed.lowercased())
            previews.append(preview)
        }
        return previews
    }

    private static func apply(
        _ rule: RenameRule, stem: String, ext: String, index: Int, url: URL, now: Date,
        problem: inout String?
    ) -> (String, String) {
        switch rule {
        case .findReplace(let find, let replace, let regex, let caseSensitive):
            guard !find.isEmpty else { return (stem, ext) }
            if regex {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                guard let expression = try? NSRegularExpression(pattern: find, options: options) else {
                    // A pattern that does not compile must not pass as "no
                    // matches" — the preview would read "No changes", which is
                    // indistinguishable from a valid pattern that matched
                    // nothing. Blocking the entry surfaces it in the summary,
                    // and the block clears as soon as the pattern compiles.
                    if problem == nil { problem = "The pattern does not compile" }
                    return (stem, ext)
                }
                let range = NSRange(stem.startIndex..., in: stem)
                let result = expression.stringByReplacingMatches(
                    in: stem, options: [], range: range, withTemplate: replace
                )
                return (result, ext)
            }
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return (stem.replacingOccurrences(of: find, with: replace, options: options), ext)

        case .addPrefix(let prefix):
            return (prefix + stem, ext)

        case .addSuffix(let suffix):
            return (stem + suffix, ext)

        case .sequence(let prefix, let start, let padding):
            let number = String(start + index)
            let padded = String(repeating: "0", count: max(0, padding - number.count)) + number
            return (prefix + padded, ext)

        case .changeCase(let style):
            switch style {
            case .lower: return (stem.lowercased(), ext.lowercased())
            case .upper: return (stem.uppercased(), ext)
            case .title: return (stem.capitalized, ext)
            }

        case .replaceExtension(let new):
            return (stem, new.hasPrefix(".") ? String(new.dropFirst()) : new)

        case .trimWhitespace:
            let collapsed = stem
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return (collapsed, ext)

        case .resequence(let start, let padding):
            guard let existing = Self.leadingNumber(in: stem) else {
                // Nothing to renumber. Left exactly as it was, and the preview
                // shows it unchanged rather than pretending it moved.
                return (stem, ext)
            }
            let number = String(start + index)
            let width = padding > 0 ? padding : existing.digits.count
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            return (padded + existing.rest, ext)

        case .insertDate(let format, let useCreated):
            let formatter = DateFormatter()
            formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd" : format
            // The file's own date, not the moment the rename ran — which is
            // what Finder gets wrong.
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
            let values = try? url.resourceValues(forKeys: keys)
            guard let date = useCreated ? values?.creationDate : values?.contentModificationDate else {
                // Falling back to the current time would stamp the moment the
                // rename ran into the filename — the very mistake this rule
                // exists to avoid, and undetectable once it is in the name.
                problem = useCreated ? "No creation date to use" : "No modification date to use"
                return (stem, ext)
            }
            return (stem + " " + formatter.string(from: date), ext)
        }
    }

    /// Renames everything in the plan, skipping entries with a problem. Returns
    /// the pairs that succeeded so the whole batch can be undone as one step.
    static func apply(_ plan: [RenamePreview]) -> (renamed: [(from: URL, to: URL)], failures: [(URL, Error)]) {
        var renamed: [(from: URL, to: URL)] = []
        var failures: [(URL, Error)] = []

        for preview in plan where preview.changed && preview.problem == nil {
            do {
                let destination = try OperationEngine.shared.rename(preview.url, to: preview.proposed)
                renamed.append((preview.url, destination))
            } catch {
                failures.append((preview.url, error))
            }
        }
        return (renamed, failures)
    }
}

extension UndoStack {
    /// A batch rename undoes as one action, not one per file.
    func pushBatchRename(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        push(Entry(label: "Rename \(pairs.count) item\(pairs.count == 1 ? "" : "s")") { done in
            DispatchQueue.global(qos: .userInitiated).async {
                var firstError: Error?
                for pair in pairs.reversed() {
                    do {
                        _ = try OperationEngine.shared.rename(pair.to, to: pair.from.lastPathComponent)
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                DispatchQueue.main.async { done(firstError) }
            }
        })
    }
}
