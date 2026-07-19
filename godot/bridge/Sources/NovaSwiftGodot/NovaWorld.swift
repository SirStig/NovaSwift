// NovaWorld — the Godot-visible façade over the NOVA Swift simulation.
//
// GDScript talks to exactly this class. It owns a `NovaSwiftEngine.World` and
// forwards a frame of Godot input into the engine's `ControlIntent`, ticks the
// sim with `step`, and hands entity state back out in packed arrays the scene
// can render cheaply. NO game logic lives here — anything past marshalling is a
// bug and belongs in the engine, where the Apple app inherits it too.
//
// Method names below are camelCase in Swift; every `@Callable` is declared
// `autoSnakeCase: true` so SwiftGodot exposes it to GDScript in snake_case
// (`makeDemoWorld` → `make_demo_world`), matching what godot/Main.gd calls.
// Confirmed on-toolchain: SwiftGodot's default (no `autoSnakeCase`) registers
// the literal camelCase Swift name instead — GDScript does not snake_case
// GDExtension methods for you, unlike its own built-in classes.
//
// Packed arrays construct from their Swift element arrays in one bulk copy —
// `PackedFloat32Array([Float])`, `PackedInt32Array([Int32])`,
// `PackedByteArray([UInt8])`, `PackedStringArray([String])` — confirmed
// on-toolchain too.
//
// See docs/GODOT_LAYER.md.

import Foundation
import SwiftGodot
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory

@Godot
class NovaWorld: Node2D {

    // MARK: Engine state

    private var world: World?
    private var galaxy: Galaxy?
    private var game: NovaGame?
    private var intent = ControlIntent()
    /// The system id `makeWorld` last built, so `launch()` can rebuild the same
    /// system after a docked visit — landing never changes system.
    private var currentSystemID: Int?
    /// The `spöb` id the player is currently docked at, or nil while flying.
    private var dockedSpobID: Int?
    /// The persistent pilot (credits, cargo, outfits, ship) — the same
    /// `PlayerState` schema the Apple app's `PilotStore` autosaves. Trade/
    /// outfit/shipyard transactions run through the portable `PilotEconomy`
    /// (Sources/NovaSwiftStory/PilotEconomy.swift) so this bridge doesn't
    /// reimplement pricing/mass-budget/trade-in rules. No disk save yet — see
    /// docs/GODOT_LAYER.md's pilot-save-load milestone item.
    private var pilot = PlayerState()
    private var pilotStarted = false

    // MARK: World setup

    /// Build a bare physics world with a synthetic player ship and a few drifting
    /// NPCs. Runs with **no EV Nova data**, so the slice is playable immediately
    /// and proves the whole bridge end-to-end.
    @Callable(autoSnakeCase: true)
    func makeDemoWorld() {
        let player = Ship(
            name: "Player",
            stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100),
            position: Vec2(0, 0)
        )
        let w = World(player: player)

        // A ring of drifting hulls so there's something to fly around. They have
        // no AI brain (no data-driven behaviour off real `düde` tables), so they
        // simply coast — enough to prove multi-entity readback + rendering.
        let count = 6
        for i in 0..<count {
            let angle = (Double(i) / Double(count)) * 2.0 * Double.pi
            let radius = 420.0
            let npc = Ship(
                name: "Drifter \(i + 1)",
                stats: ShipStats(speed: 220, acceleration: 160, turnRate: 70),
                position: Vec2(sin(angle) * radius, cos(angle) * radius),
                angle: angle
            )
            // Give each a gentle tangential drift so the scene isn't static.
            npc.velocity = Vec2(cos(angle) * 30.0, -sin(angle) * 30.0)
            _ = w.addNPC(npc)
        }

