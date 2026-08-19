import AppKit

/// Replacing the running copy with another version, in one click.
///
/// This exists for one situation: the build on this disk is on the recall list
/// and has to go, either forward to the fix or back to the last good version.
/// It is not a background updater. Nothing here runs on its own, nothing is
/// downloaded until a button is pressed, and every step is refused rather than
/// forced.
///
/// What is downloaded is checked before it is trusted. A disk image that is
/// not signed by this developer is deleted and reported, because an installer
/// that will run anything it was handed is worse than no installer.
enum Installer {
    /// The signature the replacement must carry. Anything else is not Soquel,
    /// whatever the file is called and wherever it came from.
    static let requirement =
        "identifier \"app.soquel.Soquel\" and anchor apple generic and "
        + "certificate leaf[subject.OU] = \"P4ANTPX4G4\""

    static func downloadURL(for version: String) -> URL {
        URL(string: "https://github.com/AbhinavMir/soquel/releases/download/"
            + "v\(version)/Soquel-\(version).dmg")!
    }

    enum Failure: LocalizedError {
        case download(String)
        case notSigned
        case mount(String)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .download(let why): return "The download failed: \(why)"
            case .notSigned:
                return "The downloaded copy is not signed by Soquel's developer. "
                    + "It has been deleted and nothing was installed."
            case .mount(let why): return "The disk image could not be opened: \(why)"
            case .install(let why): return "The copy could not be put in place: \(why)"
            }
        }
    }

    /// Where the running application is. Replacing anything else would be
    /// replacing something that is not us.
    static var installedLocation: URL { Bundle.main.bundleURL }

    // MARK: - Steps

    private static func run(_ tool: String, _ arguments: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (127, "could not run \(tool)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Downloads, verifies, and swaps the application in place.
    ///
    /// Progress is reported so a click does not look like nothing happening.
    /// The completion carries either the version now installed, or why not.
    static func install(version: String,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let url = downloadURL(for: version)
        progress("Downloading Soquel \(version)…")

        URLSession.shared.downloadTask(with: url) { temporary, response, error in
            func fail(_ error: Error) {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
            if let error { return fail(Failure.download(error.localizedDescription)) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return fail(Failure.download("the server answered \(http.statusCode)"))
            }
            guard let temporary else { return fail(Failure.download("nothing arrived")) }

            // downloadTask deletes its file when this handler returns, so it
            // is moved somewhere of our own before anything else touches it.
            let image = FileManager.default.temporaryDirectory
                .appendingPathComponent("Soquel-\(version)-\(UUID().uuidString).dmg")
            do { try FileManager.default.moveItem(at: temporary, to: image) }
            catch { return fail(Failure.download(error.localizedDescription)) }
            defer { try? FileManager.default.removeItem(at: image) }

            DispatchQueue.main.async { progress("Checking the signature…") }

            let mountPoint = FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-install-\(UUID().uuidString)")
            let attach = run("/usr/bin/hdiutil", [
                "attach", image.path, "-nobrowse", "-readonly", "-noverify",
                "-mountpoint", mountPoint.path
            ])
            guard attach.0 == 0 else { return fail(Failure.mount(attach.1)) }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

            let candidate = mountPoint.appendingPathComponent("Soquel.app")
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return fail(Failure.mount("the image holds no Soquel.app"))
            }

            // The gate. Not a warning, not a preference — a refusal.
            let verified = run("/usr/bin/codesign", [
                "--verify", "--deep", "--strict",
                "-R=\(requirement)", candidate.path
            ])
            guard verified.0 == 0 else {
                Log.info(.app, "refused an unsigned replacement: \(verified.1)")
                return fail(Failure.notSigned)
            }

            DispatchQueue.main.async { progress("Installing Soquel \(version)…") }

            let destination = installedLocation
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent("Soquel-\(version)-incoming.app")
            try? FileManager.default.removeItem(at: staging)
            do {
                // Copied beside the old one first. A copy that fails half way
                // then leaves the working application untouched, rather than
                // leaving no application at all.
                try FileManager.default.copyItem(at: candidate, to: staging)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                return fail(Failure.install(error.localizedDescription))
            }

            DispatchQueue.main.async { completion(.success(version)) }
        }.resume()
    }

    /// Starts the newly installed copy and stands down.
    ///
    /// `open -n` on the bundle rather than a relaunch of this process: the
    /// binary on disk has changed underneath it, and the copy that should be
    /// running is the new one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installedLocation,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
