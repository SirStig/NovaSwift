// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EVNova",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Data layer: containers, resource model, typed decoders, graphics.
        .library(name: "EVNovaKit", targets: ["EVNovaKit"]),
        // Simulation core: flight physics, input intents, world state.
        .library(name: "EVNovaEngine", targets: ["EVNovaEngine"]),
        // Story/mission runtime: control bits, missions, crons, player state.
        .library(name: "EVNovaStory", targets: ["EVNovaStory"]),
        // Plug-in store: catalog metadata + download/install pipeline.
        .library(name: "EVNovaPluginStore", targets: ["EVNovaPluginStore"]),
        // Command-line extractor / inspector.
        .executable(name: "evnova-extract", targets: ["evnova-extract"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "EVNovaKit", path: "Sources/EVNovaKit"),
        .target(name: "EVNovaEngine", dependencies: ["EVNovaKit"], path: "Sources/EVNovaEngine"),
        .target(name: "EVNovaStory", dependencies: ["EVNovaKit"], path: "Sources/EVNovaStory"),
        .target(
            name: "EVNovaPluginStore",
            dependencies: [
                "EVNovaKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/EVNovaPluginStore",
            resources: [
                .copy("Resources/PluginCatalog.json"),
                .copy("Resources/Screenshots"),
            ]
        ),
        .executableTarget(
            name: "evnova-extract",
            dependencies: ["EVNovaKit", "EVNovaEngine", "EVNovaStory"],
            path: "Sources/evnova-extract"
        ),
        .testTarget(
            name: "EVNovaKitTests",
            dependencies: ["EVNovaKit"],
            path: "Tests/EVNovaKitTests"
        ),
        .testTarget(
            name: "EVNovaEngineTests",
            dependencies: ["EVNovaEngine"],
            path: "Tests/EVNovaEngineTests"
        ),
        .testTarget(
            name: "EVNovaStoryTests",
            dependencies: ["EVNovaStory"],
            path: "Tests/EVNovaStoryTests"
        ),
        .testTarget(
            name: "EVNovaPluginStoreTests",
            dependencies: ["EVNovaPluginStore"],
            path: "Tests/EVNovaPluginStoreTests"
        ),
    ]
)
