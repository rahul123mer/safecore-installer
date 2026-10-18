// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafeCore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SafeCore", path: "Sources/SafeCore")
    ]
)
