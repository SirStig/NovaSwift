import Foundation
import NovaSwiftKit

/// Which dudes and fleets populate a system, and how densely. Built by the app
/// from a decoded `SystRes` (its `dudeSpawns`/`fleetSpawns`/`averageShips`).
public struct SpawnTable {
    public var dudes: [(dudeID: Int, prob: Int)]
    public var fleets: [(fleetID: Int, prob: Int)]
    public var averageShips: Int
    public var systemGovt: Int
    /// This system's own `sÿst.id` — needed to test `flët.LinkSyst`'s
    /// "128-2175 = a specific system id" case (FLEETS.md §3). -1 when a
    /// table is built without a real system (e.g. ad-hoc/test tables), which
    /// simply makes that one `LinkSyst` band never match.
    public var systemID: Int
    /// Reactive reinforcement fleet + timing: `sÿst.ReinfFleet`/`ReinfTime`/
    /// `ReinfIntrval` (FLEETS.md §5). -1 = no reinforcement fleet configured
    /// for this system.
    public var reinforcementFleet: Int
    /// Frames before `reinforcementFleet` arrives once triggered.
    public var reinforcementDelay: Int
    /// Minimum days between `reinforcementFleet` triggers (regen gate).
    public var reinforcementRegen: Int

    public init(dudes: [(dudeID: Int, prob: Int)] = [],
                fleets: [(fleetID: Int, prob: Int)] = [],
                averageShips: Int = 4, systemGovt: Int = independentGovt,
                systemID: Int = -1, reinforcementFleet: Int = -1,
                reinforcementDelay: Int = 0, reinforcementRegen: Int = 0) {
        self.dudes = dudes; self.fleets = fleets
        self.averageShips = averageShips; self.systemGovt = systemGovt
        self.systemID = systemID
        self.reinforcementFleet = reinforcementFleet
        self.reinforcementDelay = reinforcementDelay
        self.reinforcementRegen = reinforcementRegen
    }

    /// Build directly from a decoded system.
    public init(system: SystRes) {
        self.init(dudes: system.dudeSpawns, fleets: system.fleetSpawns,
                  averageShips: system.averageShips, systemGovt: system.government,
                  systemID: system.id, reinforcementFleet: system.reinforcementFleet,
                  reinforcementDelay: system.reinforcementDelay,
                  reinforcementRegen: system.reinforcementRegen)
    }
}

/// Maintains a living NPC population in the current system: it periodically spawns
/// dudes and fleets from the `SpawnTable`, weighted by their probabilities, at the
/// hyperspace edge, and lets the world despawn ships that jump out or die. This is
/// what makes a system feel inhabited — traders coming and going, patrols on
/// station, the occasional pirate pack.
public final class Spawner {
    public let galaxy: Galaxy
    public var table: SpawnTable
    /// How many NPCs to keep around; derived from the system's average count.
    /// This is specifically the *single-ship* backbone target — the ambient
    /// lone-trader/lone-patrol traffic that should make up most of a system's
    /// population. Fleets arrive on top of this as an occasional accent.
    public var targetPopulation: Int
    public var maxPopulation = 18
    /// How many spawned fleets may share a system at once. Fleets are an accent
    /// on top of the single-ship backbone, not the backbone itself, so this
    /// stays low; a busy system (high `AvgShips`) tolerates a second. Keeping it
    /// small is the main lever that stops formations from dominating the
    /// population — the "I only ever see the same couple of fleets and barely any
    /// lone ships" symptom.
    public var maxConcurrentFleets: Int
    /// Seconds between ambient single-ship arrival attempts once below target.
    /// Deliberately unhurried — a fresh ship warping in every couple of seconds
    /// made systems feel like a churning airport; real traffic trickles in.
    public var spawnInterval: Double = 6.0
    private var timer: Double = 0

    /// Seconds between deliberate *fleet* arrivals, tracked separately from the
    /// ambient single-ship trickle so fleets actually show up on a predictable
    /// cadence instead of losing every weighted coin-flip to lone traders (which
    /// is why the player "never saw fleets"). A fleet is a group event, so it's
    /// spaced further apart than ambient singles.
    public var fleetInterval: Double = 26
    private var fleetTimer: Double = 8

    /// The system's galaxy-wide fleet pool: every `flët` whose `LinkSyst` band
    /// matches this system (FLEETS.md §3), merged with any fleets the system's
    /// own spawn table explicitly pins, each carrying a selection weight. This is
    /// the real backbone of EV Nova's fleet traffic — nearly no `sÿst` lists a
    /// fleet in its `DudeTypes` table, yet the galaxy is full of patrols and
    /// convoys because fleets sweep in by `LinkSyst`. Computed lazily on first use
    /// (needs `world.diplomacy` for the ally/enemy bands) and cached, since
    /// `LinkSyst` eligibility is static for a system's lifetime; the *dynamic*
    /// `AppearOn` gate is applied per-draw on top, not baked into this cache.
    private var linkFleetPool: [(fleetID: Int, weight: Int)]?

