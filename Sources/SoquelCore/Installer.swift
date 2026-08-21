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

    /// The disk image for a version, or nil when the version is not one.
    ///
    /// The string can arrive from the advisory list, which is fetched over the
    /// network, and it used to be pasted straight into a URL and into two file
    /// paths. `../../../../tmp/evil` put the staging copy at
    /// `/tmp/evil-incoming.app`, outside the folder holding the application.
    /// Everything downstream now goes through `Version`, which accepts digits
    /// and dots and nothing else.
    static func downloadURL(for version: String) -> URL? {
        guard let parsed = Version(version) else { return nil }
        return URL(string: "https://github.com/AbhinavMir/soquel/releases/download/"
            + "v\(parsed)/Soquel-\(parsed).dmg")
    }

    enum Failure: LocalizedError, Equatable {
        case download(String)
        case unusableVersion(String)
        case cancelled
        case notSigned
        case mount(String)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .download(let why): return "The download failed: \(why)"
            case .unusableVersion(let text):
                return "“\(text)” is not a version number, so there is nothing to fetch."
            case .cancelled: return "Stopped before anything was replaced."
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
    @discardableResult
    static func install(version: String,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Swift.Result<String, Error>) -> Void) -> Job {
        let job = Job()
        guard let parsed = Version(version), let url = downloadURL(for: version) else {
            completion(.failure(Failure.unusableVersion(version)))
            return job
        }
        let version = parsed.description
        progress("Downloading Soquel \(version)…")

        let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
            func fail(_ error: Error) {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
            // Checked at each point where stopping is still free. Past the
            // swap there is no stopping: the application has been replaced.
            func stopped() -> Bool {
                guard job.isCancelled else { return false }
                fail(Failure.cancelled)
                return true
            }
            if stopped() { return }
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

            if stopped() { return }
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

            // The last point at which stopping costs nothing. After the swap
            // below the running application is already the new one.
            if stopped() { return }
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
        }
        job.task = task
        task.resume()
        return job
    }

    /// A running install, so the button that says Cancel can cancel.
    ///
    /// It used to say Cancel and do nothing: the alert closed, the download
    /// carried on, and the application was replaced anyway.
    final class Job {
        private let lock = NSLock()
        private var cancelled = false
        fileprivate var task: URLSessionDownloadTask?

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        /// Stops the download, and stops the install at the next point where
        /// stopping is still free. Once the swap has happened it is too late
        /// and this does nothing, which is the honest behaviour — the copy on
        /// disk is already the new one.
        func cancel() {
            lock.lock()
            cancelled = true
            let running = task
            lock.unlock()
            running?.cancel()
        }
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
