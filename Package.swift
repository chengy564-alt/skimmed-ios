// swift-tools-version: 5.9
//
// SPM manifest exists ONLY so `swift test` can run real unit tests against
// ImportCore. The app target compiles the same `Skimmed v3/ImportCore/`
// sources directly via the filesystem-synced group — no pbxproj changes, no
// `import ImportCore` inside those sources.

import PackageDescription

let package = Package(
    name: "ImportCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ImportCore", targets: ["ImportCore"]),
    ],
    targets: [
        .target(
            name: "ImportCore",
            path: "Skimmed v3/ImportCore"
        ),
        .testTarget(
            name: "ImportCoreTests",
            dependencies: ["ImportCore"],
            path: "Tests/ImportCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
