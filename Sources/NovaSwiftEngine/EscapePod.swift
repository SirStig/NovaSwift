import Foundation
import NovaSwiftKit

/// OS-02, the escape pod in flight (`Ship_HandlePlayerShipCore` 0x0044aa70: the
/// eject block 0x00451024 and the timed action 0x0044d490).
///
/// The player may eject while disabled or while their hull is in its death
/// sequence, with an owned ModType-11 escape pod or an *ejectable* bay — a
/// fighter bay whose carried class has `shïp` Flags 0x8000. A manual eject is
/// the Alt+X command (`requestEject`); a destroyed hull with a ModType-20
/// auto-eject also goes on its own once its death timer is down to half its
/// DeathDelay or to 30 raw calls. Without a pod the death sequence runs out
/// and the pilot is lost.
///
/// Ejecting leaves the old hull behind as a derelict wreck that hostiles turn
/// on (a destroyed one finishes blowing up). The player then flies either the
/// pod — shïp 895, at its base shield and armor, for 350 ticks at full thrust
/// along its heading, with no control, after which the host runs the respawn
/// (`EscapePodRespawn` in NovaSwiftStory) — or, from an ejectable bay, that
/// bay's fighter at 50–79 % of its base shield, armor and fuel, which simply
/// carries on. A pod releases the player's escorts.
extension World {

    /// shïp 895: the escape pod's class.
    public static let escapePodShipID = Ship.escapePodShipID
    /// The pod flies 350 ticks (0x15e) before the respawn.
    public static let escapePodTicks: Double = 350

    /// The player's eject command (Alt+X). Honoured on the next step if the
    /// player can eject then.
    public func requestEject() { ejectRequested = true }

    /// The self-destruct command (Alt-−, the 0x00451954 block of
    /// `Ship_HandlePlayerShipCore`, UI-15), run each step with whether the
    /// command is held and the 30 Hz ticks elapsed. Pressing it while disarmed
    /// arms a 150-tick countdown ("Self-destruct sequence initiated.", STR# 2002
    /// #385 #386, 0x28); letting go while armed aborts (#385 #387). While held,
    /// each whole-30-tick boundary at or under 120 posts "Self-destruct in N
    /// seconds." (#385 #395 N #389, 0x46), and at 1 tick or less the ship blows
    /// up: shields 0, armor −1, target cleared ("Have a nice day.", #390). Not
    /// modelled: the sound cues and the hulls docked to the player that
    /// detonate with it.
    func stepSelfDestruct(held: Bool, ticks: Double) {
        func line(_ ids: [Int], _ count: String? = nil, frames: Int) {
            let misc = galaxy?.game.stringList(2002)
            var parts = ids.map { misc?.string(at: $0) ?? "" }
            if let count { parts.insert(count, at: 2) }
            var text = parts.filter { !$0.isEmpty }.joined(separator: " ")
            if count != nil { text += "." }
            postOverlayMessage(text, frames: frames)
        }
        if held, selfDestructCountdown < 0, player.isAlive {
            line([385, 386], frames: 0x28)
            selfDestructCountdown = 150
        }
        guard selfDestructCountdown > 0 else { return }
        guard held else {
            line([385, 387], frames: 0x28)
            selfDestructCountdown = -1
            return
        }
        selfDestructCountdown -= ticks
        let whole = Int(selfDestructCountdown)
        if selfDestructCountdown <= 120, whole % 30 == 0 {
            line([385, 395, 389], String(Int(selfDestructCountdown / 30)), frames: 0x46)
        }
        if selfDestructCountdown <= 1 {
            postOverlayMessage(galaxy?.game.stringList(2002)?.string(at: 390) ?? "", frames: 0x28)
            player.shield = 0
            player.armor = -1
            player.currentTargetID = nil
            selfDestructCountdown = -1
        }
    }

    /// The pilot is in the escape pod (flying, or landed awaiting the
    /// respawn): no commands are taken.
    public var playerInEscapePod: Bool { escapePodTicksLeft != nil || escapePodLanded }

