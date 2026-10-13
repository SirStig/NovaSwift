import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The live-world <-> pilot seam: every rule a frontend runs to carry the persisted pilot
/// into a freshly built `World` and to carry what happened in flight back into the pilot.
///
/// Extracted from the Apple app (`GameContainerView` / `GameScene` wired these to the scene
/// through ~25 closures) so the Godot bridge runs the SAME rules instead of re-deriving
/// them. Nothing here is a frontend concern: it reads and writes `PlayerState` and the
/// `World`, and returns the strings/cues a frontend shows.
///
/// Inbound (pilot -> world): `seedDiplomacy`, `configure` (pre-population: Strict Play,
/// combat rating, përs/hull spawn gating, grudges, stellar armor, hold room),
/// `applyDefenseState` (garrisons, reinforcement lock, escort orders, broadcast context).
/// Outbound (world -> pilot): `syncLive` (legal record, crime rank revocation, combat
/// rating, stellar armor, garrisons), `note(event:)` (grudges, defeats, reinforcement
/// retrigger), `collectMined`, `resolveBoarding`, `HazardOutfits` (bombs).
public enum WorldPilotLink {

    // MARK: Inbound

    /// Seed the (per-galaxy cached) `Diplomacy` from the pilot before a world is built:
    /// the per-system legal record (EC-02), the system the pilot is in (where a crime's
    /// flood starts), the ranks that shield the player and the ranks whose flags the
    /// ship comm window reads (AI-42).
    public static func seedDiplomacy(_ dip: Diplomacy, pilot: PlayerState, game: NovaGame, systemID: Int) {
        dip.currentSystemID = systemID
        dip.game = game
        dip.seed(reputation: pilot.systemReputation ?? [:])
        // Ranks with "govt won't attack" (Flags 0x0100) shield the player
        // from that government's ships for as long as the rank is held.
        // EC-10: the flag is rebuilt for every government allied with the rank's (0x0046bc90).
        dip.rankProtectedGovts = RankPrivilege.governments(with: RankPrivilege.wontAttack,
                                                           activeRanks: pilot.activeRanks, game: game)
        // Every active rank's flags: the ship comm window reads 0x0400 / 0x0800
        // from ranks allied with the hailed ship (AI-42).
        dip.activeRankFlags = pilot.activeRanks.sorted()
            .compactMap { game.rank($0) }
            .filter { $0.govt >= 128 }
            .map { (govt: $0.govt, flags: $0.flags) }
    }

    /// Whether përs `id` may spawn now: not defeated, and its `ActiveOn` NCB test passes.
    public static func persSpawnEligible(_ id: Int, pilot: PlayerState, game: NovaGame) -> Bool {
        if pilot.isPersDefeated(id) { return false }
        guard let pers = game.pers(id), !pers.activeOn.isEmpty else { return true }
        return StoryEngine(game: game, player: pilot).evaluate(test: pers.activeOn)
    }

    /// Whether hull `id` may appear in düde spawns now: a non-blank `shïp.AppearOn` must pass.
    public static func shipSpawnEligible(_ id: Int, pilot: PlayerState, game: NovaGame) -> Bool {
        guard let ship = game.ship(id), !ship.appearOn.isEmpty else { return true }
        return StoryEngine(game: game, player: pilot).evaluate(test: ship.appearOn)
    }

    /// The per-day world RNG seed (so ambient traffic differs between visits). Same
    /// SplitMix64-style mix the Apple scene uses.
    public static func worldSeed(systemID: Int, day: Int) -> UInt64 { GameSession.worldSeed(systemID: systemID, day: day) }