    /// Sim-seconds since this spawner was created — drives the reactive
    /// reinforcement-fleet timers below (FLEETS.md §5), independent of
    /// `timer` (which only gates *ambient* dude/fleet arrivals).
    private var simClock: Double = 0
    /// Sim-time at which a triggered reinforcement fleet should actually
    /// arrive, once its `ReinfTime`/frame delay has elapsed. `nil` = no
    /// reinforcement currently in flight for this system.
    private var reinforcementDueAt: Double?
    /// Sim-time before which a new reinforcement trigger is suppressed —
    /// `sÿst.ReinfIntrval`'s regen gate, so a system with allies stuck in a
    /// losing fight doesn't re-summon every tick once it first triggers.
    private var reinforcementCooldownUntil: Double = 0
    /// EV Nova's `ReinfIntrval` is in calendar days, but nothing at this
    /// layer (`Spawner`/`World`) tracks a galaxy day clock — that lives in
    /// `NovaSwiftStory.GameDate`, a layer up, and isn't threaded through combat
    /// simulation. Treat a "day" as this many sim-seconds so the regen gate
    /// still does its job (suppressing back-to-back re-triggers) without
    /// pretending to calendar accuracy — an engine invention in the same
    /// spirit as `maxPopulation`/`spawnInterval` above (see FLEETS.md §7).
    private let secondsPerReinforcementDay: Double = 60

    public init(galaxy: Galaxy, table: SpawnTable) {
        self.galaxy = galaxy
        self.table = table
        // Track the system's real `sÿst.AvgShips` as the ambient fill target
        // (Bible: "the average number of AI ships in the system … +/- 50%").
        // Turnover — tour-of-duty departures + traders landing/leaving — makes the
        // live count breathe around this target instead of sitting pinned at it,
        // which is what reads as ships coming and going. Fleets/reinforcements are
        // group events allowed to push a bit past it, up to `maxPopulation`.
        let avg = max(3, table.averageShips)
        self.targetPopulation = min(maxPopulation, avg)
        // Small systems get one fleet at most; a busy system (target ~16+)
        // tolerates two so a large hub doesn't feel starved of formations.
        self.maxConcurrentFleets = max(1, self.targetPopulation / 8)
    }

    /// Where a spawn comes from: mid-system (initial fill), the hyperspace edge
    /// (a jump-in), or lifting off from a stellar object (planet launch).
    private enum SpawnOrigin { case interior, edge, planet, hypergate(spobID: Int) }

    /// Fill the system to its target population immediately (used on entry so the
    /// system isn't empty for the first few seconds). If the system has any
    /// eligible fleet, one is placed up front so the player often finds a
    /// formation already on station instead of only ever catching lone ships.
    public func populate(_ world: World) {
        applyHabitation(world)
        // One fleet up front, as an accent — so the player often arrives to find
        // a formation already on station — but just the one. Skipped entirely in
        // uninhabited systems (`maxConcurrentFleets == 0`), which have no base to
        // station a formation at.
        if maxConcurrentFleets > 0, let fid = pickFleet(world, excluding: []) {
            spawnFleet(fid, into: world, origin: .interior)
        }
        // Fill the lone-ship backbone to the ambient target, counting ONLY
        // single ships so the up-front fleet doesn't eat into that budget — the
        // player should arrive to mostly lone traffic with a fleet among it, not
        // a system that's all formation.
        var guardCount = 0
        while singleShipCount(world) < targetPopulation,
              world.npcs.count < maxPopulation,
              guardCount < maxPopulation * 2 {
            spawnOne(into: world, origin: .interior)
            guardCount += 1
        }
    }

    /// Whether `applyHabitation` has already scaled this spawner for its system.
    private var habitationApplied = false

    /// Thin out an empty or uninhabited system's traffic. A system with a real
    /// port pulls in traders and bases an authority patrol, sustaining a full
    /// ambient population plus the odd fleet. A system with nothing landable —
    /// empty space, or only bare uninhabited rocks — has no such draw: the only
    /// ships there are passing through between real destinations. So we cut the
    /// ambient target right down and drop fleets to none, leaving a thin trickle
    /// of jump-in/jump-out traffic rather than a patrolled, lived-in system.
    ///
    /// Runs once, lazily, the first time we have the `world` (its
    /// `systemContext` is what tells us whether anything here is inhabited).
    private func applyHabitation(_ world: World) {
        guard !habitationApplied else { return }
        habitationApplied = true
        let inhabited = world.systemContext.bodies.contains { $0.canLand }
        guard !inhabited else { return }
        // No port to sustain a population — just a few ships passing through.
        // Truly empty systems (no stellars at all) are the quietest.
        targetPopulation = min(targetPopulation, world.systemContext.bodies.isEmpty ? 2 : 3)
        // Nothing to patrol or base a formation at: no fleets. The concurrent-
        // fleet gate in `update` reads `< maxConcurrentFleets`, so 0 disables
        // both the up-front placement and the ongoing cadence.
        maxConcurrentFleets = 0
    }

