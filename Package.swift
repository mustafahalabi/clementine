// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates. A binary XCFramework: SwiftPM copies Sparkle.framework next to the debug/release binary
        // (found via @loader_path), and scripts/bundle.sh embeds it in Contents/Frameworks for the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clementine",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Clementine",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Inside Clementine.app the framework lives in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