        self.world = w
        self.galaxy = nil
        self.game = nil
        self.intent = ControlIntent()
    }

    /// Discover + merge the player's own EV Nova data (BYO-data, same as the
    /// Apple app). Returns false if the directory holds no readable game data.
    @Callable(autoSnakeCase: true)
    func loadGame(baseDir: String) -> Bool {
        let base = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: baseDir))
        // `merge` never throws on an empty file list (it just yields an empty
        // collection), so a missing/empty directory has to be rejected explicitly
        // here rather than relying on `try?` to catch it.
        guard !base.isEmpty, let collection = try? GameLibrary.merge(baseFiles: base) else { return false }
        let g = NovaGame(collection)
        self.game = g
        self.galaxy = Galaxy(game: g)
        return true
    }

    /// After `loadGame`, populate a real system with NPCs from its `düde`/`flët`
    /// spawn table via `GameSession.makeWorld`. Pass a negative id to use the
    /// data's starting system. Returns false if no game is loaded.
    @Callable(autoSnakeCase: true)
    func makeWorld(systemID: Int) -> Bool {
        guard let game = self.game else { return false }
        let galaxy = self.galaxy ?? Galaxy(game: game)
        self.galaxy = galaxy

        // Bootstrap the pilot from the scenario's `chär` exactly once — the
        // same authoritative bootstrap `PilotStore.newGame` uses on the Apple
        // side (random start system among candidates, starting hull/credits/
        // calendar/standings/OnStart script). A later `makeWorld` call (e.g.
        // traveling to a new system) reuses the live pilot instead of rerolling.
        if !pilotStarted {
            pilot = PilotFactory.makeDefault(name: "Captain", isMale: true, game: game)
            pilotStarted = true
        }

        let sysID = systemID >= 0 ? systemID : pilot.currentSystem
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2())
            ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo

        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        self.world = w
        self.intent = ControlIntent()
        self.currentSystemID = sysID
        self.dockedSpobID = nil
        pilot.currentSystem = sysID
        return true
    }

    // MARK: Input

    /// Map one frame of Godot input onto the engine's `ControlIntent`. Applied to
    /// the world at the next `step`.
    @Callable(autoSnakeCase: true)
    func setIntent(turnLeft: Bool, turnRight: Bool, thrust: Bool, reverse: Bool,
                   afterburner: Bool, firePrimary: Bool, fireSecondary: Bool) {
        var i = ControlIntent()
        i.turnLeft = turnLeft
        i.turnRight = turnRight
        i.thrust = thrust
        i.reverse = reverse
        i.afterburner = afterburner
        i.firePrimary = firePrimary
        i.fireSecondary = fireSecondary
        self.intent = i
    }

    // MARK: Tick

    /// Advance the simulation by `dt` seconds — the same `World.step` the Apple
    /// app and the headless `novaswift-extract ai` harness drive.
    @Callable(autoSnakeCase: true)
    func step(dt: Double) {
        guard let world = self.world else { return }
        world.intent = self.intent
        world.step(dt)
    }

    // MARK: Player readback

    @Callable(autoSnakeCase: true) func playerPosition() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        return Vector2(x: Float(p.position.x), y: Float(p.position.y))
    }

    @Callable(autoSnakeCase: true) func playerVelocity() -> Vector2 {
        guard let p = world?.player else { return Vector2(x: 0, y: 0) }
        return Vector2(x: Float(p.velocity.x), y: Float(p.velocity.y))
    }

    /// Engine heading in radians (0 = up / north, increasing clockwise).
    @Callable(autoSnakeCase: true) func playerAngle() -> Double {
        world?.player.angle ?? 0
    }

    @Callable(autoSnakeCase: true) func playerShieldFraction() -> Double {
        guard let p = world?.player, p.maxShield > 0 else { return 0 }
        return max(0, min(1, p.shield / p.maxShield))
    }

    @Callable(autoSnakeCase: true) func playerArmorFraction() -> Double {
        guard let p = world?.player, p.maxArmor > 0 else { return 0 }
        return max(0, min(1, p.armor / p.maxArmor))
    }

    @Callable(autoSnakeCase: true) func playerIsAlive() -> Bool {
        world?.player.isAlive ?? false
    }

    // MARK: All-ship readback

    /// Number of live ships this frame (player + living NPCs).
    @Callable(autoSnakeCase: true) func shipCount() -> Int {
        guard let world = self.world else { return 0 }
        return 1 + world.npcs.filter { $0.isAlive }.count
    }

    /// Every live ship packed as `[x, y, angle, kind]` per ship, player first.
    /// `kind`: 0 = player, 1 = NPC, 2 = disabled NPC hulk. One flat array keeps
    /// the per-frame crossing cheap — GDScript strides it by 4.
    @Callable(autoSnakeCase: true) func shipTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []

        func push(_ x: Double, _ y: Double, _ a: Double, _ kind: Float) {
            flat.append(Float(x)); flat.append(Float(y)); flat.append(Float(a)); flat.append(kind)
        }

        let p = world.player
        push(p.position.x, p.position.y, p.angle, 0)
        for npc in world.npcs where npc.isAlive {
            push(npc.position.x, npc.position.y, npc.angle, npc.disabled ? 2 : 1)
        }
        return PackedFloat32Array(flat)
    }

    /// Entity id per live ship, SAME order as `shipTransforms()` (player first,
    /// `Ship.entityID`). Lets the frontend map a radar blip or click back to a
    /// concrete ship for `selectTarget`.
    // autoSnakeCase mis-splits the "IDs" acronym as "i_ds" (see bodySpobIDs below).
    @Callable(explicitName: "ship_ids") func shipIDs() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [Int32(world.player.entityID)]
        for npc in world.npcs where npc.isAlive { flat.append(Int32(npc.entityID)) }
        return PackedInt32Array(flat)
    }

    /// Per live ship, SAME order as `shipTransforms()`: a radar/IFF category —
    /// 0 hostile (red), 1 neutral (blue), 2 friendly/escort (green), 3 disabled
    /// hulk (grey), 4 self (the player entry — the frontend already colors this
    /// distinctly and shouldn't need to special-case index 0). Delegates to the
    /// engine's own `Diplomacy`/brain hostility rules rather than re-deriving
    /// them client-side.
    @Callable(autoSnakeCase: true) func shipRelationships() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [4]
        for npc in world.npcs where npc.isAlive {
            flat.append(relationship(of: npc, in: world))
        }
        return PackedInt32Array(flat)
    }

    private func relationship(of npc: Ship, in world: World) -> Int32 {
        if npc.disabled { return 3 }
        if world.isPlayerEscort(npc) { return 2 }
        if world.isEffectivelyHostileToPlayer(npc) { return 0 }
        return 1
    }

    // MARK: Targeting

    /// Lock the nearest eligible ship in `World.targetLockRange` (excludes the
    /// player's own fleet). `hostileOnly` narrows to ships that would actually
    /// fight the player — the "nearest enemy" hotkey. Returns the locked ship's
    /// entity id, or -1 if nothing was in range.
    @Callable(autoSnakeCase: true) func selectNearestTarget(hostileOnly: Bool) -> Int {
        world?.selectNearestTarget(hostileOnly: hostileOnly)?.entityID ?? -1
    }

    /// Lock a specific ship by id (click-to-select). Unlike
    /// `selectNearestTarget`, allows disabled hulks and has no range gate.
    @Callable(autoSnakeCase: true) func selectTarget(id: Int) -> Bool {
        world?.selectTarget(id: id) != nil
    }

    /// Drop the player's current target lock, if any.
    @Callable(autoSnakeCase: true) func clearPlayerTarget() {
        world?.clearPlayerTarget()
    }

    /// The player's locked target's entity id, or -1 if none/no longer alive.
    @Callable(autoSnakeCase: true) func playerTargetID() -> Int {
        guard let world = self.world, let tid = world.player.currentTargetID,
              let t = world.ship(id: tid), t.isAlive else { return -1 }
        return tid
    }

    private var lockedTarget: Ship? {
        guard let world = self.world, let tid = world.player.currentTargetID,
              let t = world.ship(id: tid), t.isAlive else { return nil }
        return t
    }

    @Callable(autoSnakeCase: true) func targetName() -> String { lockedTarget?.name ?? "" }

    @Callable(autoSnakeCase: true) func targetShieldFraction() -> Double {
        guard let t = lockedTarget, t.maxShield > 0 else { return 0 }
        return max(0, min(1, t.shield / t.maxShield))
    }

    @Callable(autoSnakeCase: true) func targetArmorFraction() -> Double {
        guard let t = lockedTarget, t.maxArmor > 0 else { return 0 }
        return max(0, min(1, t.armor / t.maxArmor))
    }

    @Callable(autoSnakeCase: true) func targetIsHostile() -> Bool {
        guard let world = self.world, let t = lockedTarget else { return false }
        return world.isEffectivelyHostileToPlayer(t)
    }

    /// Distance from the player to the locked target, in px — 0 if no target.
    @Callable(autoSnakeCase: true) func targetDistance() -> Double {
        guard let world = self.world, let t = lockedTarget else { return 0 }
        return (t.position - world.player.position).length
    }

    // MARK: Weapons

    /// The EV Nova flight HUD's weapon readout tracks the selected *secondary*
    /// (guns/primaries are "always available" and never occupy it) — a
    /// guns-only ship correctly reports `hasSecondaryWeapon() == false`.
    @Callable(autoSnakeCase: true) func hasSecondaryWeapon() -> Bool {
        !(world?.player.secondaryWeaponIDs.isEmpty ?? true)
    }

    @Callable(autoSnakeCase: true) func secondaryWeaponName() -> String {
        world?.player.effectiveSecondaryMount?.spec.name ?? ""
    }

    /// Remaining ammo for the effective secondary; -1 = unlimited, 0 if none fitted.
    @Callable(autoSnakeCase: true) func secondaryWeaponAmmo() -> Int {
        world?.player.effectiveSecondaryMount?.ammo ?? 0
    }

    /// 0 = ready to fire, 1 = just fired (full reload wait).
    @Callable(autoSnakeCase: true) func secondaryWeaponCooldownFraction() -> Double {
        guard let mount = world?.player.effectiveSecondaryMount, mount.spec.reloadSeconds > 0 else { return 0 }
        return max(0, min(1, mount.cooldown / mount.spec.reloadSeconds))
    }

    /// Step the selected secondary to the next/previous fitted secondary.
    /// Returns the new weapon's display name, or "" with no secondaries fitted.
    @Callable(autoSnakeCase: true) func cycleSecondaryWeapon(forward: Bool) -> String {
        guard let player = world?.player, !player.secondaryWeaponIDs.isEmpty else { return "" }
        player.cycleSecondary(forward: forward)
        return player.effectiveSecondaryMount?.spec.name ?? ""
    }

    // MARK: Sensors

    /// `baseRange` (frontend's own radar-circle radius, e.g. 4500) shrunk by the
    /// system's interference/jamming outfits for the player — mirrors the
    /// Apple app's `World.effectiveSensorRange(_:for:)` call.
    @Callable(autoSnakeCase: true) func effectiveSensorRange(baseRange: Double) -> Double {
        guard let world = self.world else { return baseRange }
        return world.effectiveSensorRange(baseRange, for: world.player)
    }

    // MARK: Fuel

    @Callable(autoSnakeCase: true) func playerFuelFraction() -> Double {
        guard let p = world?.player, p.maxFuel > 0 else { return 0 }
        return max(0, min(1, p.fuel / p.maxFuel))
    }

    /// Whole hyperjumps left on the current fuel (`ShipFuel.perJump` each).
    @Callable(autoSnakeCase: true) func playerJumpsRemaining() -> Int {
        guard let p = world?.player else { return 0 }
        return Int((p.fuel / ShipFuel.perJump).rounded(.down))
    }

    // MARK: Landing

    /// The nearest body the player could conceivably land on right now, in
    /// reach regardless of speed — mirrors `GameScene.updateLanding`'s
    /// distance/reach test (`body.radius + 70`, not `+55`: matches where
    /// takeoff/dock-load placement actually sets the ship down). Only
    /// `isLandable` bodies count, not hypergates/wormholes — gate travel is a
    /// separate flow (see docs/GODOT_LAYER.md's hypergate section).
    private func nearestReachableLandTarget() -> (id: Int, name: String)? {
        guard let world = self.world else { return nil }
        var bestID: Int?
        var bestDist = Double.greatestFiniteMagnitude
        var bestReach = 0.0
        for body in world.systemContext.bodies where body.isLandable {
            let d = (body.position - world.player.position).length
            if d < bestDist { bestDist = d; bestID = body.id; bestReach = body.radius + 70 }
        }
        guard let id = bestID, bestDist <= bestReach else { return nil }
        return (id, game?.spob(id)?.name ?? "")
    }

    /// True once the player is close enough AND slow enough to land — mirrors
    /// `GameScene.canLandNow`'s 130 u/s speed limit (`landingSpeedLimit`).
    @Callable(autoSnakeCase: true) func canLandNow() -> Bool {
        guard let world = self.world, nearestReachableLandTarget() != nil else { return false }
        return world.player.velocity.length <= 130
    }

    /// The `spöb` id of the nearest body in reach, or -1 if nothing's close
    /// enough — set even when too fast to land yet, so the frontend can show
    /// "slow down to land on X" like the Apple app does.
    @Callable(autoSnakeCase: true) func nearestLandableSpobID() -> Int {
        nearestReachableLandTarget()?.id ?? -1
    }

    /// Display name of the nearest body in reach, or "" if none.
    @Callable(autoSnakeCase: true) func nearestLandableName() -> String {
        nearestReachableLandTarget()?.name ?? ""
    }

    /// True while docked at a spöb (spaceport screens should be showing).
    @Callable(autoSnakeCase: true) func isLanded() -> Bool { dockedSpobID != nil }

    /// The `spöb` id the player is docked at, or -1 while flying.
    @Callable(autoSnakeCase: true) func landedSpobID() -> Int { dockedSpobID ?? -1 }

    /// Attempt to land on the nearest body in reach. Fails (returns false) if
    /// out of reach or moving too fast, exactly like pressing the Land key does
    /// in the Apple app. On success the frontend should stop calling `step()`
    /// and show spaceport screens until `launch()`.
    @Callable(autoSnakeCase: true) func attemptLand() -> Bool {
        guard canLandNow(), let target = nearestReachableLandTarget() else { return false }
        dockedSpobID = target.id
        return true
    }

    /// Take off from the current dock: rebuilds the system (fresh NPC spawn,
    /// same as any `makeWorld`) and places the player just clear of the body's
    /// surface, nose pointed away from the system centre, at rest — EV Nova
    /// gives no outbound momentum on takeoff (mirrors
    /// `GameScene.reloadForDeparture`). No-op (returns false) if not landed.
    @Callable(autoSnakeCase: true) func launch() -> Bool {
        guard let spobID = dockedSpobID, let game = self.game, let galaxy = self.galaxy,
              let sysID = currentSystemID else { return false }
        // Rebuild from the pilot's current loadout, not the old flight `Ship` —
        // trade/outfit/shipyard transactions while docked only mutate `pilot`
        // (see the trade section below), matching the Apple app's
        // `buildPlayerShip` (a fresh loaded ship each landing/launch, cargo
        // carried in from `pilot.cargo`).
        let player = galaxy.makeLoadedShip(pilot.shipType, extraOutfits: pilot.outfits, at: Vec2())
            ?? world?.player ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
        player.cargo = pilot.cargo
        let (w, _) = GameSession.makeWorld(game: game, systemID: sysID, player: player, galaxy: galaxy)
        let ctx = w.systemContext
        if let body = ctx.bodies.first(where: { $0.id == spobID }) {
            var outward = body.position - ctx.center
            if outward.length < 1 { outward = Vec2(0, -1) }
            let dir = outward.normalized
            player.position = body.position + dir * (body.radius + 60)
            player.angle = dir.angle
            player.velocity = Vec2()
        }
        player.currentTargetID = nil
        self.world = w
        dockedSpobID = nil
        return true
    }

    // MARK: Trade (Commodity Exchange)
    //
    // All pricing/mass/affordability math is `PilotEconomy`'s (see that type's
    // doc comment) — this section only resolves the docked `spöb` and marshals
    // its commodity rows. Only the standard 6 `Commodity` goods are exposed
    // here, matching the Apple app's `TradeCenterView`; `jünk` (contraband)
    // trading is a separate, not-yet-bridged screen.

    private var dockedSpob: SpobRes? {
        guard let id = dockedSpobID else { return nil }
        return game?.spob(id)
    }

    /// The docked spöb's tradable commodities, in `Commodity` raw-value order
    /// (food/industrial/medical/luxury/metal/equipment) — empty if not docked
    /// or the port has no commodity exchange.
    private func market() -> [(commodity: Commodity, level: PriceLevel, price: Int)] {
        guard let game = self.game, let spob = dockedSpob else { return [] }
        return game.commodityMarket(at: spob)
    }

    @Callable(autoSnakeCase: true) func playerCredits() -> Int { pilot.credits }
    @Callable(autoSnakeCase: true) func cargoFreeTons() -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        return PilotEconomy.cargoFree(pilot, galaxy: galaxy)
    }
    @Callable(autoSnakeCase: true) func cargoCapacityTons() -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        return PilotEconomy.cargoCapacity(pilot, galaxy: galaxy)
    }

    /// Number of tradable commodity rows at the docked spöb (0 if not docked
    /// or no exchange). The frontend indexes the other `commodity*`/`buy`/`sell`
    /// calls by row 0..<this.
    @Callable(autoSnakeCase: true) func commodityCount() -> Int { market().count }

    @Callable(autoSnakeCase: true) func commodityName(index: Int) -> String {
        let m = market()
        guard index >= 0, index < m.count else { return "" }
        return game?.commodityName(m[index].commodity) ?? m[index].commodity.fallbackName
    }

    @Callable(autoSnakeCase: true) func commodityPrice(index: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return m[index].price
    }

    /// Tons of this commodity currently in the pilot's hold (persists across
    /// landings — the same figure the flight HUD's cargo readout carries once
    /// `launch()` seeds the ship from it).
    @Callable(autoSnakeCase: true) func commodityHeld(index: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.held(pilot, cargo: m[index].commodity.cargoID)
    }

    /// Buy up to `tons` of commodity row `index` at its current price, capped by
    /// affordability and free cargo space. Returns the tonnage actually bought.
    @discardableResult
    @Callable(autoSnakeCase: true) func buyCommodity(index: Int, tons: Int) -> Int {
        guard let galaxy = self.galaxy else { return 0 }
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        let free = PilotEconomy.cargoFree(pilot, galaxy: galaxy)
        return PilotEconomy.buyCommodity(&pilot, m[index].commodity, tons: tons, unitPrice: m[index].price, cargoFree: free)
    }

    /// Sell up to `tons` of commodity row `index` at its current price. Returns
    /// the tonnage actually sold.
    @discardableResult
    @Callable(autoSnakeCase: true) func sellCommodity(index: Int, tons: Int) -> Int {
        let m = market()
        guard index >= 0, index < m.count else { return 0 }
        return PilotEconomy.sellCommodity(&pilot, m[index].commodity, tons: tons, unitPrice: m[index].price)
    }

    /// One string per `WorldEvent` produced this step (the case name, e.g.
    /// `weaponFired`, `shipDestroyed`), for sound/FX hooks. Uses the case-name
    /// prefix of the reflected value so new engine event kinds surface without a
    /// bridge change.
    @Callable(autoSnakeCase: true) func drainEvents() -> PackedStringArray {
        guard let world = self.world else { return PackedStringArray() }
        let names = world.events.map { String(String(describing: $0).prefix { $0 != "(" }) }
        return PackedStringArray(names)
    }

    // MARK: Real-data render queries
    //
    // All nil-safe: they return empty/sentinel values in the data-free demo world,
    // so the frontend can call them unconditionally and fall back to primitives.

    /// True once real EV Nova data is loaded (vs the data-free demo world).
    @Callable(autoSnakeCase: true) func hasGame() -> Bool { game != nil }

    /// The player hull's `shïp` id, or -1 (demo ship has no sprite).
    @Callable(autoSnakeCase: true) func playerShipType() -> Int { world?.player.shipTypeID ?? -1 }

    /// A hull's display name, or "" if unknown / no data.
    @Callable(autoSnakeCase: true) func shipTypeName(shipType: Int) -> String {
        game?.ship(shipType)?.name ?? ""
    }

    /// Per live ship: `[shipType, spriteFrame]`, player first — SAME order and
    /// count as `shipTransforms()`, so the frontend zips the two. `shipType` is
    /// -1 for the synthetic demo ship (draw a primitive instead of a sprite).
    @Callable(autoSnakeCase: true) func shipSpriteFrames() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        var flat: [Int32] = [Int32(world.player.shipTypeID), Int32(world.player.spriteFrame)]
        for npc in world.npcs where npc.isAlive {
            flat.append(Int32(npc.shipTypeID)); flat.append(Int32(npc.spriteFrame))
        }
        return PackedInt32Array(flat)
    }

    // MARK: System geometry (stellar bodies)

    /// The system's hyperspace-jump radius (0 in the demo world).
    @Callable(autoSnakeCase: true) func jumpRadius() -> Double { world?.systemContext.jumpRadius ?? 0 }

    /// Per stellar body: `[x, y, radius, kind]`. `kind`: 0 landable planet,
    /// 1 non-landable planet, 2 hypergate, 3 wormhole, 4 deadly.
    @Callable(autoSnakeCase: true) func bodyTransforms() -> PackedFloat32Array {
        guard let world = self.world else { return PackedFloat32Array() }
        var flat: [Float] = []
        for b in world.systemContext.bodies {
            flat.append(Float(b.position.x))
            flat.append(Float(b.position.y))
            flat.append(Float(b.radius))
            var kind: Float = 1
            if b.isDeadly { kind = 4 }
            else if b.isWormhole { kind = 3 }
            else if b.isHypergate { kind = 2 }
            else if b.isLandable { kind = 0 }
            flat.append(kind)
        }
        return PackedFloat32Array(flat)
    }

    /// Per stellar body: its `spöb` id (for sprite lookup), SAME order as
    /// `bodyTransforms()`.
    // autoSnakeCase mis-splits the "IDs" acronym as "i_ds"; pin the name explicitly.
    @Callable(explicitName: "body_spob_ids") func bodySpobIDs() -> PackedInt32Array {
        guard let world = self.world else { return PackedInt32Array() }
        return PackedInt32Array(world.systemContext.bodies.map { Int32($0.id) })
    }

    // MARK: Sprite export (raw RGBA the frontend uploads as a Godot Image)
    //
    // The decoders (RLED/PICT) produce a plain RGBA8 buffer with no Apple
    // dependency, so this path is fully cross-platform. GDScript turns the bytes
    // into an Image (FORMAT_RGBA8) once per hull/planet and caches the texture.

    /// `[frameWidth, frameHeight, frameCount, columns, rows, surfaceWidth,
    /// surfaceHeight]` for a hull's rotation sheet, or empty if it has no sprite.
    @Callable(autoSnakeCase: true) func shipSpriteInfo(shipType: Int) -> PackedInt32Array {
        spriteInfo(game?.shipSprite(shipType))
    }

    /// The RGBA8 surface bytes (`surfaceWidth*surfaceHeight*4`) for a hull's sheet.
    @Callable(autoSnakeCase: true) func shipSpriteRGBA(shipType: Int) -> PackedByteArray {
        spriteRGBA(game?.shipSprite(shipType))
    }

    /// Same as `shipSpriteInfo`, for a planet/station's `spöb` sprite.
    @Callable(autoSnakeCase: true) func spobSpriteInfo(spobID: Int) -> PackedInt32Array {
        spriteInfo(game?.spobSprite(spobID))
    }

    /// Same as `shipSpriteRGBA`, for a planet/station's `spöb` sprite.
    @Callable(autoSnakeCase: true) func spobSpriteRGBA(spobID: Int) -> PackedByteArray {
        spriteRGBA(game?.spobSprite(spobID))
    }

    // MARK: Sprite marshalling helpers

    private func spriteInfo(_ sheet: SpriteSheet?) -> PackedInt32Array {
        guard let s = sheet else { return PackedInt32Array() }
        return PackedInt32Array([
            s.frameWidth, s.frameHeight, s.frameCount,
            s.columns, s.rows, s.surfaceWidth, s.surfaceHeight,
        ].map { Int32($0) })
    }

    private func spriteRGBA(_ sheet: SpriteSheet?) -> PackedByteArray {
        guard let s = sheet else { return PackedByteArray() }
        // Convenience init from `[UInt8]` — one bulk copy, no per-byte Variant
        // crossing (the surface can be megabytes). Cached texture-side by GDScript.
        return PackedByteArray(s.rgba)
    }
}
