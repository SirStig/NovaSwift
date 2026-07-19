// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NovaSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        // Data layer: containers, resource model, typed decoders, graphics.
        .library(name: "NovaSwiftKit", targets: ["NovaSwiftKit"]),
        // Simulation core: flight physics, input intents, world state.
        .library(name: "NovaSwiftEngine", targets: ["NovaSwiftEngine"]),
        // Story/mission runtime: control bits, missions, crons, player state.
        .library(name: "NovaSwiftStory", targets: ["NovaSwiftStory"]),
        // Multiplayer netcode: transport abstraction, presence, session sync.
        .library(name: "NovaSwiftNet", targets: ["NovaSwiftNet"]),
        // Multiplayer bridge: maps the engine's World/ControlIntent to/from the
        // net wire types and drives per-system Layer-2 sync. Depends on both.
        .library(name: "NovaSwiftSync", targets: ["NovaSwiftSync"]),
        // Plug-in store: catalog metadata + download/install pipeline.
        .library(name: "NovaSwiftPluginStore", targets: ["NovaSwiftPluginStore"]),
        // Command-line extractor / inspector.
        .executable(name: "novaswift-extract", targets: ["novaswift-extract"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "NovaSwiftKit", path: "Sources/NovaSwiftKit"),
        .target(name: "NovaSwiftEngine", dependencies: ["NovaSwiftKit"], path: "Sources/NovaSwiftEngine"),
        .target(name: "NovaSwiftStory", dependencies: ["NovaSwiftKit", "NovaSwiftEngine"], path: "Sources/NovaSwiftStory"),
        .target(name: "NovaSwiftNet", path: "Sources/NovaSwiftNet"),
        .target(
            name: "NovaSwiftSync",
            dependencies: ["NovaSwiftEngine", "NovaSwiftNet"],
            path: "Sources/NovaSwiftSync"
        ),
        .target(
            name: "NovaSwiftPluginStore",
            dependencies: [
                "NovaSwiftKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/NovaSwiftPluginStore",
            resources: [
                .copy("Resources/PluginCatalog.json"),
                .copy("Resources/Screenshots"),
            ]
        ),
        .executableTarget(
            name: "novaswift-extract",
            dependencies: ["NovaSwiftKit", "NovaSwiftEngine", "NovaSwiftStory"],
            path: "Sources/novaswift-extract"
        ),
        .testTarget(
            name: "NovaSwiftKitTests",
            dependencies: ["NovaSwiftKit"],
            path: "Tests/NovaSwiftKitTests"
        ),
        .testTarget(
            name: "NovaSwiftEngineTests",
            dependencies: ["NovaSwiftEngine"],
            path: "Tests/NovaSwiftEngineTests"
        ),
        .testTarget(
            name: "NovaSwiftStoryTests",
            dependencies: ["NovaSwiftStory"],
            path: "Tests/NovaSwiftStoryTests"
        ),
        .testTarget(
            name: "NovaSwiftNetTests",
            dependencies: ["NovaSwiftNet"],
            path: "Tests/NovaSwiftNetTests"
        ),
        .testTarget(
            name: "NovaSwiftSyncTests",
            dependencies: ["NovaSwiftSync"],
            path: "Tests/NovaSwiftSyncTests"
        ),
        .testTarget(
            name: "NovaSwiftPluginStoreTests",
            dependencies: ["NovaSwiftPluginStore"],
            path: "Tests/NovaSwiftPluginStoreTests"
        ),
    ]
)
