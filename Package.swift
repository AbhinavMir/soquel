// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Soquel",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything lives in the library so it can be exercised by tests; the
        // executable is only an entry point.
        .target(
            name: "SoquelCore",
            path: "Sources/SoquelCore",
            // NetFS mounts SMB, AFP, NFS, WebDAV and FTP; it is not linked in
            // by default the way AppKit is.
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        .executableTarget(
            name: "Soquel",
            dependencies: ["SoquelCore"],
            path: "Sources/Soquel"
        ),
        .testTarget(
            name: "SoquelCoreTests",
            dependencies: ["SoquelCore"],
            path: "Tests/SoquelCoreTests"
        ),
    ]
)
