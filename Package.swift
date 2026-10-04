// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageSniffer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "StorageSniffer", targets: ["StorageSniffer"]),
        .executable(name: "sniff", targets: ["sniff"]),
    ],
    targets: [
        // Scanner, tree model and treemap layout. No UI dependencies.
        .target(name: "SnifferCore"),
        // The SwiftUI app.
        .executableTarget(name: "StorageSniffer", dependencies: ["SnifferCore"]),
        // Command-line scanner, used for benchmarking and checking accuracy against `du`.
        .executableTarget(name: "sniff", dependencies: ["SnifferCore"]),
        .testTarget(name: "SnifferCoreTests", dependencies: ["SnifferCore"]),
    ]
)