    /// Called every step by the world.
    public func update(_ dt: Double, world: World) {
        applyHabitation(world)
        simClock += dt
        updateReinforcements(world)

        // Deliberate fleet cadence, independent of the ambient trickle so fleets
        // reliably appear — but gated so they stay an *accent*, not the bulk of
        // the population. Two gates fix the "same couple of fleets, barely any
        // lone ships" symptom: a hard cap on concurrent fleets, and picking a
        // fleet type that isn't already in-system so what does arrive varies.
        fleetTimer -= dt
        if fleetTimer <= 0 {
            // Jitter the next fleet arrival ±40% so convoys don't march in on a
            // metronome; a fleet is a group event, spaced well apart from the
            // ambient single-ship trickle.
            fleetTimer = fleetInterval * world.rng.double(in: 0.6...1.4)
            if world.npcs.count < maxPopulation,
               currentFleetCount(world) < maxConcurrentFleets,
               let fid = pickFleet(world, excluding: presentFleetIDs(world)) {
                spawnFleet(fid, into: world, origin: .edge)
            }
        }

        // Ambient single-ship trickle — the backbone of a system's traffic. It's
        // maintained toward `targetPopulation` counting ONLY lone ships, so a
        // fleet passing through never starves it. (The old code gated on total
        // head-count, so as soon as a fleet's ships pushed the count past the
        // target the trickle stopped — which is exactly what made systems read
        // as "all fleets, no singles.")
        timer -= dt
        guard singleShipCount(world) < targetPopulation,
              world.npcs.count < maxPopulation, timer <= 0 else { return }
        timer = spawnInterval
        // Split arrivals between hyperspace jump-ins and spaceport lift-offs so the
        // player sees a believable two-way flow — ships coming in from the edge AND
        // traders lifting off planets and heading out (see `spawnOutbound`). ~40%
        // launches when the system has pads; the rest jump in.
        let hasPads = world.systemContext.bodies.contains { $0.canLand }
        let origin: SpawnOrigin = (hasPads && world.rng.double(in: 0...1) < 0.4) ? .planet : .edge
        spawnOne(into: world, origin: origin)
    }

    // MARK: Population accounting (single-ship backbone vs. fleet accent)

    /// Ships in-system that belong to a spawned `flët` (flagship + escorts).
    private func fleetShipCount(_ world: World) -> Int {
        world.npcs.reduce(0) { $0 + (($1.brain?.isFleetMember ?? false) ? 1 : 0) }
    }

    /// Lone ships in-system — the ambient single-ship traffic the trickle
    /// maintains, i.e. everything that isn't part of a fleet.
    private func singleShipCount(_ world: World) -> Int {
        world.npcs.count - fleetShipCount(world)
    }

    /// Distinct fleets currently in-system, counted by their flagships (a fleet
    /// whose lead has died leaves reverting escorts that each read as their own
    /// remnant — an acceptable over-count that only makes the spawner slightly
    /// more conservative about adding another fleet).
    private func currentFleetCount(_ world: World) -> Int {
        world.npcs.reduce(0) {
            guard let b = $1.brain, b.isFleetMember, b.leaderID == nil else { return $0 }
            return $0 + 1
        }
    }

    /// The `flët` ids of every fleet currently represented in-system.
    private func presentFleetIDs(_ world: World) -> Set<Int> {
        Set(world.npcs.compactMap { $0.brain?.fleetID })
    }

    /// Pick an eligible fleet to spawn, optionally excluding ids already present
    /// so repeats vary. Applies the same `LinkSyst`/`AppearOn` eligibility the
    /// pool always has; returns nil when nothing eligible remains.
    private func pickFleet(_ world: World, excluding present: Set<Int>) -> Int? {
        let pool = fleetPool(world: world).filter { !present.contains($0.fleetID) }
        guard !pool.isEmpty else { return nil }
        return weightedPick(pool.map { ($0.fleetID, $0.weight) },
                            roll: world.rng.int(in: 0...9999), world: world)
    }

    // MARK: Spawning

    private func spawnOne(into world: World, origin: SpawnOrigin) {
        // The ambient trickle is dudes only — the per-system `DudeTypes`/`%Prob`
        // background traffic (traders and lone patrols coming and going). Fleets
        // are a separate mechanism (FLEETS.md §0): they arrive as a group on the
        // dedicated `fleetTimer` cadence, drawn from the galaxy-wide `LinkSyst`
        // pool (`fleetPool`), never one-at-a-time here. Routing all fleets through
        // that one path keeps them from being double-spawned (once here, once on
        // the timer) and keeps the "traders wander / convoys jump in" split clean.
        let dudeWeight = table.dudes.reduce(0) { $0 + $1.prob }
        guard dudeWeight > 0 else { return }
        let dRoll = world.rng.int(in: 0...(dudeWeight - 1))
        if let did = weightedPick(table.dudes.map { ($0.dudeID, $0.prob) }, roll: dRoll, world: world) {
            spawnDude(did, into: world, origin: origin, leaderID: nil)
        }
    }

