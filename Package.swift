// swift-tools-version: 6.0
import PackageDescription

// Keep the OpenSSH data types and parsers independently testable.
let package = Package(
    name: "Portlane",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PortlaneCore"),
        .testTarget(name: "PortlaneCoreTests", dependencies: ["PortlaneCore"])
    ],
    swiftLanguageModes: [.v6]
)
