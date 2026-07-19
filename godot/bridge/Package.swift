// swift-tools-version:5.9
import PackageDescription

// The NOVA Swift ↔ Godot bridge.
//
// This is a SEPARATE Swift package from the repo-root `Package.swift` on
// purpose: it depends on the root package by path and adds the heavy SwiftGodot
// dependency here, so the Apple app's `swift build` / `swift test` and its CI
// never resolve or compile SwiftGodot. The Godot desktop frontend is a consumer
// of the Swift core, not part of it.
//
// It builds `NovaSwiftGodot` as a DYNAMIC library — the native GDExtension that
// Godot loads at runtime (`.so` on Linux, `.dll` on Windows, `.dylib` on macOS).
// See docs/GODOT_LAYER.md.
let package = Package(
    name: "NovaSwiftGodot",
    platforms: [
        // Must be >= SwiftGodot's own minimum (macOS 14) even though the
        // root NovaSwift package (and the Apple SpriteKit app) target 13.
        .macOS(.v14),
    ],
    products: [
        .library(name: "NovaSwiftGodot", type: .dynamic, targets: ["NovaSwiftGodot"]),
    ],
    dependencies: [
        // The reusable Swift core (engine + data layer + story), by path.
        // NB: SwiftPM resolves a local path dependency's identity from its
        // manifest `name:` (here "NovaSwift"), not the checkout directory
        // name — but only if `name:` is passed explicitly here too.
        .package(name: "NovaSwift", path: "../.."),
        // SwiftGodot — the maintained Swift binding for Godot 4 GDExtensions.
        // Pinned to a branch because SwiftGodot tracks Godot releases on `main`;
        // pin to a tagged version once the frontend stabilises.
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", branch: "main"),
    ],
    targets: [
        .target(
            name: "NovaSwiftGodot",
            dependencies: [
                .product(name: "NovaSwiftEngine", package: "NovaSwift"),
                .product(name: "NovaSwiftKit", package: "NovaSwift"),
                .product(name: "NovaSwiftStory", package: "NovaSwift"),
                .product(name: "SwiftGodot", package: "SwiftGodot"),
            ],
            path: "Sources/NovaSwiftGodot"
        ),
    ]
)
