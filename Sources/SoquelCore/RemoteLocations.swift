import AppKit
import Foundation
import NetFS

extension Notification.Name {
    static let soquelServersChanged = Notification.Name("app.soquel.serversChanged")
}

/// Connecting to a file server.
///
/// A mounted server is an ordinary path, so everything else in the application
/// — search, compare, the shelf, the inspector — works on it without knowing
/// it is remote. That is the whole reason to mount rather than to build a
/// second, weaker file browser for network volumes.
enum RemoteLocations {
    /// The protocols, and whether macOS can mount them without help.
    enum Scheme: String, CaseIterable {
        case smb
        case afp
        case nfs
        case https
        case http
        case ftp
        case sftp

        var title: String {
            switch self {
            case .smb: return "SMB"
            case .afp: return "AFP"
            case .nfs: return "NFS"
            case .https: return "WebDAV over HTTPS"
            case .http: return "WebDAV"
            case .ftp: return "FTP"
            case .sftp: return "SFTP"
            }
        }

        /// macOS mounts these itself. SFTP is not among them: it needs macFUSE
        /// and sshfs, which are third-party and cannot be shipped here.
        var isNative: Bool { self != .sftp }

        /// FTP is mounted read-only by macOS, and saying so up front beats a
        /// permission error on the first save.
        var isReadOnly: Bool { self == .ftp }
    }

    /// A server address, parsed and checked.
    struct Address: Equatable {
        let scheme: Scheme
        let host: String
        let user: String?
        let port: Int?
        /// Share or path on the server; empty means the server's root.
        let path: String

        /// What the mount would be called under /Volumes, for reporting.
        var displayName: String {
            let last = path.split(separator: "/").last.map(String.init)
            return last?.isEmpty == false ? last! : host
        }

        var url: URL? {
            var components = URLComponents()
            components.scheme = scheme.rawValue
            components.host = host
            components.user = user
            components.port = port
            components.path = path.hasPrefix("/") ? path : (path.isEmpty ? "" : "/" + path)
            return components.url
        }
    }

