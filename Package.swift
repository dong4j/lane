// swift-tools-version: 6.0
import PackageDescription

// Keep the OpenSSH data types and parsers independently testable.
let package = Package(
    name: "Portlane",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Portlane", targets: ["Portlane"])],
    targets: [
        .target(name: "PortlaneCore"),
        .executableTarget(name: "Portlane", dependencies: ["PortlaneCore"]),
        .testTarget(name: "PortlaneCoreTests", dependencies: ["PortlaneCore", "Portlane"])
    ],
    swiftLanguageModes: [.v6]
)
