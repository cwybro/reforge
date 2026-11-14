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
        // Opt-in end-to-end smoke tests: launch the bundled Reforge.app in stub mode and drive it
        // through the Accessibility API. Skipped unless REFORGE_E2E=1; run them with `make e2e`.
        .testTarget(name: "ReforgeE2ETests", path: "Tests/ReforgeE2ETests"),
    ],
    swiftLanguageModes: [.v5]
)
