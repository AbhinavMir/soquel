import AppKit

/// Making a zip that does not carry macOS's litter.
///
/// Finder's Compress puts `.DS_Store` in the archive, adds a `__MACOSX` folder
/// full of `._` AppleDouble files, and writes resource forks nobody asked for.
/// Anyone who has sent a zip to somebody not on a Mac has been asked about it.
enum Archiver {
    /// What is never put in an archive.
    ///
    /// All of it is macOS bookkeeping: window positions, resource forks, the
    /// Spotlight index and the volume trash. None of it means anything to the
    /// person opening the file, and most of it is noise on any other system.
    static let excluded = [
        ".DS_Store",
        "__MACOSX",
        "._*",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
    ]

    /// What the archive is called.
    ///
    /// One item takes its own name, which is what you meant when you compressed
    /// one thing. Several take the folder's name rather than Finder's flat
    /// "Archive.zip", because a Downloads folder with four of those in it is
    /// four files you have to open to tell apart.
    static func archiveName(for urls: [URL], in directory: URL) -> String {
        guard let first = urls.first else { return "Archive.zip" }
        if urls.count == 1 {
            return first.deletingPathExtension().lastPathComponent + ".zip"
        }
        let folder = directory.lastPathComponent
        return (folder.isEmpty ? "Archive" : folder) + ".zip"
    }

    /// Appends " 2", " 3" … until the name is free, so compressing twice does
    /// not overwrite the first archive.
    static func uniqueURL(for name: String, in directory: URL,
                          fileManager: FileManager = .default) -> URL {
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).zip")
            counter += 1
        }
        return candidate
    }

    /// The arguments handed to `zip`.
    ///
    /// `-r` recurses, `-X` leaves out the extra attributes that become the
    /// `__MACOSX` folder, and each exclusion is matched both at the top level
    /// and at any depth — `-x .DS_Store` alone would only catch the one beside
    /// the items being compressed.
    static func arguments(archive: URL, items: [String]) -> [String] {
        var args = ["-r", "-X", "-q", archive.path]
        // "./" keeps a name like "-m" from being read as one of zip's own
        // options ("-m" deletes the files it archives). zip strips the prefix
        // when it stores the name, so the archive contents do not change.
        // "--" would not do: everything after it, the "-x" list included,
        // would be read as file names.
        args.append(contentsOf: items.map { "./" + $0 })
        args.append("-x")
        for pattern in excluded {
            args.append(pattern)
            args.append("*/\(pattern)")
            args.append("*/\(pattern)/*")
        }
        return args
    }

    struct Outcome {
        let archive: URL?
        let message: String
    }

    /// Compresses `urls` into their own folder. The completion runs on the main
    /// queue.
    ///
    /// Paths are passed relative to the working directory rather than absolute,
    /// or the archive would carry the whole of `/Users/you/...` inside it.
    static func compress(
        _ urls: [URL],
        completion: @escaping (Outcome) -> Void
    ) {
        guard let first = urls.first else {
            completion(Outcome(archive: nil, message: "Nothing to compress"))
            return
        }
        let directory = first.deletingLastPathComponent()
        let archive = uniqueURL(for: archiveName(for: urls, in: directory), in: directory)
        let names = urls.map(\.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            task.arguments = arguments(archive: archive, items: names)
            task.currentDirectoryURL = directory

            let errors = Pipe()
            task.standardError = errors
            task.standardOutput = Pipe()

            let outcome: Outcome
            do {
                try task.run()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    outcome = Outcome(
                        archive: archive,
                        message: "Made \(archive.lastPathComponent)"
                    )
                } else {
                    // Leave nothing half-written behind.
                    try? FileManager.default.removeItem(at: archive)
                    let reason = String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    outcome = Outcome(
                        archive: nil,
                        message: reason.isEmpty
                            ? "Could not make the archive"
                            : "Could not make the archive: \(reason)"
                    )
                }
            } catch {
                outcome = Outcome(
                    archive: nil,
                    message: "Could not run zip: \(error.localizedDescription)"
                )
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// The menu title, which names what is about to happen.
    static func menuTitle(for urls: [URL]) -> String {
        guard let first = urls.first else { return "Compress" }
        if urls.count == 1 { return "Compress “\(first.lastPathComponent)”" }
        return "Compress \(urls.count) Items"
    }
}
