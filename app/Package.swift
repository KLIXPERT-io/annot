// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ANNOT",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ANNOT",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ANNOT",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ScreenCaptureKit"), .linkedLibrary("sqlite3")]
        ),
    ]
)