    // MARK: Galaxy-wide fleet pool

    /// The set of fleets that may spawn in this system, each with a selection
    /// weight, built once and cached. This is what fixes "you never see fleets":
    /// instead of only the fleets a `sÿst` explicitly pins in its `DudeTypes`
    /// table (nearly always none), it sweeps the whole `flët` catalog for any
    /// fleet whose `LinkSyst` band matches this system (FLEETS.md §3/§8
    /// interpretation B). `flët` carries no probability field, so swept fleets
    /// are uniform (weight 1); a fleet the system's own table *does* pin keeps
    /// its designer-set `%Prob` as its weight (min 1), so hand-placed fleets stay
    /// more common than the ambient galaxy-wide sweep. Union is by id, so a fleet
    /// that is both swept and pinned is counted once at its pinned weight. The
    /// `AppearOn` NCB gate is *not* applied here (it can change during a visit) —
    /// it's re-checked per draw in `fleetSpawnAllowed`.
    private func fleetPool(world: World) -> [(fleetID: Int, weight: Int)] {
        if let cached = linkFleetPool { return applyAppearOnGate(cached, world: world) }
        var weights: [Int: Int] = [:]
        for fleet in galaxy.fleetCatalog() where isFleetEligible(fleet, world: world) {
            weights[fleet.id] = 1
        }
        // The system's own explicitly-pinned fleets (negative-id `DudeTypes`
        // slots) keep their designer `%Prob` as weight, overriding the uniform 1.
        for entry in table.fleets where isFleetEligible(entry.fleetID, world: world) {
            weights[entry.fleetID] = max(weights[entry.fleetID] ?? 0, max(1, entry.prob))
        }
        let pool = weights.map { (fleetID: $0.key, weight: $0.value) }
            .sorted { $0.fleetID < $1.fleetID }   // stable order → deterministic weightedPick
        linkFleetPool = pool
        return applyAppearOnGate(pool, world: world)
    }

    /// Drop any fleet whose `AppearOn` NCB gate currently forbids it (Phase 2).
    /// Blank `AppearOn` ("if left blank it will be ignored", Bible) is always
    /// allowed; a non-blank one is a story/plugin control-bit test the engine
    /// can't evaluate itself, so it defers to the host's `World.fleetSpawnEligible`
    /// — whose default suppresses gated fleets, keeping e.g. rebel/late-campaign
    /// fleets out of a fresh galaxy until the story layer says otherwise.
    private func applyAppearOnGate(_ pool: [(fleetID: Int, weight: Int)],
                                   world: World) -> [(fleetID: Int, weight: Int)] {
        pool.filter { fleetAppearOnAllowed($0.fleetID, world: world) }
    }

    /// True if fleet `fleetID`'s `AppearOn` control-bit test currently permits it.
    /// Blank ⇒ always; non-blank ⇒ host-gated via `World.fleetSpawnEligible`.
    private func fleetAppearOnAllowed(_ fleetID: Int, world: World) -> Bool {
        guard let fleet = galaxy.game.fleet(fleetID) else { return false }
        if fleet.appearOn.isEmpty { return true }
        return world.fleetSpawnEligible(fleetID)
    }

    // MARK: LinkSyst eligibility

    /// `flët.LinkSyst`: which systems a fleet may spawn in (FLEETS.md §3 —
    /// Bible: "-1 Any system · 128-2175 ID of a specific system · 10000-10255
    /// Any system belonging to this specific government · 15000-15255 Any
    /// system belonging to an ally of this govt · 20000-20255 Any system
    /// belonging to any but this govt · 25000-25255 Any system belonging to
    /// an enemy of this govt"). Looks the fleet up by id first; missing data
    /// is not eligible (nothing to check).
    private func isFleetEligible(_ fleetID: Int, world: World) -> Bool {
        guard let fleet = galaxy.game.fleet(fleetID) else { return false }
        return isFleetEligible(fleet, world: world)
    }

    /// The government referenced by each banded `LinkSyst` range is *not*
    /// necessarily the fleet's own `Govt` — it's an independent government id
    /// encoded directly in the `LinkSyst` value (e.g. a pirate fleet can be
    /// flagged eligible for "systems hostile to the Federation" without the
    /// fleet itself belonging to the Federation). Ally/enemy tests reuse
    /// `Diplomacy.areAllied`/`.areEnemies` — no new relational logic, per
    /// FLEETS.md §3's own analysis.
    func isFleetEligible(_ fleet: FleetRes, world: World) -> Bool {
        systemMatchesLink(fleet.linkSystem, world: world)
    }