    /// Whether the eject command would work right now: disabled or going
    /// down, with a pod or an ejectable bay, and not already in the pod.
    public var canPlayerEject: Bool {
        guard escapePodTicksLeft == nil, !escapePodLanded,
              player.hasEscapePod || ejectableBayClass(of: player) != nil else { return false }
        return player.isAlive ? player.disabled : !playerDeathSequenceOver
    }

    /// The bay class the player would eject into
    /// (`ShipClass_FindLaunchBayShipClassId` 0x00464590): the carried class
    /// of the first bay, by weapon id, with a fighter docked whose `shïp` has
    /// Flags 0x8000.
    func ejectableBayClass(of ship: Ship) -> Int? {
        ejectableBay(of: ship)?.spec.fighterShipID
    }

    /// B-6 (`Ship_HandleShip` 0x00433050): a destroyed ship with an
    /// ejectable bay rolls once its death timer is down to half the hull's
    /// DeathDelay.
    /// A9 (0x00433050): in the second half of its death delay a hull with a
    /// PodCount throws that many debris puffs, one every
    /// `max(10, trunc(DeathDelay / PodCount × 0.4))` ticks, the first at once.
    /// Each lives `Rand(100) + 150` ticks, carries the hull's velocity plus
    /// `(Rand(10) + 10) × 0.1` px/tick on a random heading.
    func tickDeathDebris(_ ship: Ship, timerTicks: Double) {
        guard ship.debrisLeft > 0, ship.deathDelayTicks > 0, ship.debrisPodCount > 0,
              timerTicks <= ship.deathDelayTicks * 0.5 else { return }
        let interval = max(10, Int(ship.deathDelayTicks / Double(ship.debrisPodCount) * 0.4))
        let tick = Int(timerTicks)
        guard tick != ship.lastDebrisTick, tick % interval == 0 || ship.debrisLeft == ship.debrisPodCount
        else { return }
        ship.lastDebrisTick = tick
        ship.debrisLeft -= 1
        let heading = Double(rng.range(360)) * .pi / 180
        let speed = Double(rng.range(10) + 10) * 0.1
        let velocity = ship.velocity + Vec2.heading(heading) * OriginalClock.perSecond(speed)
        emit(.debrisPuff(at: ship.position, velocity: velocity, lifeTicks: rng.range(100) + 150))
    }

    func dyingCarrierEscapeDue(_ ship: Ship, timerTicks: Double) -> Bool {
        guard !ship.dyingBaysCleared, ship.deathDelayTicks > 0, ejectableBay(of: ship) != nil else { return false }
        return timerTicks <= ship.deathDelayTicks * 0.5
    }

    /// The roll: one time in three one fighter escapes the bay. The original
    /// then randomises the shield (`Rand(trunc(shield))` above 1.0) and halves
    /// the velocity of the ship in slot *1* when the launch succeeded (the
    /// spawn function returns 1, not the new slot) and of the player (slot 0)
    /// when it failed — reproduced here with the first NPC in slot order
    /// standing for slot 1. Every bank is emptied either way, so it is one
    /// chance per death.
    func dyingCarrierEscape(_ ship: Ship) {
        guard !ship.dyingBaysCleared else { return }
        ship.dyingBaysCleared = true
        if rng.range(3) == 0, let bay = ejectableBay(of: ship) {
            let launched = launchFighter(from: ship, bay: bay, formationSlot: 0)
            let slot = launched != nil ? npcs.first : player
            if let s = slot {
                if s.shield > 1 { s.shield = Double(rng.range(Int(s.shield.rounded(.towardZero)))) }
                s.velocity = s.velocity * 0.5
            }
        }
        for b in ship.fighterBays { b.docked = 0 }
        for m in ship.weapons { m.count = 0; m.ammo = 0 }
    }

    /// `Weapon_FindLaunchBayWeaponBank` (0x00464600): that bay.
    func ejectableBay(of ship: Ship) -> Ship.FighterBay? {
        guard let game = galaxy?.game else { return nil }
        return ship.fighterBays.sorted { $0.spec.bayWeaponID < $1.spec.bayWeaponID }.first {
            $0.docked >= 1 && (game.ship($0.spec.fighterShipID)?.flags ?? 0) & 0x8000 != 0
        }
    }

