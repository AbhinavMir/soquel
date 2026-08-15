import Foundation

/// SFTP with nothing to install.
///
/// The usual answer on macOS is macFUSE and sshfs — a kernel extension, a
/// reboot, and a trip through Security settings before anything works. The
/// second usual answer is sshpass, which is not on macOS either and puts the
/// password in the command line where any other process can read it.
///
/// Neither is necessary. `/usr/bin/sftp` ships with the system, and OpenSSH
/// reads a password from a helper program when `SSH_ASKPASS_REQUIRE` is set,
/// so the password goes over a pipe instead of the argument list. One master
/// connection is opened and every later operation rides on it, so the password
/// is asked for once and a listing costs no handshake.
final class SFTPSession {
    struct Location: Equatable, Hashable {
        var user: String
        var host: String
        var port: Int?
        /// The folder the URL pointed at, or "." when it named only a host.
        var path: String

        var destination: String { "\(user)@\(host)" }

        /// `sftp://user@host:2222/srv/data` and the same without a port or path.
        init?(url: URL) {
            guard url.scheme?.lowercased() == "sftp",
                  let host = url.host, !host.isEmpty,
                  let user = url.user, !user.isEmpty
            else { return nil }
            self.user = user
            self.host = host
            self.port = url.port
            let path = url.path
            self.path = path.isEmpty ? "." : path
        }

        init(user: String, host: String, port: Int? = nil, path: String = ".") {
            self.user = user
            self.host = host
            self.port = port
            self.path = path
        }
    }

