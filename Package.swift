// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Reforge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Reforge", path: "Sources/Reforge")
    ],
    swiftLanguageModes: [.v5]
)
