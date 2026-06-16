// swift-tools-version:5.9
import PackageDescription

// cc-tailsync — the iOS-side sync library for the cc-mods suite.
//
// `CCTailsync` is a small, self-contained Swift package. It depends on NOTHING from cc-ios, so it
// can be versioned and built independently. cc-ios consumes it *optionally* (see
// `tools/integrate-ios.sh`): cc-ios owns a `SaveSyncProvider` protocol and this package's
// `TailscaleSyncClient` conforms to it structurally, so cc-ios builds fine with or without us.
let package = Package(
    name: "cc-tailsync",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CCTailsync", targets: ["CCTailsync"]),
    ],
    targets: [
        .target(name: "CCTailsync", path: "Sources/CCTailsync"),
    ]
)