    /// Run the eject rules for this step; called by `step` after the player
    /// has flown.
    func stepEjection() {
        defer { ejectRequested = false }
        guard escapePodTicksLeft == nil, galaxy != nil else { return }
        let canEject = player.hasEscapePod || ejectableBayClass(of: player) != nil
        guard canEject else { return }
        if player.isAlive {
            if player.disabled && ejectRequested { eject(destroyed: false) }
            return
        }
        // Destroyed: the death sequence must still be running.
        guard playerDeathReportedForEject, !playerDeathSequenceOver else { return }
        let start = player.deathDelayTicks * 3
        let timer = start - playerDeathElapsed / OriginalClock.rawCallSeconds
        let autoReady = player.hasAutoEject && (timer <= player.deathDelayTicks * 0.5 || timer <= 30)
        if ejectRequested || autoReady { eject(destroyed: true) }
    }

    /// The eject transform (0x00451024 → 0x00451630).
    private func eject(destroyed: Bool) {
        guard let galaxy else { return }
        let old = player
        let bayClass = ejectableBayClass(of: old)
        let intoPod = bayClass == nil
        let newClass = bayClass ?? Self.escapePodShipID
        guard let craft = galaxy.makeLoadedShip(newClass, government: old.government,
                                                at: old.position, angle: old.angle) else {
            Log.combat.error("eject: class \(newClass) not in the data — staying aboard")
            return
        }
        if intoPod {
            craft.shield = craft.maxShield
            craft.armor = craft.maxArmor
            craft.invulnerable = true
        } else {
            craft.shield = Double(rng.range(30) + 50) * craft.maxShield * 0.01
            craft.armor = Double(rng.range(30) + 50) * craft.maxArmor * 0.01
            craft.fuel = Double(rng.range(30) + 50) * craft.maxFuel * 0.01
        }
        // Relaunch at full speed along the heading (an unclamped polar add).
        craft.velocity = Vec2.heading(wholeDegrees(old.angle)) * craft.stats.maxSpeed
        craft.entityID = World.playerEntityID

        // The old hull becomes a derelict wreck, already plundered.
        old.currentTargetID = nil
        old.brain = nil
        old.plunderCredits = 0
        old.plunderOutfits = []
        old.cargo = [:]
        old.wreckOfPlayer = true
        player = craft
        let wreckID = addNPC(old, arrival: .populate)
        for npc in npcs where npc.isAlive && npc.entityID != wreckID {
            if npc.currentTargetID == World.playerEntityID {
                if isEffectivelyHostileToPlayer(npc) {
                    npc.currentTargetID = wreckID
                    npc.brain?.targetID = wreckID
                } else {
                    npc.currentTargetID = nil
                    npc.brain?.targetID = nil
                }
            }
            // A pod can't lead: the player's escorts are released.
            if intoPod, npc.brain?.leaderID == World.playerEntityID, !isEffectivelyHostileToPlayer(npc) {
                npc.brain?.leaderID = nil
            }
        }
        if intoPod { escapePodTicksLeft = Self.escapePodTicks }
        if destroyed { playerDeathEjected = true }
        emit(.playerEjected(previousShipType: old.shipTypeID, newShipType: newClass,
                            intoPod: intoPod, wreckID: wreckID))
        Log.combat.notice("Player ejected \(intoPod ? "in the escape pod" : "into a bay fighter") (class \(newClass)) from \(destroyed ? "a destroyed" : "a disabled") hull")
    }

    /// The pod's flight (`PlayerTick_TimedActionTransition` 0x0044d490): full
    /// thrust along its heading, per axis up to its top speed, with no
    /// control; when the 350 ticks are up the host respawns the pilot.
    func stepEscapePod(_ dt: Double) {
        guard var left = escapePodTicksLeft else { return }
        player.addPolarVelocityWithClamp(heading: wholeDegrees(player.angle),
                                         step: player.stats.acceleration * dt,
                                         max: player.stats.maxSpeed)
        player.position += player.velocity * dt
        left -= dt * OriginalClock.ticksPerSecond
        if left > 0 {
            escapePodTicksLeft = left
        } else {
            escapePodTicksLeft = nil
            escapePodLanded = true
            emit(.escapePodRespawn)
        }
    }
}
