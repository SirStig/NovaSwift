// Plain-Swift state for the bridge's "Flight visuals" section (`// MARK: Flight visuals`
// in NovaWorld.swift); same split as Flight.swift / Gaps.swift -- `@Godot` registers only what
// is declared in the class body, so the callables live in NovaWorld and this is the data they
// share.
//
// No renderer here and no invented numbers: every frame pick, blink phase, flare decay, glow
// flicker, fog level and stellar frame step is the Apple Classic path's own rule, taken from
// `HullAnimConfig` / `ShieldFlare` (Sources/NovaSwiftEngine/HullAnimator.swift, the SpriteKit-free
// port of `HullAnimation.swift`), `StellarAnimator`, `MurkFog` and `OriginalRendering`. This type
// only advances the per-ship clocks once per display frame (as `GameScene.syncNPCs` does with
// `frameDT`) and packs the result for GDScript.

import Foundation
import NovaSwiftEngine
import NovaSwiftKit

final class FlightVisuals {
    /// Floats per ship in `shipLayers()`. Column meanings are documented there.
    static let layerStride = 26

    // Options pushed by the frontend (Classic preferences / accessibility).
    var shipAnimations = true
    var reduceFlashing = false

    private var layers: [Int: ShipLayerState] = [:]
    private var rows: [Int: [Float]] = [:]
    private var configs: [Int: HullAnimConfig] = [:]
    private var persColors: [Int: Int?] = [:]
    private var usesShipSprite: [Int: Bool] = [:]
    private var animators: [Int: StellarAnimator] = [:]
    private var animatorSystem: Int = Int.min
    /// Per body (same order as `bodyTransforms`): [frame, destroyed, fog].
    private(set) var stellarRows: [Float] = []
    private var lastFlickerSeed = 0
    /// Last drawn type / heading frame / position per ship, so a landing ship (already removed from the world
    /// when its event arrives) can still be drawn shrinking into the stellar.
    private var lastInfo: [Int: (type: Int, frame: Int, pos: Vec2)] = [:]
    /// Effect rows raised by `note` (landing ghosts), drained into `pendingEffects` by the caller.
    var extraEffects: [Float] = []

    /// A new world was built: drop every per-entity clock.
    func reset() {
        layers.removeAll(); rows.removeAll(); lastInfo.removeAll(); extraEffects.removeAll(); animators.removeAll(); stellarRows.removeAll()
        animatorSystem = Int.min
    }

    /// Hull configs are cached per `shïp` id; changing "Ship Animations" invalidates them.
    func setShipAnimations(_ on: Bool) {
        if on != shipAnimations { configs.removeAll() }
        shipAnimations = on
    }

    private func config(_ shipTypeID: Int, game: NovaGame?) -> HullAnimConfig {
        if let c = configs[shipTypeID] { return c }
        let c = game?.shan(shipTypeID).map { HullAnimConfig($0, animations: shipAnimations) } ?? HullAnimConfig()
        configs[shipTypeID] = c
        return c
    }

    private func usesShipWeaponSprite(_ weaponID: Int, game: NovaGame?) -> Bool {
        if weaponID < 128 { return false }
        if let c = usesShipSprite[weaponID] { return c }
        let u = game?.weapon(weaponID)?.usesShipWeaponSprite ?? false
        usesShipSprite[weaponID] = u
        return u
    }

    // MARK: Events

    /// `GameScene`: firing a weapon whose `Flags2` has 0x0200 flashes the shooter's weapon glow.
    var bodies: [StellarBody]?
    func note(event: WorldEvent, game: NovaGame?) {
        switch event {
        case let .weaponFired(shooterID, _, _, _, weaponID):
            if usesShipWeaponSprite(weaponID, game: game) { layers[shooterID, default: ShipLayerState()].weaponGlowFlare = 1 }
        case let .shipLanded(entityID, spobID, at):
            if let info = lastInfo[entityID], let body = bodies?.first(where: { $0.id == spobID }) {
                // kind 10: ghost = shipType, frame; rgb carry the stellar position.
                extraEffects.append(contentsOf: [10, Float(at.x), Float(at.y), Float(info.type), Float(info.frame),
                                                 Float(body.position.x), Float(body.position.y), 0])
            }
        case let .shipLaunched(entityID, at):
            extraEffects.append(contentsOf: [9, Float(at.x), Float(at.y), Float(entityID), 0, 0, 0, 0])
        case let .beam(shooterID, _, _, _, _, _, weaponID):
            if usesShipWeaponSprite(weaponID, game: game) { layers[shooterID, default: ShipLayerState()].weaponGlowFlare = 1 }
        default:
            break
        }
    }

    // MARK: Per-frame advance

