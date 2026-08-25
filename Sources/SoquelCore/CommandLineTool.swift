import Foundation

/// Installs the small `soquel` launcher used from a shell.
///
/// The launcher goes through Launch Services rather than running the executable
/// inside the bundle directly. That keeps one application instance and makes
/// path arguments arrive through `application(_:open:)`, just like folders
/// opened from Finder.
enum CommandLineTool {
    static let destinationURL = URL(fileURLWithPath: "/usr/local/bin/soquel")
    static let launcher = """
    #!/bin/sh
    exec /usr/bin/open -b app.soquel.Soquel -- "$@"
    """ + "\n"

    static func isInstalled(at url: URL = destinationURL) -> Bool {
        guard let installed = try? String(contentsOf: url, encoding: .utf8),
              installed == launcher else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func exists(at url: URL = destinationURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the launcher without elevation. Kept separate from `install` so
    /// the exact installed file and its mode can be exercised in tests.
    static func write(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try launcher.write(to: url, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Installs into `/usr/local/bin`, asking macOS for an administrator name
    /// only when that system directory is not writable by the current user.
    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                let parent = destinationURL.deletingLastPathComponent()
                if FileManager.default.isWritableFile(atPath: parent.path) {
                    try write(at: destinationURL)
                } else {
                    try installWithAdministratorPrivileges()
                }
                guard isInstalled() else { throw InstallError.verificationFailed }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func installWithAdministratorPrivileges() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(at: temporary)

        let command = "/usr/bin/install -d -m 755 /usr/local/bin && "
            + "/usr/bin/install -m 755 \(shellQuote(temporary.path)) /usr/local/bin/soquel"
        let appleScript = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.commandFailed(detail ?? "Installation was cancelled.")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    enum InstallError: LocalizedError {
        case commandFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .commandFailed(let detail): return detail
            case .verificationFailed:
                return "The installed command could not be verified."
            }
        }
    }
}