    /// Whether the current system satisfies an EV Nova banded `LinkSyst` value —
    /// shared by `flët.LinkSyst` (fleet spawn gating) and `përs.LinkSyst` (person
    /// spawn-location gating). Bands: -1 anywhere · 128-2175 a specific system ·
    /// 10000-10255 any system of a govt · 15000-15255 an ally's · 20000-20255 any
    /// but that govt · 25000-25255 an enemy's.
    ///
    /// The banded government ranges encode a government by its 0-based *index*;
    /// the system/diplomacy layer speaks resource ids (128+), so add
    /// `govtResourceBase` before comparing. (Getting this wrong silently made
    /// every govt-banded fleet ineligible — Federation is govt id 128, so
    /// `LinkSyst 10000` meant "index 0" i.e. id 128, but was compared to 0.)
    func systemMatchesLink(_ link: Int, world: World) -> Bool {
        switch link {
        case -1:
            return true
        case 128...2175:
            return link == table.systemID
        case 10000...10255:
            return table.systemGovt == (link - 10000) + govtResourceBase
        case 15000...15255:
            guard let dip = world.diplomacy else { return true }
            return dip.areAllied(table.systemGovt, (link - 15000) + govtResourceBase)
        case 20000...20255:
            return table.systemGovt != (link - 20000) + govtResourceBase
        case 25000...25255:
            guard let dip = world.diplomacy else { return true }
            return dip.areEnemies(table.systemGovt, (link - 25000) + govtResourceBase)
        default:
            // Outside the documented bands (or 0/blank on non-`flët` test
            // fixtures) — permissive default so it doesn't silently zero out
            // a fleet the system's own spawn table already explicitly lists.
            return true
        }
    }

    // MARK: Reactive reinforcement fleets (sÿst.ReinfFleet/ReinfTime/ReinfIntrval)

    /// The reactive half of FLEETS.md §5: `AIBrain.favorableOdds` already
    /// gates whether an individual ship picks a fight; this is the other
    /// half — when a government's ships already *in* this system are
    /// outnumbered and under attack, summon `table.reinforcementFleet` after
    /// its frame delay, then hold off retriggering until the regen window
    /// passes. One reinforcement can be in flight (triggered-but-not-yet-
    /// arrived) at a time per system, matching "a fleet jumps in as a unit."
    private func updateReinforcements(_ world: World) {
        guard table.reinforcementFleet >= 128 else { return }

        if let dueAt = reinforcementDueAt {
            guard simClock >= dueAt else { return }
            reinforcementDueAt = nil
            if isFleetEligible(table.reinforcementFleet, world: world),
               fleetAppearOnAllowed(table.reinforcementFleet, world: world) {
                spawnFleet(table.reinforcementFleet, into: world, origin: .edge)
            }
            reinforcementCooldownUntil = simClock
                + Double(max(0, table.reinforcementRegen)) * secondsPerReinforcementDay
            return
        }

        guard simClock >= reinforcementCooldownUntil,
              let fleet = galaxy.game.fleet(table.reinforcementFleet) else { return }
        // The reinforcement fleet's own government is who we're checking is
        // "outmatched" — falling back to the system's controlling government
        // when the fleet has none set, same fallback order `spawnFleet` uses.
        let reinforcementGovt = fleet.govt >= 128 ? fleet.govt : table.systemGovt
        guard governmentUnderAttackAndOutmatched(reinforcementGovt, world: world) else { return }

        let delaySeconds = Double(max(0, table.reinforcementDelay)) / max(1, galaxy.combatTuning.framesPerSecond)
        reinforcementDueAt = simClock + delaySeconds
        Log.world.debug("Spawner: reinforcement fleet \(self.table.reinforcementFleet) triggered for govt \(reinforcementGovt), arriving in \(delaySeconds, format: .fixed(precision: 1))s")
    }

    /// System-wide odds check for the reinforcement trigger: are `govt`'s
    /// ships (plus its allies) present in this system, currently being
    /// targeted by an enemy, and outmatched per that government's own
    /// `gövt.MaxOdds`? This mirrors the power formula `AIBrain.favorableOdds`
    /// uses (combat strength scaled 30%-100% by shield fraction) but at
    /// government/system granularity rather than one ship's personal
    /// go/no-go decision — a different question ("should the *system*
    /// summon backup") from AIBrain's ("should *I* personally engage"), so
    /// this doesn't reuse that method directly; see the assignment note on
    /// why no hook was added to `AIBrain.swift`.
    private func governmentUnderAttackAndOutmatched(_ govt: Int, world: World) -> Bool {
        guard govt >= 128, let dip = world.diplomacy, let gov = dip.govt(govt), gov.maxOdds > 0 else { return false }

        func isFriend(_ s: Ship) -> Bool { s.government == govt || dip.areAllied(govt, s.government) }
        func isFoe(_ s: Ship) -> Bool {
            s.isPlayer ? dip.isHostileToPlayer(govt) : dip.areEnemies(govt, s.government)
        }
        func power(_ s: Ship) -> Double { s.combatStrength * (0.3 + 0.7 * s.shieldFraction) }

        let living = world.allShips.filter { $0.isAlive && !$0.disabled }
        let friends = living.filter(isFriend)
        let foes = living.filter(isFoe)
        guard !friends.isEmpty, !foes.isEmpty else { return false }

        // "Under attack": at least one friendly ship is a foe's current
        // target — not just diplomatically hostile-capable presence.
        let friendUnderFire = friends.contains { friend in
            foes.contains { $0.currentTargetID == friend.entityID }
        }
        guard friendUnderFire else { return false }

        let friendlyStrength = friends.reduce(0.0) { $0 + power($1) }
        let enemyStrength = foes.reduce(0.0) { $0 + power($1) }
        guard friendlyStrength > 0 else { return true }
        let tolerated = friendlyStrength * (Double(gov.maxOdds) / 100.0)
        return enemyStrength > tolerated
    }