    /// One remote file or folder.
    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        var isSymlink: Bool
        var size: Int64
        var modified: Date?
        var permissions: String
    }

    enum Failure: LocalizedError, Equatable {
        case notConnected
        case authenticationFailed
        case hostUnreachable(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to the server."
            case .authenticationFailed:
                return "The server refused that username or password."
            case .hostUnreachable(let host):
                return "Could not reach \(host)."
            case .commandFailed(let detail):
                return detail
            }
        }
    }

    let location: Location
    private let controlPath: String
    private var askpassURL: URL?

    init(location: Location) {
        self.location = location
        self.controlPath = Self.controlPath(for: location)
    }

    deinit { disconnect() }

    // MARK: - The control socket

    /// A Unix socket path cannot exceed 104 bytes, and the obvious home for one
    /// — the application's own caches folder — is already longer than that
    /// before a filename is added. So the socket lives in `/tmp` under a digest
    /// of the destination, which is both short and stable.
    static func controlPath(for location: Location) -> String {
        var seed = "\(location.user)@\(location.host)"
        if let port = location.port { seed += ":\(port)" }
        return "/tmp/soquel-sftp-\(digest(of: seed))"
    }

    /// A short hex digest. Not a security boundary — it only has to keep two
    /// destinations from sharing a socket.
    static func digest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    var isConnected: Bool {
        let result = Self.run("/usr/bin/ssh", ["-S", controlPath, "-O", "check", location.destination])
        return result.status == 0
    }

    /// Opens the master connection, asking the server for a password only if it
    /// wants one. A host with a key already in the agent never sees `password`.
    func connect(password: String?) throws {
        if isConnected { return }

        var arguments = [
            "-M", "-S", controlPath,
            "-o", "ControlPersist=600",
            "-o", "ConnectTimeout=15",
            // First contact records the host key rather than refusing outright.
            // Refusing means the user has no way to say yes; a later change of
            // key is still rejected, which is the case that matters.
            "-o", "StrictHostKeyChecking=accept-new",
            "-fN",
        ]
        if let port = location.port { arguments += ["-p", String(port)] }

        var environment = ProcessInfo.processInfo.environment
        if let password {
            let helper = try writeAskpass()
            askpassURL = helper
            environment["SSH_ASKPASS"] = helper.path
            // Without `force` OpenSSH only consults the helper when it has no
            // terminal, and an application launched from Finder sometimes has
            // one inherited. Needs OpenSSH 8.4 or newer; macOS 13 ships 9.
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SOQUEL_SFTP_PASSWORD"] = password
            arguments += ["-o", "NumberOfPasswordPrompts=1"]
        } else {
            arguments += ["-o", "BatchMode=yes"]
        }
        arguments.append(location.destination)

        let result = Self.run("/usr/bin/ssh", arguments, environment: environment)
        forgetAskpass()

        guard result.status == 0 else {
            throw Self.failure(from: result.output, host: location.host)
        }
    }

    func disconnect() {
        _ = Self.run("/usr/bin/ssh", ["-S", controlPath, "-O", "exit", location.destination])
        forgetAskpass()
    }

    /// The helper exists only while a connection is being made, holds no
    /// secret itself, and is readable by nobody else.
    private func writeAskpass() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("soquel-askpass-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s' \"$SOQUEL_SFTP_PASSWORD\"\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
        return url
    }

    private func forgetAskpass() {
        guard let askpassURL else { return }
        try? FileManager.default.removeItem(at: askpassURL)
        self.askpassURL = nil
    }

    // MARK: - Operations

    func list(_ path: String) throws -> [Entry] {
        // `cd` first so the names come back bare. Listing a path directly
        // prefixes every name with it, which then has to be stripped back off.
        let output = try batch(["cd \(Self.quote(path))", "ls -la"])
        return Self.parse(listing: output)
    }

    func download(_ remote: String, to local: URL) throws {
        _ = try batch(["get \(Self.quote(remote)) \(Self.quote(local.path))"])
    }

    func upload(_ local: URL, to remote: String) throws {
        _ = try batch(["put \(Self.quote(local.path)) \(Self.quote(remote))"])
    }

    func rename(_ from: String, to: String) throws {
        _ = try batch(["rename \(Self.quote(from)) \(Self.quote(to))"])
    }

    func remove(_ path: String) throws {
        _ = try batch(["rm \(Self.quote(path))"])
    }

    func removeDirectory(_ path: String) throws {
        _ = try batch(["rmdir \(Self.quote(path))"])
    }

    func makeDirectory(_ path: String) throws {
        _ = try batch(["mkdir \(Self.quote(path))"])
    }

    /// Runs commands down the existing master connection.
    private func batch(_ commands: [String]) throws -> String {
        // sftp reads one command per line from `-b -`, and its quoting has no
        // way to carry a line break. A name with one would split into two
        // commands and do something other than what was asked.
        for command in commands where command.contains("\n") {
            throw Failure.commandFailed("The name contains a line break, which sftp cannot carry.")
        }
        let arguments = [
            "-o", "ControlPath=\(controlPath)",
            // `-b` turns BatchMode on, which switches password authentication
            // off entirely. The master is already authenticated, but a server
            // that drops it would otherwise fail with a misleading
            // "Permission denied" instead of asking again.
            "-o", "BatchMode=no",
            "-b", "-",
            location.destination,
        ]
        let result = Self.run("/usr/bin/sftp", arguments, input: commands.joined(separator: "\n") + "\n")
        guard result.status == 0 else {
            throw Self.operationFailure(from: result.output, host: location.host)
        }
        return result.output
    }

    // MARK: - Reading what sftp says

    /// One `ls -l` line, whatever is in the filename.
    ///
    /// Splitting on whitespace breaks the moment a name contains a space, and
    /// counting fields from the right breaks on the same thing. So does
    /// counting the owner and group fields from the left: either can carry a
    /// space ("Domain Users"). Anchoring on the parts whose shape is fixed —
    /// the mode string at the front, then the first size-and-date pair —
    /// leaves the name as everything after, spaces and all. Every file type
    /// letter is accepted, sockets and devices included, and a device's
    /// "major, minor" is taken where the size goes. OpenSSH puts exactly one
    /// space between the date and the name, so a name's own leading spaces
    /// survive.
    static let lineExpression = try? NSRegularExpression(
        pattern: #"^([dlspcb\-])([rwxsStT\-]{9})[+@.]?\s+.+?\s(\d+(?:,\s*\d+)?)\s+"#
            + #"(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})) (.+)$"#
    )

    static func parse(listing: String) -> [Entry] {
        var entries: [Entry] = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = parse(line: String(line)) else { continue }
            // The server lists these; they are not files anyone wants shown.
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry)
        }
        return entries
    }

    static func parse(line: String) -> Entry? {
        guard let expression = lineExpression else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              match.numberOfRanges == 6,
              let kindRange = Range(match.range(at: 1), in: line),
              let modeRange = Range(match.range(at: 2), in: line),
              let sizeRange = Range(match.range(at: 3), in: line),
              let dateRange = Range(match.range(at: 4), in: line),
              let nameRange = Range(match.range(at: 5), in: line)
        else { return nil }

        let kind = String(line[kindRange])
        var name = String(line[nameRange])
        // A symlink is written "link -> target". The link is the file.
        if kind == "l", let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrow.lowerBound])
        }
        // Not trimmed: a name really can end in a space, and addressing it
        // without one names a file that does not exist on the server.
        guard !name.isEmpty else { return nil }

        return Entry(
            name: name,
            isDirectory: kind == "d",
            isSymlink: kind == "l",
            size: Int64(line[sizeRange]) ?? 0,
            modified: date(from: String(line[dateRange])),
            permissions: kind + String(line[modeRange])
        )
    }

    /// `ls` prints a time for this year and a year for anything older, so a
    /// recent file has no year written down and takes the current one.
    static func date(from text: String, now: Date = Date()) -> Date? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { return nil }
        let calendar = Calendar(identifier: .gregorian)

        var components = DateComponents()
        components.month = months[parts[0].lowercased()]
        components.day = Int(parts[1])
        guard components.month != nil, components.day != nil else { return nil }

        if parts[2].contains(":") {
            let clock = parts[2].split(separator: ":")
            guard clock.count == 2 else { return nil }
            components.hour = Int(clock[0])
            components.minute = Int(clock[1])
            let thisYear = calendar.component(.year, from: now)
            components.year = thisYear
            // A date that has not happened yet belongs to last year: `ls` drops
            // the year for anything within six months either way.
            if let candidate = calendar.date(from: components), candidate > now.addingTimeInterval(86_400) {
                components.year = thisYear - 1
            }
        } else {
            components.year = Int(parts[2])
            guard components.year != nil else { return nil }
        }
        return calendar.date(from: components)
    }

    static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// What went wrong mid-session. "Permission denied" here is the server
    /// refusing a file, not a password — the master already authenticated —
    /// so only the reachability patterns are translated and the rest is
    /// reported in sftp's own words.
    static func operationFailure(from output: String, host: String) -> Failure {
        let text = output.lowercased()
        if text.contains("could not resolve") || text.contains("no route to host")
            || text.contains("connection refused") || text.contains("operation timed out")
            || text.contains("connection timed out") {
            return .hostUnreachable(host)
        }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? "The server rejected that." : detail)
    }

    /// What went wrong while connecting, in words rather than ssh's. Only
    /// here does "permission denied" mean the credentials: this is ssh's own
    /// authentication verdict, not a file the server would not hand over.
    static func failure(from output: String, host: String) -> Failure {
        let text = output.lowercased()
        if text.contains("permission denied") || text.contains("authentication failed") {
            return .authenticationFailed
        }
        if text.contains("could not resolve") || text.contains("no route to host")
            || text.contains("connection refused") || text.contains("operation timed out")
            || text.contains("connection timed out") {
            return .hostUnreachable(host)
        }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? "The server rejected that." : detail)
    }

    /// Wraps a path for sftp, which splits its command line on spaces and
    /// understands double quotes.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Running the tools

    struct Result {
        var status: Int32
        var output: String
    }

    @discardableResult
    static func run(
        _ tool: String, _ arguments: [String],
        input: String? = nil, environment: [String: String]? = nil
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }

        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        try? stdin.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
