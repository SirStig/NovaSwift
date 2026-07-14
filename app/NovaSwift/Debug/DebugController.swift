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

    /// CPU time spent in our own game-loop code per frame this window, in ms —
    /// the sum of every measured phase (sim + scene sync/render prep).
    @Published var cpuMsAvg: Double = 0
    /// The frame time *not* accounted for by our CPU phases — SpriteKit's own
    /// render/present pass plus anything unmeasured. `frameMsAvg - cpuMsAvg`,
    /// clamped at 0. A high render share with low CPU means the bottleneck is
    /// draw calls / fill rate, not the simulation.
    @Published var renderMsAvg: Double = 0
    /// Resident memory of the process, in MB — sampled on the report tick.
    @Published var memoryMB: Double = 0

    /// Per-phase frame-time breakdown for the last window, sorted most-expensive
    /// first. The heart of the "where is the frame going" readout — each entry is
    /// a subsystem's average and worst cost per frame. Empty until the first
    /// sample lands. See `FrameProfiler`.
    @Published var phaseBreakdown: [PerfPhase] = []

    /// The worst single-frame spike seen since the last report tick, in ms, or 0
    /// if none crossed the hitch threshold. Spikes are what read as stutter; the
    /// average hides them.
    @Published var lastSpikeMs: Double = 0
    /// That spike frame's own phase breakdown (worst-first) — which subsystem
    /// blew the frame budget on the bad frame specifically.
    @Published var lastSpikePhases: [PerfPhase] = []

    // MARK: Performance stress test

    /// Whether a stress test is currently flooding the live world with a
    /// combat fleet. Reset to `false` whenever a fresh scene is attached (a
    /// new world starts empty).
    @Published var perfTestActive = false

    /// How many combatants the next stress test spawns. The suite offers a set
    /// of presets; this is the chosen one.
    @Published var perfTestShipCount: Int = 60

    // MARK: Live cheats
    //
    // Continuous player-ship cheats the scene enforces every frame (see
    // `GameScene.applyDebugCheats`). Reset whenever a fresh scene attaches so a
    // new session never silently inherits god mode from the last one.

    /// God mode: the player ship takes no damage and its shields/armor stay
    /// pinned full. Drives `Ship.invulnerable` on the live player.
    @Published var godMode = false

    /// Infinite fuel: the player's fuel tank is held full, so afterburner and
    /// hyperjumps never deplete it.
    @Published var infiniteFuel = false

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
        // A new world starts clean — never carry cheats across a jump/departure
        // without the developer re-enabling them.
        godMode = false
        infiniteFuel = false
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
    /// from the scene's throttled update tick (never per-frame).
    func report(fps: Double, frameMsAvg: Double, frameMsMax: Double,
                cpuMsAvg: Double, renderMsAvg: Double, memoryMB: Double,
                ships: Int, projectiles: Int, asteroids: Int, nodes: Int,
                phases: [PerfPhase]) {
        self.fps = fps
        self.frameMsAvg = frameMsAvg
        self.frameMsMax = frameMsMax
        self.cpuMsAvg = cpuMsAvg
        self.renderMsAvg = renderMsAvg
        self.memoryMB = memoryMB
        self.shipCount = ships
        self.projectileCount = projectiles
        self.asteroidCount = asteroids
        self.nodeCount = nodes
        self.phaseBreakdown = phases
    }

    /// Surface the worst frame spike from the last window (or clear it when the
    /// window was clean). Kept separate from `report` so an ordinary window
    /// leaves the last spike's detail on screen to read, rather than blanking it.
    func reportSpike(frameMs: Double, phases: [PerfPhase]) {
        self.lastSpikeMs = frameMs
        self.lastSpikePhases = phases
    }
}