    /// Everything a new world needs from the pilot BEFORE it is populated (so the initial
    /// fill already honours it): Strict Play, the combat rating the NPC fire ramp reads
    /// (AI-03), përs grudges and `ActiveOn` / `AppearOn` gating, damaged stellars' armor
    /// (OS-13), and the mining scoop's hold-room gate. `pilot` is read live (closures run
    /// during spawns); `liveCargo` is the flying ship's hold when the frontend keeps the
    /// pilot's cargo only at spaceport boundaries (nil = measure the pilot's own cargo).
    public static func configure(world w: World, game: NovaGame, pilot: @escaping () -> PlayerState,
                                 liveCargo: Bool = true) {
        let p = pilot()
        w.strictPlay = p.isStrictPlay
        w.playerCombatRating = p.combatRating
        w.playerPersGrudges = p.persGrudges ?? []
        w.persSpawnEligible = { persSpawnEligible($0, pilot: pilot(), game: game) }
        w.shipSpawnEligible = { shipSpawnEligible($0, pilot: pilot(), game: game) }
        w.stellarArmor = p.stellarStrengthLeft ?? [:]
        w.playerHoldHasRoom = { [weak w] in
            guard let w, let galaxy = w.galaxy else { return false }
            var held = pilot()
            if liveCargo { held.cargo = w.player.cargo }
            return PilotEconomy.cargoFree(held, galaxy: galaxy) > 0
        }
    }

    /// Seed a freshly built world with the persisted system-defense state (AI-13 / AI-15):
    /// stellar garrisons, the system's reinforcement retrigger lock, the saved per-category
    /// escort orders, and the pilot name / mission-cargo scan mask NPC broadcasts read (AI-32).
    public static func applyDefenseState(world w: World, game: NovaGame, pilot p: PlayerState, systemID: Int,
                                         escortOrdersChanged: (([Int]) -> Void)?) {
        w.pilotName = p.pilotName
        var mask: UInt16 = 0
        for am in p.activeMissions where am.isCarryingCargo {
            mask |= UInt16(truncatingIfNeeded: game.mission(am.missionID)?.scanMask ?? 0)
        }
        w.missionCargoScanMask = mask
        if let saved = p.escortCategoryOrders { w.originalAI.restoreCategoryCommand(saved) }
        w.originalAI.onCategoryCommandChanged = escortOrdersChanged
        w.stellarGarrisons = p.stellarGarrisons ?? [:]
        w.spawner?.holdReinforcements(retriggerDaysLeft: (p.reinforcementRetriggerDays ?? [:])[systemID] ?? 0)
    }

    // MARK: Outbound

    /// Fold what the live world accrued into the pilot: crimes -> the per-system legal
    /// record (EC-02) and the crime-sensitive rank revocation (EC-10), kills -> the combat
    /// rating (Appendix I; handed back to the world for the AI-03 fire ramp), damaged
    /// destroyable stellars' armor (OS-13) and the garrisons this visit touched (AI-15).
    /// Safe to call at any sync point: every drain only returns what accrued since the last.
    public static func syncLive(world: World, game: NovaGame, pilot: inout PlayerState) {
        FlightComm.syncStanding(world: world, game: game, pilot: &pilot)
        let armor = world.stellarArmor
        if !armor.isEmpty {
            var left = pilot.stellarStrengthLeft ?? [:]
            for (id, value) in armor where !pilot.isStellarDestroyed(id) && value >= 0 { left[id] = value }
            pilot.stellarStrengthLeft = left
        }
        let snapshot = world.garrisonSnapshot()
        if !snapshot.isEmpty {
            var garrisons = pilot.stellarGarrisons ?? [:]
            for (spobID, count) in snapshot { garrisons[spobID] = count }
            pilot.stellarGarrisons = garrisons.isEmpty ? nil : garrisons
        }
    }

    /// Fold the legal record / rating the diplomacy table accrued into the pilot WITHOUT a
    /// live world (the table is cached per galaxy and outlives a world).
    public static func foldStanding(_ dip: Diplomacy, game: NovaGame, pilot: inout PlayerState) {
        pilot.applyReputationDelta(dip.consumeReputationDelta())
        for crime in dip.consumeCrimeEvents() {
            pilot.revokeRanks(forCrime: crime.kind, against: crime.victim, game: game)
        }
        let delta = dip.consumeCombatRatingDelta()
        if delta != 0 { pilot.combatRating = CombatRatingRule.fold(pilot.combatRating, adding: delta) }
    }

