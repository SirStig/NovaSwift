import SwiftUI

/// Shared state and control surface for the in-game **debug suite** — the
/// developer panel that opens over a live play session once "Debug mode" is on
/// (Settings ▸ Developer). It owns the live performance readout the scene feeds
/// it, and the handful of switches the suite's tools flip.
///
/// Kept deliberately small and additive: a new debug tool is a new field here
/// plus a row in `DebugSuiteView`. The suite is designed to grow as the port
/// does, so this is the seam every future tool hangs off of.
///
/// One `DebugController` lives for the whole play session (owned by
/// `GameContainerView`). Each time the `GameScene` is rebuilt — a hyperjump, a
/// spaceport departure — the container re-`attach`es the new scene, so the
/// controls always drive whatever world is currently on screen.
@MainActor
final class DebugController: ObservableObject {

    // MARK: Live performance metrics
    //
    // Written by the scene a few times a second (never per-frame — see
    // `report` — so SwiftUI isn't asked to re-lay-out at 60 Hz).

    /// Smoothed frames per second over the last sampling window.
    @Published var fps: Double = 0
    /// Average frame time this window, in milliseconds (the inverse of `fps`).
    @Published var frameMsAvg: Double = 0
    /// Worst single frame this window, in milliseconds — the number that
    /// actually shows up as a stutter, which a smoothed average hides.
    @Published var frameMsMax: Double = 0

    /// Live NPC ship count in the simulation (excludes the player).
    @Published var shipCount: Int = 0
    /// Travelling projectiles currently alive.
    @Published var projectileCount: Int = 0
    /// Live asteroids currently in the field.
    @Published var asteroidCount: Int = 0
    /// Total SpriteKit nodes in the scene graph — the render-side cost that
    /// grows with population, effects, and projectiles.
    @Published var nodeCount: Int = 0

    // MARK: Performance stress test

    /// Whether a stress test is currently flooding the live world with a
    /// combat fleet. Reset to `false` whenever a fresh scene is attached (a
    /// new world starts empty).
    @Published var perfTestActive = false

    /// How many combatants the next stress test spawns. The suite offers a set
    /// of presets; this is the chosen one.
    @Published var perfTestShipCount: Int = 60

    // MARK: AI debug overlay

    /// Draw each NPC's live AI state, combat target, navigation goal ("path"),
    /// and formation link over the flight scene. Read every frame by the scene;
    /// off by default. A pure visualization — it never changes the simulation.
    @Published var aiDebugEnabled = false

    /// The scene currently being measured / driven. Weak: the container owns
    /// the scene's lifetime through `GameHost`, and swaps it on every rebuild.
    weak var scene: GameScene?

    /// Point the controls at a freshly-built scene. Called by the container
    /// after each `GameHost` (re)build. A new scene means a new, empty world,
    /// so any prior stress test is implicitly over.
    func attach(_ scene: GameScene?) {
        self.scene = scene
        scene?.debug = self
        perfTestActive = false
    }

    /// Flood the live world with `perfTestShipCount` mutually-hostile
    /// combatants and let them fight — the worst-case render+sim load, so
    /// frame timing under real pressure is measurable.
    func startPerformanceTest() {
        scene?.startPerformanceTest(shipCount: perfTestShipCount)
        perfTestActive = true
    }

    /// Clear the stress-test fleet and hand the system back to its normal
    /// ambient traffic.
    func stopPerformanceTest() {
        scene?.stopPerformanceTest()
        perfTestActive = false
    }

    /// Push a fresh metrics sample up from the scene. Called on the main thread
    /// from the scene's throttled update tick.
    func report(fps: Double, frameMsAvg: Double, frameMsMax: Double,
                ships: Int, projectiles: Int, asteroids: Int, nodes: Int) {
        self.fps = fps
        self.frameMsAvg = frameMsAvg
        self.frameMsMax = frameMsMax
        self.shipCount = ships
        self.projectileCount = projectiles
        self.asteroidCount = asteroids
        self.nodeCount = nodes
    }
}