    /// Advance every ship's clocks and flares by one display frame and rebuild the rows.
    func advance(world: World, game: NovaGame?, dt: Double, playerThrusting: Bool,
                 renderAngle: (Ship) -> Double, renderPosition: (Ship) -> Vec2) {
        let dt = max(0, min(dt, 0.1))
        // A continuous (or co-op echoed) beam holds the glow on for as long as it is live.
        for b in world.activeBeams where (b.continuous || b.visualOnly) && usesShipWeaponSprite(b.weaponID, game: game) {
            layers[b.shooterID, default: ShipLayerState()].weaponGlowFlare = 1
        }
        let murk = world.effectiveMurk(for: world.player)
        let origin = renderPosition(world.player)
        let bg = world.systemBackgroundColor
        let screenRevealsCloaked = world.player.cloakScannerFlags & 0x0002 != 0
        _ = screenRevealsCloaked
        var seen = Set<Int>()

        func build(_ ship: Ship, isPlayer: Bool) {
            let id = ship.entityID
            seen.insert(id)
            var st = layers[id] ?? ShipLayerState()
            let cfg = config(ship.shipTypeID, game: game)
            let disabled = !isPlayer && ship.disabled
            let angle = renderAngle(ship)
            let pos = renderPosition(ship)

            st.animClock += dt
            st.blinkClock += dt
            let turn = st.bank.update(angle: ship.angle, dt: dt)
            let heading = cfg.heading(forAngle: angle)
            let set = cfg.baseSet(turnSign: turn, animClock: st.animClock, disabled: disabled,
                                  carriesKeyShip: ship.carriesKeyShip)

            // Murk (0x00438db0): the hull mixes toward the backdrop by distance from the player.
            let fog = isPlayer ? 0 : MurkFog.level(murk: murk, dx: pos.x - origin.x, dy: pos.y - origin.y)

            // Weapon glow.
            st.weaponGlowFlare = cfg.weaponGlowAfter(st.weaponGlowFlare, dt: dt)
            let wgAlpha = st.weaponGlowFlare <= 0.02 ? 0 : st.weaponGlowFlare

            // Running lights.
            var lightAlpha = 0.0
            if !(disabled && cfg.hidesLightsWhenDisabled) {
                let inten = cfg.lightIntensity(clock: st.blinkClock)
                if inten > 0.02 {
                    if isPlayer {
                        lightAlpha = inten
                    } else {
                        let lightFog = Int(Double(fog) * 0.333)
                        let capped = min(inten, Double(Int(32 - Double(lightFog) * 1.5)) / 32)
                        lightAlpha = max(0, capped) * (1 - Double(lightFog) / 32)
                    }
                }
            }

            // Shield flare.
            if disabled {
                st.shieldFlare = 0
            } else {
                st.shieldFlare = ShieldFlare.advance(st.shieldFlare, shieldNow: ship.shield, shieldWas: st.lastShield,
                                                     maxShield: ship.maxShield, dt: dt)
            }
            st.lastShield = ship.shield
            let shieldAlpha = st.shieldFlare <= 0.02 ? 0 : st.shieldFlare * ShieldFlare.maxAlpha

            // Engine glow: the player's comes from live intent, an NPC's from moving forward fast.
            var thrust = 0.0   // 0 none, 1 thrust, 2 afterburner
            if isPlayer {
                if playerThrusting || ship.afterburnerActive { thrust = ship.afterburnerActive ? 2 : 1 }
            } else if !disabled {
                let fwd = ship.velocity.x * sin(ship.angle) + ship.velocity.y * cos(ship.angle)
                if ship.velocity.length > ship.stats.maxSpeed * 0.25 && fwd > 0 { thrust = ship.afterburnerActive ? 2 : 1 }
            }
            var glowAlpha = 0.0
            if thrust > 0 {
                let boosted = thrust == 2
                let target: Double
                if isPlayer {
                    target = reduceFlashing ? (boosted ? 0.95 : 0.75)
                        : (boosted ? Double.random(in: 0.85...1.0) : Double.random(in: 0.6...0.85))
                } else {
                    target = Double.random(in: 0.55...0.8)
                }
                st.thrusterAlpha = st.thrusterAlpha * 0.85 + target * 0.15
                glowAlpha = st.thrusterAlpha
                if !isPlayer {
                    // Murk caps an NPC's glow at trunc(32 - fog*1.5)/32 and dims it by its fog.
                    let cap = Double(Int(32 - Double(fog) * 1.5)) / 32
                    glowAlpha = max(0, min(glowAlpha, cap)) * (1 - Double(fog) / 32)
                }
            }

            // Tint (0x0046e470): the player gets only the oütf paint, an NPC its përs colour.
            var paint555: Int?
            if isPlayer, let p = ship.paintColor {
                func c5(_ v: Double) -> Int { max(0, min(31, Int((v * 31).rounded()))) }
                paint555 = (c5(p.r) << 10) | (c5(p.g) << 5) | c5(p.b)
            }
            var pers555: Int?
            if !isPlayer, let pid = ship.personID {
                if let cached = persColors[pid] { pers555 = cached } else {
                    let c = game?.pers(pid)?.color
                    persColors[pid] = c
                    pers555 = c
                }
            }
            let m = OriginalRendering.shipTint(isPlayer: isPlayer, paint555: paint555, persColor555: pers555,
                                               govtShipColor: nil).multipliers

            // The hull's one blend slot: murk, overwritten by ionization when that is stronger.
            var blend: (r: Double, g: Double, b: Double, f: Double) = (0, 0, 0, 0)
            if fog > 0 { blend = (Double(bg.r) / 255, Double(bg.g) / 255, Double(bg.b) / 255, Double(fog) / 32) }
            var ionIntensity = 0.0
            if ship.ionizeMax > 0 {
                ionIntensity = ship.ionCharge / ship.ionizeMax
                if ionIntensity >= 0.33 {
                    let level = min(24, max(16, Int((ionIntensity * 0.24).rounded()))) + Int.random(in: 0..<5) - 2
                    if fog < level || fog < 8 {
                        let c = ship.ionizeColor ?? (r: 0.4, g: 0.6, b: 1.0)
                        blend = (c.r, c.g, c.b, Double(level) / 32)
                    } else {
                        blend = (0, 0, Double(max(0, 32 - fog)) / 31, Double(fog) / 32)
                    }
                }
            }
            // Gate emergence / entry wash (white over the hull, hidden while invisible).
            var gateHidden = 0.0, gateWhite = 0.0
            if !isPlayer, let fade = world.originalAI.record(for: id)?.gateFade {
                gateHidden = fade.hidden ? 1 : 0
                gateWhite = fade.white
                if !fade.hidden, fade.white > 0 { blend = (1, 1, 1, fade.white) }
            }

            layers[id] = st
            lastInfo[id] = (ship.shipTypeID, heading, pos)
            let altSet = cfg.altSet(animClock: st.animClock)
            rows[id] = [
                Float(set), Float(heading), Float(cfg.framesPerSet), Float(altSet),
                Float(lightAlpha), Float(wgAlpha), Float(shieldAlpha), Float(glowAlpha),
                disabled ? 1 : 0, Float(turn), Float(cfg.baseOpacity),
                Float(m.r), Float(m.g), Float(m.b),
                Float(fog), Float(blend.f), Float(blend.r), Float(blend.g), Float(blend.b),
                Float(gateHidden), Float(gateWhite), Float(ionIntensity), Float(thrust),
                Float(st.shieldFlare),
                // 24: hyperspace jump-in over-speed still braking (px/s; the engine's own arrival kinematics),
                // 25: gate emergence in progress (1) -- the AI record's fade is already in 19/20.
                Float(ship.entryOverspeed), Float(world.originalAI.record(for: id)?.gateFade != nil ? 1 : 0),
            ]
        }

        build(world.player, isPlayer: true)
        for npc in world.npcs where npc.isAlive { build(npc, isPlayer: false) }
        if layers.count > seen.count + 64 {
            layers = layers.filter { seen.contains($0.key) }
            rows = rows.filter { seen.contains($0.key) }
        }
    }