    enum AddressError: Error, LocalizedError, Equatable {
        case empty
        case unknownScheme(String)
        case missingScheme
        case missingHost
        case unreadable
        case needsFUSE(Scheme)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a server address."
            case .missingScheme:
                return "Start the address with a protocol, such as smb:// or https://."
            case .unknownScheme(let scheme):
                return "“\(scheme)” is not a protocol this can mount. Use "
                    + Scheme.allCases.filter(\.isNative).map { $0.rawValue + "://" }.joined(separator: ", ") + "."
            case .missingHost:
                return "The address has no server name."
            case .unreadable:
                return "That address could not be read."
            case .needsFUSE(let scheme):
                // Nothing to install any more: SFTP opens in a browser window
                // driven by the ssh already on the system. This is left for
                // any other scheme that reaches it.
                return "macOS cannot mount \(scheme.rawValue):// on its own."
            }
        }
    }

    // MARK: - Parsing

    /// Reads a typed address. Rejects rather than guesses: a bare hostname
    /// could be any of five protocols, and picking one for the user would
    /// silently connect them to the wrong thing.
    static func parse(_ text: String) -> Result<Address, AddressError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard let separator = trimmed.range(of: "://") else { return .failure(.missingScheme) }
        let rawScheme = String(trimmed[trimmed.startIndex..<separator.lowerBound]).lowercased()
        guard let scheme = Scheme(rawValue: rawScheme) else {
            return .failure(.unknownScheme(rawScheme))
        }

        guard let components = urlComponents(from: trimmed) else { return .failure(.unreadable) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }

        return .success(Address(
            scheme: scheme,
            host: host,
            user: components.user?.isEmpty == false ? components.user : nil,
            port: components.port,
            path: components.path
        ))
    }

    /// URLComponents on macOS 13 is a strict RFC 3986 parser: a raw space
    /// anywhere makes it return nil, and "smb://server/My Share" is an
    /// address people type. Newer systems encode the stray characters
    /// themselves; the supported minimum gets its spaces encoded by hand.
    private static func urlComponents(from text: String) -> URLComponents? {
        if let components = URLComponents(string: text) { return components }
        if #available(macOS 14.0, *) {
            return URLComponents(string: text, encodingInvalidCharacters: true)
        }
        guard let separator = text.range(of: "://") else { return nil }
        let encoded = text[separator.upperBound...].replacingOccurrences(of: " ", with: "%20")
        return URLComponents(string: String(text[..<separator.upperBound]) + encoded)
    }

    /// Whether this address can be mounted on this machine right now.
    static func check(_ address: Address, sshfsPath: String? = locateSSHFS()) -> AddressError? {
        if !address.scheme.isNative && sshfsPath == nil {
            return .needsFUSE(address.scheme)
        }
        return nil
    }

    /// sshfs, if the user has installed macFUSE.
    static func locateSSHFS() -> String? {
        ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Mounting

    struct Mounted {
        let address: Address
        /// Where it landed, usually under /Volumes.
        let mountPoint: URL
    }

    /// Mounts a server. The completion runs on the main queue.
    ///
    /// Credentials are left to the system: passing nil for user and password
    /// makes NetFS use the keychain entry and put up the standard
    /// authentication sheet when there is none, rather than this application
    /// collecting passwords it has no business holding.
    static func mount(_ address: Address, completion: @escaping (Result<Mounted, Error>) -> Void) {
        guard let url = address.url else {
            completion(.failure(AddressError.missingHost))
            return
        }
        if let problem = check(address) {
            completion(.failure(problem))
            return
        }

        guard address.scheme.isNative else {
            mountWithSSHFS(address, completion: completion)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var mountPoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL,
                nil,                    // let the system choose the mount point
                address.user as CFString?,
                nil,                    // password: keychain, or the system's own prompt
                nil, nil,
                &mountPoints
            )

            DispatchQueue.main.async {
                guard status == 0 else {
                    let problem = mountError(status: status, address: address)
                    Log.error(.remote, "Mount of \(address.scheme.rawValue)://\(address.host) "
                        + "failed with \(status): \(problem.localizedDescription)")
                    completion(.failure(problem))
                    return
                }
                Log.info(.remote, "Mounted \(address.scheme.rawValue)://\(address.host)")
                let paths = mountPoints?.takeRetainedValue() as? [String] ?? []
                guard let first = paths.first else {
                    // A zero status with no mount point means it was already
                    // mounted somewhere; find it rather than reporting nothing.
                    if let existing = existingMount(for: address) {
                        remember(address)
                        completion(.success(Mounted(address: address, mountPoint: existing)))
                    } else {
                        completion(.failure(NSError(
                            domain: "app.soquel.netfs", code: Int(EEXIST),
                            userInfo: [NSLocalizedDescriptionKey:
                                "\(address.host) is already mounted, but its volume was not found."]
                        )))
                    }
                    return
                }
                remember(address)
                completion(.success(Mounted(address: address, mountPoint: URL(fileURLWithPath: first))))
            }
        }
    }

    /// SFTP through sshfs, when the user has macFUSE installed.
    private static func mountWithSSHFS(
        _ address: Address, completion: @escaping (Result<Mounted, Error>) -> Void
    ) {
        guard let sshfs = locateSSHFS() else {
            completion(.failure(AddressError.needsFUSE(address.scheme)))
            return
        }
        let mountPoint = URL(fileURLWithPath: "/Volumes")
            .appendingPathComponent(address.displayName)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                let remote = (address.user.map { "\($0)@" } ?? "") + address.host
                    + ":" + (address.path.isEmpty ? "/" : address.path)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: sshfs)
                // FUSE splits an -o value on commas and has no way to escape
                // one, so a comma in the share name would smuggle extra mount
                // options in. A space keeps the name readable and inert.
                let volname = address.displayName.replacingOccurrences(of: ",", with: " ")
                // Arguments are passed as a list, never through a shell, so a
                // hostname can never be read as a command.
                process.arguments = [remote, mountPoint.path, "-o", "volname=\(volname)"]
                let errors = Pipe()
                process.standardError = errors
                try process.run()

                // The pipe is drained before waiting: a child that fills the
                // pipe's buffer blocks on write, and waiting on it first
                // deadlocks both sides. sshfs closes stderr when it
                // daemonizes, so the read ends on success too.
                let message = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                process.waitUntilExit()

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        remember(address)
                        completion(.success(Mounted(address: address, mountPoint: mountPoint)))
                    } else {
                        completion(.failure(NSError(
                            domain: "app.soquel.sshfs", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message.isEmpty
                                ? "sshfs could not mount \(address.host)." : message]
                        )))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// An already-mounted volume for this address, matched by where it was
    /// mounted from. Matching by name is not enough: mountedVolumeURLs also
    /// lists local volumes and disk images, and one of those that happens to
    /// share the name must not stand in for the server.
    static func existingMount(for address: Address) -> URL? {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []
        ) ?? []
        let slashes = CharacterSet(charactersIn: "/")
        let wanted = address.path.trimmingCharacters(in: slashes).lowercased()
        return volumes.first { volume in
            guard let values = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]),
                  let source = values.volumeURLForRemounting,
                  source.host?.lowercased() == address.host.lowercased()
            else { return false }
            // An address without a share names only the server, so any
            // volume mounted from that server answers it.
            guard !wanted.isEmpty else { return true }
            return source.path.trimmingCharacters(in: slashes).lowercased() == wanted
        }
    }

    /// Turns a NetFS status into something a person can act on. The numbers are
    /// POSIX errnos; the rest are NetFS's own and are reported as-is rather
    /// than guessed at.
    static func mountError(status: Int32, address: Address) -> NSError {
        let message: String
        switch status {
        case Int32(ECANCELED):
            message = "Cancelled."
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            message = "\(address.host) refused those credentials."
        case Int32(ENETDOWN), Int32(ENETUNREACH), Int32(EHOSTUNREACH), Int32(EHOSTDOWN):
            message = "\(address.host) could not be reached."
        case Int32(ETIMEDOUT):
            message = "\(address.host) did not answer."
        case Int32(ENOENT):
            message = "\(address.host) has no share at that path."
        default:
            message = "Could not mount \(address.host) (error \(status))."
        }
        return NSError(domain: "app.soquel.netfs", code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Recents

    private static let recentsKey = "recentServers"
    static let recentLimit = 10

    static var recents: [String] {
        Settings.stringArray(forKey: recentsKey) ?? []
    }

    /// Most recent first, without duplicates. The password is never part of
    /// this: only what the user typed, and they cannot type one into the field
    /// because the field takes an address, not credentials.
    static func remember(_ address: Address) {
        guard let text = address.url?.absoluteString else { return }
        var list = recents.filter { $0 != text }
        list.insert(text, at: 0)
        Settings.set(Array(list.prefix(recentLimit)), forKey: recentsKey)
        NotificationCenter.default.post(name: .soquelServersChanged, object: nil)
    }

    static func forgetRecents() {
        Settings.set([String](), forKey: recentsKey)
        NotificationCenter.default.post(name: .soquelServersChanged, object: nil)
    }

    /// Unmounts a volume. Used by the sidebar's eject action.
    static func unmount(_ url: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}
