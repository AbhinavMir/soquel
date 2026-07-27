import CryptoKit
import Foundation

/// File checksums, read in chunks so a large file does not have to fit in
/// memory. The research puts verified copy in a professional niche, but the
/// digest itself is cheap to offer in the inspector.
enum Checksum {
    /// Lowercase hex SHA-256, or nil when the file cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
