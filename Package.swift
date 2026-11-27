// swift-tools-version: 6.0
import PackageDescription

// Keep the OpenSSH data types and parsers independently testable.
let package = Package(
    name: "Lane",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Lane", targets: ["Lane"])],
    targets: [
        .target(name: "LaneCore"),
        .executableTarget(name: "Lane", dependencies: ["LaneCore"]),
        .testTarget(name: "LaneCoreTests", dependencies: ["LaneCore", "Lane"])
    ],
    swiftLanguageModes: [.v6]
)
