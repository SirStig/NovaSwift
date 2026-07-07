// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EVNova",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        // The reusable core: containers, resource model, (later) type decoders + graphics.
        .library(name: "EVNovaKit", targets: ["EVNovaKit"]),
        // Command-line extractor / inspector over EVNovaKit.
        .executable(name: "evnova-extract", targets: ["evnova-extract"]),
    ],
    targets: [
        .target(
            name: "EVNovaKit",
            path: "Sources/EVNovaKit"
        ),
        .executableTarget(
            name: "evnova-extract",
            dependencies: ["EVNovaKit"],
            path: "Sources/evnova-extract"
        ),
        .testTarget(
            name: "EVNovaKitTests",
            dependencies: ["EVNovaKit"],
            path: "Tests/EVNovaKitTests"
        ),
    ]
)