    private func weightedPick(_ entries: [(Int, Int)], roll: Int, world: World) -> Int? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return entries.first?.0 }
        var acc = 0
        let target = ((roll % total) + total) % total
        for e in entries { acc += e.1; if target < acc { return e.0 } }
        return entries.last?.0
    }

    /// Spawn a single dude's ship with an AI brain matching its disposition.
    @discardableResult
    private func spawnDude(_ dudeID: Int, into world: World, origin: SpawnOrigin,
                           leaderID: Int?) -> Ship? {
        guard let dude = galaxy.game.dude(dudeID) else { return nil }
        let roll = world.rng.int(in: 0...9999)
        guard let shipID = dude.pickShip(roll: roll) else { return nil }
        let govt = dude.govt >= 128 ? dude.govt : (galaxy.shipSpec(shipID)?.government ?? independentGovt)

        // A lone hyperspace arrival may instead emerge from one of the system's
        // hypergates — often for govts that prefer gate travel, rarely for the
        // rest (fleet escorts always stay with their leader, so only leaders/solo
        // dudes are redirected).
        var effectiveOrigin = origin
        if case .edge = origin, leaderID == nil,
           let gate = emergenceGate(for: govt, world: world) {
            effectiveOrigin = .hypergate(spobID: gate.id)
        }
        let (pos, ang, arrival) = spawnPose(world, origin: effectiveOrigin)
        // Equip NPCs from their real hull loadout (preinstalled outfits: afterburner,
        // extra shields/weapons, fuel) — the same aggregation the player uses — so a
        // spawned ship matches its authentic EV Nova fit, not a bare hull.
        guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: -1...1)) else { return nil }
        let brain = AIBrain(aiType: dude.aiType, govt: govt)
        brain.leaderID = leaderID
        // A trader that lifts off a spaceport is usually done here — most head
        // straight back out to hyperspace (a visible departure), the rest hop to
        // another port. Only solo dudes (not fleet escorts, who stay with their
        // leader) and only trader dispositions.
        if case .planet = effectiveOrigin, leaderID == nil, dude.aiType.isTrader,
           world.rng.double(in: 0...1) < 0.65 {
            brain.spawnOutbound = true
        }
        ship.brain = brain
        rollDudeCargo(dude, into: ship, world: world)
        // Bible: "When ships are created, there is a 5% chance that a specific
        // AI-person will also be created." Promote a matching hull to a named
        // përs (drives target name + ItemClass boarding loot).
        assignPersonIfLucky(to: ship, shipID: shipID, govt: govt, world: world)
        world.addNPC(ship, arrival: arrival)
        return ship
    }

    /// Fill `ship`'s hold with whatever commodities its `düde` class carries
    /// (`Booty`, Bible) — otherwise boarding loot is empty even for a full-size
    /// trader. The Bible names which goods a dude class carries but not how
    /// much; filling 30-80% of the hold, split evenly across the carried
    /// types, is this engine's reading.
    func rollDudeCargo(_ dude: DudeRes, into ship: Ship, world: World) {
        let commodities = dude.bootyCommodities
        guard !commodities.isEmpty, ship.cargoCapacity > 0 else { return }
        let total = Int(Double(ship.cargoCapacity) * world.rng.double(in: 0.3...0.8))
        guard total > 0 else { return }
        let perType = max(1, total / commodities.count)
        for commodity in commodities {
            ship.cargo[commodity.rawValue, default: 0] += perType
        }
    }

    /// Fill a freighter's hold with random standard trade goods — the flët
    /// `Flags` 0x0001 behavior ("Freighters in this fleet will have random cargo
    /// when boarded"). The Bible says *that* it happens, not how much; filling
    /// 30-90% of the hold across one or two of the six standard commodities
    /// (types 0-5, the same pool `CargoType == 1000` missions draw from) is this
    /// engine's reading, so a boarded convoy hauler yields a plausible haul.
    func rollRandomFreighterCargo(into ship: Ship, world: World) {
        guard ship.cargoCapacity > 0 else { return }
        let total = Int(Double(ship.cargoCapacity) * world.rng.double(in: 0.3...0.9))
        guard total > 0 else { return }
        let typeCount = world.rng.int(in: 1...2)
        let perType = max(1, total / typeCount)
        for _ in 0..<typeCount {
            let commodity = world.rng.int(in: 0...5)
            ship.cargo[commodity, default: 0] += perType
        }
    }

    /// 5% chance to tag `ship` as an eligible `përs` character flying this hull
    /// (same ship class + compatible government), avoiding one already in-system.
    private func assignPersonIfLucky(to ship: Ship, shipID: Int, govt: Int, world: World) {
        guard world.rng.int(in: 0...99) < 5 else { return }
        let candidates = galaxy.game.perses().filter { candidate in
            candidate.shipType == shipID && (candidate.govt == govt || candidate.govt == -1)
                && systemMatchesLink(candidate.linkSyst, world: world)   // LinkSyst spawn-location band
                && !world.npcs.contains { npc in npc.personID == candidate.id }
                && world.persSpawnEligible(candidate.id)   // ActiveOn NCB + not-yet-defeated
        }
        guard !candidates.isEmpty else { return }
        let pers = candidates[world.rng.int(in: 0...candidates.count - 1)]
        ship.personID = pers.id
        applyPersonCustomization(pers, to: ship, world: world)
    }

    /// Apply a `pêrs`'s ship customization: a shield-strength multiplier
    /// (`ShieldMod`, <0 = invincible), the credits it carries for plunder, and
    /// its `WeapType`/`WeapCount`/`AmmoLoad` weapon layering on top of the
    /// hull's stock fit.
    private func applyPersonCustomization(_ pers: PersRes, to ship: Ship, world: World) {
        if pers.shieldMod < 0 {
            ship.maxShield = 1_000_000; ship.shield = ship.maxShield   // "invincible"
        } else if pers.shieldMod > 0, pers.shieldMod != 100 {
            let scale = Double(pers.shieldMod) / 100.0
            ship.maxShield *= scale; ship.shield = ship.maxShield
        }
        if pers.credits > 0 {
            // Credits carried, ±25% (deterministic jitter from the RNG).
            let jitter = 0.75 + world.rng.double(in: 0...0.5)
            ship.plunderCredits = max(0, Int(Double(pers.credits) * jitter))
        }
        ship.brain?.personAggression = pers.aggression
        ship.brain?.personCoward = pers.coward
        applyPersonWeapons(pers, to: ship)
    }

    /// Layer a `pêrs`'s `WeapType`/`WeapCount`/`AmmoLoad[4]` onto the spawned
    /// hull's stock weapons. Per the Bible, a negative `WeapCount` *removes*
    /// that many stock copies of `WeapType` instead of adding them.
    func applyPersonWeapons(_ pers: PersRes, to ship: Ship) {
        for i in 0..<4 {
            let wtype = pers.weapType[i]
            let wcount = pers.weapCount[i]
            guard wtype > 0, wcount != 0 else { continue }
            if wcount > 0 {
                guard let spec = galaxy.weaponSpec(wtype) else { continue }
                let ammoLoad = pers.ammoLoad[i]
                if let existing = ship.weapons.first(where: { $0.spec.id == wtype }) {
                    existing.count += wcount
                    if ammoLoad > 0, existing.ammo >= 0 { existing.ammo += ammoLoad }
                } else {
                    ship.weapons.append(WeaponMount(spec: spec, ammo: ammoLoad > 0 ? ammoLoad : -1, count: wcount))
                }
            } else {
                var remaining = -wcount
                ship.weapons.removeAll { mount in
                    guard mount.spec.id == wtype, remaining > 0 else { return false }
                    if mount.count <= remaining {
                        remaining -= mount.count
                        return true
                    } else {
                        mount.count -= remaining
                        remaining = 0
                        return false
                    }
                }
            }
        }
    }

    /// Spawn a fleet: a lead ship plus its escorts, formed up on the leader. The
    /// leader flies to its own disposition (from the hull's inherent AI), and each
    /// escort takes a numbered formation slot so they hold a tidy wing.
    private func spawnFleet(_ fleetID: Int, into world: World, origin: SpawnOrigin) {
        guard let fleet = galaxy.game.fleet(fleetID) else { return }
        let govt = fleet.govt >= 128 ? fleet.govt
                 : (galaxy.shipSpec(fleet.leadShip)?.government ?? table.systemGovt)

        let (pos, ang, arrival) = spawnPose(world, origin: origin)
        guard let lead = galaxy.makeLoadedShip(fleet.leadShip, government: govt, at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: -1...1)) else { return }
        // The flagship acts on its own hull's disposition (a freighter convoy leader
        // trades; a warfleet's leader fights) rather than always being a warship.
        let leadAI = galaxy.game.ship(fleet.leadShip).map { AIType(raw: $0.inherentAI) } ?? .warship
        let leadBrain = AIBrain(aiType: leadAI == .unknown ? .warship : leadAI, govt: govt)
        leadBrain.isFleetMember = true
        leadBrain.fleetID = fleetID
        lead.brain = leadBrain
        // flët `Flags` 0x0001: freighters (InherentAI <= 2) in this fleet carry
        // random cargo, so boarding a convoy hauler actually yields loot.
        if fleet.freightersHaveRandomCargo, let ai = galaxy.game.ship(fleet.leadShip)?.inherentAI, ai <= 2 {
            rollRandomFreighterCargo(into: lead, world: world)
        }
        let leadID = world.addNPC(lead, arrival: arrival)

        var slot = 0
        for escort in fleet.escorts {
            let count = escort.min == escort.max ? escort.min
                      : world.rng.int(in: escort.min...max(escort.min, escort.max))
            for _ in 0..<max(0, count) {
                guard world.npcs.count < maxPopulation else { return }
                let offset = Vec2(world.rng.double(in: -120...120), world.rng.double(in: -120...120))
                guard let e = galaxy.makeLoadedShip(escort.shipID, government: govt,
                                                    at: pos + offset, angle: ang,
                                                    skillRoll: world.rng.double(in: -1...1)) else { continue }
                // Escorts fly their own hull's disposition so that, if the flagship
                // dies, they fall back to hull-appropriate behavior rather than
                // always reverting to a generic interceptor.
                let escortAI = galaxy.game.ship(escort.shipID).map { AIType(raw: $0.inherentAI) } ?? .interceptor
                let brain = AIBrain(aiType: escortAI == .unknown ? .interceptor : escortAI, govt: govt)
                brain.leaderID = leadID
                brain.formationSlot = slot
                brain.isFleetMember = true
                brain.fleetID = fleetID
                e.brain = brain
                if fleet.freightersHaveRandomCargo, let ai = galaxy.game.ship(escort.shipID)?.inherentAI, ai <= 2 {
                    rollRandomFreighterCargo(into: e, world: world)
                }
                world.addNPC(e, arrival: arrival)
                slot += 1
            }
        }
    }

    /// A spawn position, facing, and the arrival effect it should trigger. Edge
    /// spawns jump in on a random bearing pointed inward; interior (initial fill)
    /// spawns scatter mid-system with no effect; planet spawns lift off a landable
    /// stellar object, facing outward.
    /// A hypergate in the current system this govt's ship may emerge from this
    /// spawn, or nil to arrive from the edge as usual. Govts flagged "prefer
    /// hypergates" emerge fairly often; everyone else only occasionally, so the
    /// player still sees the odd ship materialise from a gate. Govts flagged
    /// "don't use hypergates" never do. Prefers a gate the govt owns, else any
    /// gate present (stock gates all belong to the neutral "Hypergate" govt).
    private func emergenceGate(for govt: Int, world: World) -> StellarBody? {
        let gates = world.systemContext.bodies.filter { $0.isHypergate }
        guard !gates.isEmpty else { return nil }
        guard let g = galaxy.game.govt(govt), !g.avoidsHypergates else { return nil }
        let chancePercent = g.prefersHypergates ? 35 : 4
        guard world.rng.int(in: 0...99) < chancePercent else { return nil }
        let owned = gates.filter { $0.government == govt }
        let pool = owned.isEmpty ? gates : owned
        return pool[world.rng.int(in: 0...(pool.count - 1))]
    }

    private func spawnPose(_ world: World, origin: SpawnOrigin) -> (Vec2, Double, World.ArrivalMode) {
        let ctx = world.systemContext
        switch origin {
        case let .hypergate(spobID):
            // Emerge just clear of the gate along its emerge heading (a random
            // direction if the gate defines none). If the gate has since vanished
            // from the system geometry, fall back to an ordinary edge arrival.
            if let gate = ctx.bodies.first(where: { $0.id == spobID }) {
                let ang = gate.gateEmergeAngle ?? world.rng.double(in: 0...(2 * .pi))
                let pos = gate.position + Vec2(sin(ang), cos(ang)) * (gate.radius + 30)
                return (pos, ang, .gate(spobID: spobID))
            }
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * ctx.spawnRadius
            return (pos, (ctx.center - pos).angle, .hyperspace)
        case .planet:
            // `canLand` already means landable AND inhabited (see `StellarBody`'s
            // doc comment) — a system with no such body has nowhere to launch a
            // ship from, so fall through to an edge/hyperspace arrival instead
            // of lifting off an uninhabited rock.
            let pads = ctx.bodies.filter { $0.canLand }
            if !pads.isEmpty {
                let pad = pads[world.rng.int(in: 0...(pads.count - 1))]
                let outward = (pad.position - ctx.center)
                let ang = (outward.length < 1 ? Vec2(0, 1) : outward).angle
                return (pad.position, ang, .launch)
            }
            fallthrough
        case .edge:
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * ctx.spawnRadius
            return (pos, (ctx.center - pos).angle, .hyperspace)
        case .interior:
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let r = world.rng.double(in: 300...(ctx.jumpRadius * 0.6))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * r
            return (pos, (ctx.center - pos).angle, .populate)
        }
    }
}