    /// World events that persist into the pilot: a përs the player wronged (grudge) or
    /// defeated (never to appear again), and a system calling reinforcements (the day
    /// countdown before it may call again). Returns true when the pilot changed.
    @discardableResult
    public static func note(event: WorldEvent, pilot: inout PlayerState) -> Bool {
        switch event {
        case let .personGrudge(pid):
            pilot.recordPersGrudge(pid)
            return true
        case let .personDefeated(pid):
            pilot.recordPersDefeated(pid)
            return true
        case let .reinforcementsCalled(systemID, days):
            var delays = pilot.reinforcementRetriggerDays ?? [:]
            delays[systemID] = max(delays[systemID] ?? 0, days)
            pilot.reinforcementRetriggerDays = delays
            return true
        default:
            return false
        }
    }

    /// The player's mining scoop collected `quantity` tons of cargo `cargoType` (a destroyed
    /// asteroid's yield, a plundered-loot spill): add it to the hold, clamped to free
    /// space. Returns the tonnage stowed and the commodity's name, nil if nothing fit.
    public static func collectMined(cargoType: Int, quantity: Int, pilot: inout PlayerState,
                                    galaxy: Galaxy) -> (stowed: Int, name: String)? {
        guard let commodity = Commodity.standard(cargoID: cargoType) else { return nil }
        let stowed = PilotEconomy.collectCargo(&pilot, id: cargoType, tons: quantity, galaxy: galaxy)
        guard stowed > 0 else { return nil }
        return (stowed, galaxy.game.commodityName(commodity))
    }

    /// An NPC boarded the player (AI-29, `Boarding_BoardShipAndTransferCargo` 0x00412550):
    /// the boarders take cargo and credits. Mutates `cargo` and `credits` and returns the
    /// original's status line (nil when nothing was taken). The caller sounds snd 151.
    public static func resolveBoarding(world: World, game: NovaGame, boarderID: Int, ratio: Int,
                                       cargo: inout [Int: Int], credits: inout Int) -> String? {
        let loss = world.resolvePlayerBoarding(byShipID: boarderID, ratio: ratio, playerCargo: cargo,
                                               playerCargoCapacity: world.player.cargoCapacity,
                                               playerCredits: credits)
        for (commodity, tons) in loss.cargo {
            let left = (cargo[commodity] ?? 0) - tons
            cargo[commodity] = left > 0 ? left : nil
        }
        credits = max(0, credits - loss.credits)
        return OriginalText(game: game).playerBoardedLine(tons: loss.cargo.values.reduce(0, +), credits: loss.credits)
    }
}

// MARK: - Bombs

/// Bomb outfits (OS-08): a fuse seeded at `rand(100)` counts 30 Hz ticks to 300
/// (6.7-10 s after the bomb comes aboard, 0x0044b3d4). A lethal bomb (ModType 47) then
/// destroys the ship outright - game over, no escape pod; a nonlethal one (ModType 50)
/// throws all its units overboard, plays spob impact effect `ModVal - 128` and deals
/// armor-only damage `armor + rand(armor x 0.5 + 1)` of the hull's base armor.
public enum HazardOutfits {
    public enum Outcome: Equatable, Sendable {
        /// Nothing happened this tick.
        case none
        /// The lethal bomb went off (the ship has taken its fatal damage): show `line`.
        case detonated(line: String, outfitID: Int)
        /// The nonlethal bomb went off (outfit removed, armor damaged): draw the blast
        /// and show `line` ("Your <outfit> has exploded!", #39–#41, 0x190 raw calls).
        case nonlethal(outfitID: Int, boomID: Int?, line: String)
    }

    /// The bomb that will go off (OS-08, 0x0046d4b0): ModType 47 sets class 1 (lethal); ModType 50 is
    /// class 2 only while the class is still below 1, so a lethal bomb aboard wins whatever the
    /// outfit ids. Within a class the lowest outfit id.
    static func activeBomb(pilot: PlayerState, game: NovaGame) -> (OutfRes, Int, Bool)? {
        var nonlethal: (OutfRes, Int, Bool)?
        for oid in pilot.outfits.filter({ $0.value > 0 }).keys.sorted() {
            guard let o = game.outfit(oid) else { continue }
            for (type, value) in o.modifiers {
                if type == .bomb { return (o, value, true) }
                if type == .nonlethalBomb, nonlethal == nil { nonlethal = (o, value, false) }
            }
        }
        return nonlethal
    }

