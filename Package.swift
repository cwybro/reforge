// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Reforge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Reforge", path: "Sources/Reforge"),
        // Tests `@testable import` the executable target directly (SwiftPM supports this on macOS).
        // Run them with `make test`, which adds the Swift Testing search paths the Command Line Tools need.
        .testTarget(name: "ReforgeTests", dependencies: ["Reforge"], path: "Tests/ReforgeTests"),
    ],
    swiftLanguageModes: [.v5]
)