    /// Rows for the live ships in `shipTransforms()` order (player first).
    func shipLayerRows(world: World) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity((1 + world.npcs.count) * Self.layerStride)
        func neutral() -> [Float] {
            var r = [Float](repeating: 0, count: Self.layerStride)
            r[2] = 36; r[10] = 1; r[11] = 1; r[12] = 1; r[13] = 1
            return r
        }
        out.append(contentsOf: rows[world.player.entityID] ?? neutral())
        for npc in world.npcs where npc.isAlive { out.append(contentsOf: rows[npc.entityID] ?? neutral()) }
        return out
    }

    // MARK: Animated + destroyed stellars

    /// Step every animated `spöb` (`GameScene.updateAnimatedStellars`) and publish `[frame, destroyed, fog]`
    /// per body. Also feeds `World.stellarFrames` so contact masks use the frame on screen.
    func advanceStellars(world: World, game: NovaGame?, systemID: Int?, dt: Double, destroyed: Set<Int>) {
        guard let game else { stellarRows = []; return }
        let bodies = world.systemContext.bodies
        if animatorSystem != (systemID ?? -1) {
            animators.removeAll()
            animatorSystem = systemID ?? -1
            for b in bodies {
                guard let spob = game.spob(b.id), spob.isAnimated || spob.flags2 & 0x1000 != 0 else { continue }
                let n = max(game.spobSprite(b.id)?.frameCount ?? 1, game.spobDestroyedSprite(b.id)?.frameCount ?? 1)
                guard n > 1 else { continue }
                animators[b.id] = StellarAnimator(frameCount: n, delay: max(0, spob.animationDelay),
                                                  bias: spob.frame0Bias, flags2: spob.flags2, custPic: spob.landingPictID)
            }
        }
        let ticks = dt * OriginalClock.ticksPerSecond
        let murk = world.effectiveMurk(for: world.player)
        let p = world.player.position
        var out: [Float] = []
        out.reserveCapacity(bodies.count * 3)
        for b in bodies {
            var frame = 0
            let isDestroyed = destroyed.contains(b.id)
            if var a = animators[b.id], let spob = game.spob(b.id) {
                let sheetCount = isDestroyed ? (game.spobDestroyedSprite(b.id)?.frameCount ?? 1) : (game.spobSprite(b.id)?.frameCount ?? 1)
                // Animate iff destroyed == Flags2 0x0080; otherwise rest on frame 0.
                if isDestroyed == spob.animatesOnlyWhenDestroyed, sheetCount > 1 {
                    frame = a.step(ticks: ticks, engaged: a.isGate && gateEngaged(b, a, world: world)) { Int.random(in: 0..<max(1, $0)) }
                    animators[b.id] = a
                }
            }
            world.stellarFrames[b.id] = frame
            let fog = MurkFog.level(murk: murk, dx: b.position.x - p.x, dy: b.position.y - p.y)
            out.append(Float(frame)); out.append(isDestroyed ? 1 : 0); out.append(Float(fog))
        }
        stellarRows = out
    }

    /// A gate is "engaged" while an enabled ship leaves it (AI state 0x15 aimed at it) or heads to it
    /// within twice the sheet width on both axes (`GameScene.gateIsEngaged`).
    private func gateEngaged(_ b: StellarBody, _ a: StellarAnimator, world: World) -> Bool {
        let past = a.current >= a.transitionFrame
        let reach = b.radius * 4 * (past ? 1.1 : 1)
        for npc in world.npcs where npc.isAlive && !npc.disabled {
            guard let rec = world.originalAI.record(for: npc.entityID) else { continue }
            if rec.state == OriginalAIState.gateEmerge, rec.secondary.stellarID == b.id { return true }
            if rec.state == OriginalAIState.travel || rec.state == OriginalAIState.gateEntry,
               rec.secondary.stellarID == b.id,
               abs(npc.position.x - b.position.x) < reach, abs(npc.position.y - b.position.y) < reach { return true }
        }
        return false
    }

    // MARK: cicn art

    private var cicnCache: [Int: SpriteSheet?] = [:]

    /// A decoded `cicn` (reticle corners, nav cursor, smoke puffs), cached; nil when absent.
    func cicn(_ id: Int, game: NovaGame?) -> SpriteSheet? {
        if let c = cicnCache[id] { return c }
        var sheet: SpriteSheet?
        if let r = game?.resources.resource(NovaType.cicn, id) { sheet = try? CICN.decode(r.data) }
        cicnCache[id] = sheet
        return sheet
    }

    // MARK: Weapon visuals

    /// Per `wëap`: `[usesShipSprite, smoke, bigSmoke, trailActive, trailR, trailG, trailB, hitCount, hitVel,
    /// hitLifeMax, hitR, hitG, hitB, lightningDensity, lightningAmplitude, smokeSet, graphicSpinID]` (colours 0…1).
    func weaponVisual(_ id: Int, game: NovaGame?) -> [Float] {
        guard id >= 128, let w = game?.weapon(id) else { return [] }
        let t = w.trailParticles.color, h = w.hitParticles.color
        return [
            w.usesShipWeaponSprite ? 1 : 0,
            (w.generatesSmallSmoke || w.generatesBigSmoke) ? 1 : 0, w.generatesBigSmoke ? 1 : 0,
            w.trailParticles.isActive ? 1 : 0, Float(t.r) / 255, Float(t.g) / 255, Float(t.b) / 255,
            Float(w.hitParticles.count), Float(w.hitParticles.velocity), Float(w.hitParticles.lifeMax),
            Float(h.r) / 255, Float(h.g) / 255, Float(h.b) / 255,
            Float(w.lightningDensity), Float(w.lightningAmplitude), Float(w.smokeSet), Float(w.graphicSpinID ?? -1),
        ]
    }
}