    /// `Outfit_RecomputeOutfitDerivedState` 0x0046d4b0 (OS-08): every recompute with a bomb aboard
    /// zeroes the timer and, because it is then at or below 0.0, reseeds `rand(100)`. The fuse is
    /// therefore not kept across the events that recompute (a purchase or sale, launching, jumping,
    /// boarding). Without a bomb the class is 0 and the timer clears. Hosts call this wherever the
    /// original recomputes; `tick` still seeds a fuse when none was ever drawn.
    public static func recompute(fuse: inout Int?, pilot: PlayerState, game: NovaGame,
                                 rand: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        fuse = activeBomb(pilot: pilot, game: game) == nil ? nil : rand(100)
    }

    /// Advance one 30 Hz tick of the fuse. `fuse` is the host's persisted counter (nil = no
    /// bomb aboard). Mutates `pilot.outfits` and the ship when a bomb goes off.
    public static func tick(fuse: inout Int?, pilot: inout PlayerState, ship: Ship?, game: NovaGame,
                            rand: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Outcome {
        guard let (outfit, value, lethal) = activeBomb(pilot: pilot, game: game) else { fuse = nil; return .none }
        guard let f = fuse else { fuse = rand(100); return .none }
        guard f >= 300 else { fuse = f + 1; return .none }
        fuse = nil
        guard let ship, ship.isAlive else { return .none }
        if lethal {
            let line = value >= 0 ? game.descText(value)
                : (game.stringList(2002)?.string(at: 38) ?? "A bomb has exploded onboard your ship!")
            ship.hasEscapePod = false
            ship.hasAutoEject = false
            _ = ship.applyDamage(shield: 1_000_000, armor: 1_000_000, piercing: true)
            return .detonated(line: line, outfitID: outfit.id)
        }
        let thrown = pilot.outfits[outfit.id] ?? 1
        pilot.outfits[outfit.id] = nil
        let base = Double(game.ship(pilot.shipType)?.armor ?? 0)
        let damage = base + Double(rand(max(1, Int(base * 0.5 + 1))))
        _ = ship.applyDamage(shield: 0, armor: damage, piercing: true)
        return .nonlethal(outfitID: outfit.id, boomID: value >= 128 ? value - 128 : nil,
                          line: OriginalText(game: game).bombExploded(
                            count: thrown, singular: outfit.lowercaseDisplayName,
                            plural: outfit.lowercasePluralDisplayName))
    }
}

extension OriginalText {
    /// The boarded-player line (0x00412550): "<n> ton(s)" STR# 2002 #391 #373
    /// [#392] "<c> credit(s)" #374, nil when nothing was taken.
    public func playerBoardedLine(tons: Int, credits: Int) -> String? {
        guard tons > 0 || credits > 0 else { return nil }
        let list = game.stringList(2002)
        func s(_ i: Int) -> String { list?.string(at: i) ?? "" }
        var parts: [String] = []
        if tons > 0 {
            parts += ["\(tons)", tons == 1 ? "ton" : "tons", s(391), s(373)]
            if credits > 0 { parts.append(s(392)) }
        }
        if credits > 0 { parts += ["\(credits)", credits < 2 ? "credit" : "credits"] }
        parts.append(s(374))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Jump engage

extension World {
    /// At hyperjump engage, deployed bay fighters that can't make the jump (and whose class
    /// lacks Flags2 0x0010) call out - "Wait for me!" / "Wait for us!" (STR# 2002 #160-163,
    /// the class name first; FL-23). Nil when nobody is stranded. Consumes one rng draw.
    public func strandedFighterWarning(game: NovaGame) -> String? {
        let stranded = npcs.filter { f in
            guard f.carrierID == World.playerEntityID, f.isAlive, !f.disabled,
                  f.fuel < ShipFuel.perJump else { return false }
            return (game.ship(f.shipTypeID)?.flags2 ?? 0) & 0x0010 == 0
        }
        guard let last = stranded.last else { return nil }
        let entry = (stranded.count == 1 ? 160 : 162) + rng.range(2)
        guard let line = game.stringList(2002)?.string(at: entry) else { return nil }
        let name = game.ship(last.shipTypeID)?.displayName ?? last.name
        return "\(name): \(line)"
    }
}
