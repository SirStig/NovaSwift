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
        // Cross-play: ENet client transport that joins Godot / dedicated servers by IP:port.
        .library(name: "NovaSwiftENet", targets: ["NovaSwiftENet"]),
        // Multiplayer bridge: maps the engine's World/ControlIntent to/from the
        // net wire types and drives per-system Layer-2 sync. Depends on both.
        .library(name: "NovaSwiftSync", targets: ["NovaSwiftSync"]),
        // Plug-in store: catalog metadata + download/install pipeline.
        .library(name: "NovaSwiftPluginStore", targets: ["NovaSwiftPluginStore"]),
        // HD / 3D graphics extensions: HD atlases, model baking (Apple only).
        .library(name: "NovaSwiftHD", targets: ["NovaSwiftHD"]),
        // Standalone dedicated server with a web admin panel: needs no game and no EV Nova data.
        .executable(name: "novaswift-server", targets: ["NovaSwiftServer"]),
        // Command-line extractor / inspector.
        .executable(name: "novaswift-extract", targets: ["novaswift-extract"]),
        // HD pack tool: build, bake, compare and benchmark graphics packs.
        .executable(name: "novaswift-hd", targets: ["novaswift-hd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "NovaSwiftKit",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/NovaSwiftKit",
            swiftSettings: optimizedInDebug
        ),
        .target(name: "NovaSwiftEngine", dependencies: ["NovaSwiftKit"], path: "Sources/NovaSwiftEngine",
                swiftSettings: optimizedInDebug),
        .target(name: "NovaSwiftStory", dependencies: ["NovaSwiftKit", "NovaSwiftEngine"], path: "Sources/NovaSwiftStory"),
        .target(name: "NovaSwiftNet", path: "Sources/NovaSwiftNet"),
        // Vendored ENet 1.3.18 (MIT). Kept out of NovaSwiftNet so the Game Center / Multipeer builds don't link it
        // unless something imports NovaSwiftENet (see docs/MULTIPLAYER.md, "Cross-play with the Apple app").
        .target(
            name: "CENet",
            path: "Sources/CENet",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAS_FCNTL", to: "1"), .define("HAS_POLL", to: "1"), .define("HAS_GETNAMEINFO", to: "1"),
                .define("HAS_GETADDRINFO", to: "1"), .define("HAS_INET_PTON", to: "1"), .define("HAS_INET_NTOP", to: "1"),
                .define("HAS_MSGHDR_FLAGS", to: "1"), .define("HAS_SOCKLEN_T", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "NovaSwiftENet",
            dependencies: ["NovaSwiftNet", "CENet", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/NovaSwiftENet"
        ),
        .target(
            name: "NovaSwiftSync",
            dependencies: ["NovaSwiftEngine", "NovaSwiftNet"],
            path: "Sources/NovaSwiftSync"
        ),
        .target(
            name: "NovaSwiftPluginStore",
            dependencies: [
                "NovaSwiftKit",
                // ZIPFoundation needs a system zlib and doesn't compile on Windows; ZipSupport_Windows.swift uses tar.exe there.
                .product(name: "ZIPFoundation", package: "ZIPFoundation",
                         condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/NovaSwiftPluginStore",
            resources: [
                .copy("Resources/PluginCatalog.json"),
            ]
        ),
        // Dedicated server: everything except `main` lives in the Core library so tests can drive it.
        .target(
            name: "NovaSwiftServerCore",
            dependencies: [
                "NovaSwiftNet", "NovaSwiftENet", "NovaSwiftKit", "NovaSwiftPluginStore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),   // RSA signature check for server updates
            ],
            path: "Sources/NovaSwiftServerCore",
            exclude: ["Web"]
        ),
        .executableTarget(
            name: "NovaSwiftServer",
            dependencies: ["NovaSwiftServerCore"],
            path: "Sources/NovaSwiftServer"
        ),
        .executableTarget(
            name: "novaswift-extract",
            dependencies: ["NovaSwiftKit", "NovaSwiftEngine", "NovaSwiftStory"],
            path: "Sources/novaswift-extract"
        ),
        .target(
            name: "NovaSwiftHD",
            dependencies: ["NovaSwiftKit", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/NovaSwiftHD",
            swiftSettings: optimizedInDebug
        ),
        .executableTarget(
            name: "novaswift-hd",
            dependencies: ["NovaSwiftKit", "NovaSwiftHD"],
            path: "Sources/novaswift-hd"
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
            name: "NovaSwiftENetTests",
            dependencies: ["NovaSwiftENet", "NovaSwiftNet", "CENet"],
            path: "Tests/NovaSwiftENetTests"
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
            name: "NovaSwiftServerTests",
            dependencies: ["NovaSwiftServerCore", "NovaSwiftENet", "NovaSwiftNet", "NovaSwiftKit", "CENet", .product(name: "_CryptoExtras", package: "swift-crypto")],
            path: "Tests/NovaSwiftServerTests"
        ),
        .testTarget(
            name: "NovaSwiftPluginStoreTests",
            dependencies: ["NovaSwiftPluginStore"],
            path: "Tests/NovaSwiftPluginStoreTests"
        ),
    ]
)

/// The data decoder, the simulation and the HD image work are hot loops that
/// run 10-50x slower unoptimised, which made Debug runs from Xcode load and
/// play nothing like the real thing. They're optimised in every build; the
/// app target stays debuggable. Release is unchanged.
var optimizedInDebug: [SwiftSetting] { [.unsafeFlags(["-O"], .when(configuration: .debug))] }
