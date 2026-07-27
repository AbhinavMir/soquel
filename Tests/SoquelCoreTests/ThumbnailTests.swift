import XCTest
@testable import SoquelCore

final class ThumbnailCacheTests: XCTestCase {
    private func item(_ path: String, isDirectory: Bool = false, isSymlink: Bool = false) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isPackage: false,
            isSymlink: isSymlink,
            isHidden: false,
            size: 0,
            modified: Date(timeIntervalSince1970: 0),
            created: Date(timeIntervalSince1970: 0),
            kind: "Document"
        )
    }

    /// A folder's Quick Look thumbnail is a picture of its first item, which
    /// makes similar folders indistinguishable. They keep the type icon.
    func testFoldersAndSymlinksKeepTheirTypeIcon() {
        XCTAssertFalse(ThumbnailCache.wantsThumbnail(item("/tmp/folder", isDirectory: true)))
        XCTAssertFalse(ThumbnailCache.wantsThumbnail(item("/tmp/link", isSymlink: true)))
        XCTAssertTrue(ThumbnailCache.wantsThumbnail(item("/tmp/photo.jpg")))
    }

    func testCacheKeyChangesWithSize() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertNotEqual(
            ThumbnailCache.key(for: url, size: 64, modified: date),
            ThumbnailCache.key(for: url, size: 128, modified: date)
        )
    }

    /// An edited file must not keep showing the image of its old contents.
    func testCacheKeyChangesWhenTheFileIsModified() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        XCTAssertNotEqual(
            ThumbnailCache.key(for: url, size: 64, modified: Date(timeIntervalSince1970: 1000)),
            ThumbnailCache.key(for: url, size: 64, modified: Date(timeIntervalSince1970: 2000))
        )
    }

    func testCacheKeyIsStableForTheSameFile() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            ThumbnailCache.key(for: url, size: 64, modified: date),
            ThumbnailCache.key(for: url, size: 64, modified: date)
        )
    }

    func testMissingModificationDateStillProducesAKey() {
        let key = ThumbnailCache.key(for: URL(fileURLWithPath: "/tmp/a.png"), size: 64, modified: nil)
        XCTAssertTrue((key as String).hasSuffix("|0"))
    }

    func testAnUncachedFileReportsNoImage() {
        XCTAssertNil(ThumbnailCache.shared.cached(
            for: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png"),
            size: 64, modified: nil
        ))
    }

    func testCancellingAnUnknownTokenIsHarmless() {
        ThumbnailCache.shared.cancel(nil)
        ThumbnailCache.shared.cancel(UUID())
    }
}
