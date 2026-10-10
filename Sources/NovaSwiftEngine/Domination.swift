import Foundation
import NovaSwiftKit

/// Live state of one stellar's Demand-Tribute defense (`spöb.DefenseDude`/
/// `DefCount`). Created when the player first demands tribute from a defended
/// planet and torn down when the planet surrenders (or the world is rebuilt on
/// leaving the system).
struct StellarDefense {
    let spobID: Int
    let dudeID: Int
    let govt: Int
    /// Max defenders in the field at once (`spöb.DefCount` wave size). Not a
    /// batch that only refills once wiped out — the target concurrent count the
    /// planet keeps topped up, launching one replacement per defender lost.
    let waveSize: Int
    /// Defenders not yet launched. Replacements peel off this one at a time as
    /// defenders fall; once it's zero and no defenders remain up, the next demand
    /// wins.
    var poolRemaining: Int
}

// EV Nova's planetary domination ("Demand Tribute"), from the stellar comm
// window (0x00480030, EC-16). Every demand is a crime against the stellar's
// government; below a combat rating of 12,800 the demand is laughed off. A
// stellar with nothing left to fight — no garrison and no defender up —
// submits to the first demand made in a comm window; otherwise it launches its
// `DefenseDude` defenders until its `DefCount` pool is spent. Once dominated it
// pays `Tribute` credits per day (the day clock, in NovaSwiftStory, does the
// paying). See docs/reverse-engineering/DOMINATION.md.
extension World {

    /// The combat rating below which a stellar laughs off a tribute demand
    /// (`0x3200`, a flat gate in the original).
    public static let tributeCombatRating = 12_800

    /// The combat rating a tribute demand on `spob` requires.
    public func tributeRatingRequired(for spob: SpobRes) -> Int { Self.tributeCombatRating }

    /// Demand tribute from stellar `spobID`. `firstPressInWindow` is whether
    /// this is the first Demand Tribute press since the comm window opened —
    /// only that press can win a stellar with nothing left to fight.
    ///
    /// Every demand fires the stellar government's kill penalty once, after
    /// first dropping a record that still meets `MinStatus` to `MinStatus − 1`;
    /// a demand that dominates or opens the defence fires it five more times.
    /// The player must be in the same system as the stellar (the world is
    /// single-system); pass the id of a stellar present in `systemContext`.
    @discardableResult
    public func demandTribute(spobID: Int, firstPressInWindow: Bool = true) -> TributeOutcome {
        // Already ours.
        if dominatedStellars.contains(spobID) {
            emit(.tributeRefused(spobID: spobID, reason: .alreadyDominated))
            return .refused(.alreadyDominated)
        }
        // Must be a real, in-system stellar we have data for.
        guard let galaxy = galaxy, let spob = galaxy.game.spob(spobID),
              systemContext.bodies.contains(where: { $0.id == spobID }) else {
            emit(.tributeRefused(spobID: spobID, reason: .notDominatable))
            return .refused(.notDominatable)
        }
        if spob.startsDominated {
            // Flagged always-dominated: treat a demand as an immediate win.
            dominatedStellars.insert(spobID)
            emit(.stellarDominated(spobID: spobID))
            return .dominated
        }

        applyTributeCrime(spob, floods: 1, lowerToMinStatus: true)
        if playerCombatRating < Self.tributeCombatRating {
            emit(.tributeRefused(spobID: spobID, reason: .combatRatingTooLow(required: Self.tributeCombatRating)))
            Log.world.notice("\(LogTag.spob(id: spobID, name: spob.name)) tribute refused — combat rating \(self.playerCombatRating) below \(Self.tributeCombatRating)")
            return .refused(.combatRatingTooLow(required: Self.tributeCombatRating))
        }

        let garrison = stellarDefenses[spobID]?.poolRemaining
            ?? stellarGarrisons[spobID] ?? (spob.hasDefenseFleet ? spob.defenseTotal : 0)
        let mounted = liveDefenders(of: spobID) > 0
        if firstPressInWindow, garrison < 1, !mounted {
            applyTributeCrime(spob, floods: 5, lowerToMinStatus: false)
            stellarDefenses[spobID] = nil
            stellarGarrisons[spobID] = 0
            touchedGarrisons.insert(spobID)
            dominatedStellars.insert(spobID)
            emit(.stellarDominated(spobID: spobID))
            Log.world.notice("\(LogTag.spob(id: spobID, name: spob.name)) dominated — nothing left to defend it")
            return .dominated
        }

        // An active contest: the per-frame trickle keeps the field topped up as
        // defenders fall.
        if var defense = stellarDefenses[spobID] {
            _ = topUpDefenders(&defense, spob: spob)
            stellarDefenses[spobID] = defense
            return .stillDefending
        }
        guard spob.hasDefenseFleet else { return .stillDefending }

        // Open the contest and scramble the first wave.
        applyTributeCrime(spob, floods: 5, lowerToMinStatus: false)
        let govt = spob.government >= 128 ? spob.government
                 : (galaxy.game.dude(spob.defenseDude)?.govt ?? independentGovt)
        var defense = StellarDefense(spobID: spobID, dudeID: spob.defenseDude, govt: govt,
                                     waveSize: spob.defenseWaveSize, poolRemaining: garrison)
        let n = topUpDefenders(&defense, spob: spob)
        // Only the opening scramble announces on the HUD; the silent trickle that
        // replaces losses does not, so a long fight doesn't spam a line per ship.
        if n > 0 {
            emit(.stellarDefendersLaunched(spobID: spobID, count: n, remainingPool: defense.poolRemaining))
        }
        stellarDefenses[spobID] = defense
        Log.world.notice("\(LogTag.spob(id: spobID, name: spob.name)) tribute demand opened — \(n) defenders launched, pool \(defense.poolRemaining)")
        return .defending(launched: n)
    }

    /// Releasing a dominated stellar (EC-16): it stops paying tribute and its
    /// garrison is reseeded; a record that still meets `MinStatus` drops to
    /// `MinStatus − 1`. The host runs `OnRelease`.
    public func releaseStellar(spobID: Int) {
        dominatedStellars.remove(spobID)
        stellarDefenses[spobID] = nil
        stellarGarrisons[spobID] = nil   // reseeded: a full DefCount again
        touchedGarrisons.insert(spobID)
        if let spob = galaxy?.game.spob(spobID) {
            applyTributeCrime(spob, floods: 0, lowerToMinStatus: true)
        }
    }

    /// The demand's cost in standing (0x00480030): the player's reputation in
    /// this system drops to `MinStatus − 1` if it still meets `MinStatus`,
    /// then faction event 3 (a kill, `KillPenalty`) against the stellar's
    /// government floods from this system (EC-02) `floods` times.
    func applyTributeCrime(_ spob: SpobRes, floods: Int, lowerToMinStatus: Bool) {
        guard let diplomacy else { return }
        // An ungoverned stellar floods as an independent victim, as the
        // original passes its −1 straight through.
        let victim = spob.government >= govtResourceBase ? spob.government : independentGovt
        if lowerToMinStatus {
            diplomacy.lowerReputationHere(belowMinStatus: spob.minStatus)
        }
        for _ in 0..<floods {
            diplomacy.recordCrime(.kill, against: victim)
        }
    }

    /// Dev-tools shortcut: grants domination of `spobID` instantly, skipping the
    /// defense-wave fight `demandTribute` normally requires. Drives the exact
    /// same success outcome a real win reaches — inserts into `dominatedStellars`
    /// and emits `.stellarDominated` — so tribute income, `PlayerState`
    /// persistence, and UI all stay consistent with an actual conquest rather
    /// than needing a separate "fake owned" flag. A no-op for an already-
    /// dominated or unrecognized stellar.
    public func debugForceDominate(spobID: Int) {
        guard !dominatedStellars.contains(spobID),
              let galaxy, galaxy.game.spob(spobID) != nil,
              systemContext.bodies.contains(where: { $0.id == spobID }) else { return }
        stellarDefenses[spobID] = nil
        dominatedStellars.insert(spobID)
        emit(.stellarDominated(spobID: spobID))
    }

    /// AI-15: every garrison this visit changed, for the host to merge into
    /// the save — the ships still in each pool plus the defenders still alive
    /// in the field (survivors return to the garrison; the dead are lost).
    /// nil = reseeded to a full `DefCount` (a release).
    public func garrisonSnapshot() -> [Int: Int?] {
        var out: [Int: Int?] = [:]
        for spobID in touchedGarrisons { out[spobID] = stellarGarrisons[spobID] }
        for (spobID, defense) in stellarDefenses {
            let alive = npcs.reduce(0) { $0 + (($1.spobDefenderOf == spobID && $1.isAlive) ? 1 : 0) }
            out[spobID] = defense.poolRemaining + alive
        }
        return out
    }

    /// Number of a stellar's defense ships still in the system. Public so the
    /// app can show "defenders remaining" while a tribute fight is on. AI-15:
    /// the original counts every active ship slot tagged to the stellar
    /// (`System_TickNpcSpawnMaintenance` 0x0041d6e0), so a *disabled* defender
    /// still holds its place in the wave quota and still blocks the surrender —
    /// only destroying (or boarding away) a hulk frees its slot.
    public func liveDefenders(of spobID: Int) -> Int {
        npcs.reduce(0) { $0 + (($1.spobDefenderOf == spobID && $1.isAlive) ? 1 : 0) }
    }

    /// Per-frame upkeep for active tribute contests: keep each planet's field
    /// topped up to its concurrent `waveSize`, launching one replacement for every
    /// defender that has been destroyed since last frame, until the
    /// pool is spent — a continuous trickle, not a wave that only refills once the
    /// field is empty. Called from `step`.
    func updateStellarDefenses() {
        guard !stellarDefenses.isEmpty else { return }
        // AI-15: the maintenance tick (0x0041d6e0) launches at most one
        // defender per raw call, from the first stellar short of its wave.
        var budget = rawCallsThisStep
        for spobID in stellarDefenses.keys.sorted() where budget > 0 {
            guard var defense = stellarDefenses[spobID], defense.poolRemaining > 0,
                  let spob = galaxy?.game.spob(spobID) else { continue }
            let deficit = defense.waveSize - liveDefenders(of: defense.spobID)
            guard deficit > 0 else { continue }
            let launched = launchDefenders(&defense, spob: spob, count: min(deficit, budget))
            if launched > 0 {
                budget -= launched
                stellarDefenses[spobID] = defense
            }
        }
    }

    /// Bring the live (up-and-fighting) defender count back up to the concurrent
    /// target (`waveSize`) by scrambling replacements from the remaining pool — one
    /// per open slot, so each destroyed defender draws exactly one
    /// fresh ship. Returns how many launched this call.
    @discardableResult
    private func topUpDefenders(_ defense: inout StellarDefense, spob: SpobRes) -> Int {
        let deficit = defense.waveSize - liveDefenders(of: defense.spobID)
        guard deficit > 0, defense.poolRemaining > 0 else { return 0 }
        return launchDefenders(&defense, spob: spob, count: min(deficit, defense.poolRemaining))
    }

    /// Launch exactly `count` defenders (capped by the pool) from the planet,
    /// tagged to it and set to attack the player. Decrements the pool and returns
    /// how many actually launched. Emitting the `stellarDefendersLaunched` HUD
    /// notice is the caller's job — only the opening scramble announces.
    private func launchDefenders(_ defense: inout StellarDefense, spob: SpobRes, count: Int) -> Int {
        guard let galaxy = galaxy, let dude = galaxy.game.dude(defense.dudeID),
              defense.poolRemaining > 0, count > 0 else { return 0 }
        let want = min(count, defense.poolRemaining)
        // Launch from the planet's own position if we have its geometry, else the
        // system centre.
        // AI-15 (`Stellar_SpawnDefenseFleetShip` 0x00421fd0): exactly on the
        // stellar, flying a warship's AI whatever the dude says, leaving at full
        // speed on a random heading, hostile to the player.
        let origin = systemContext.bodies.first { $0.id == defense.spobID }?.position ?? systemContext.center
        var launched: [Int] = []
        for _ in 0..<want {
            let roll = rng.int(in: 0...9999)
            guard let shipID = dude.pickShip(roll: roll) else { continue }
            let ang = Double(rng.range(360)) * .pi / 180
            guard let ship = galaxy.makeLoadedShip(shipID, government: defense.govt,
                                                   at: origin, angle: ang,
                                                   skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &rng),
                                                   includeDefaultItems: false, defaultItemCapabilities: true) else { continue }
            ship.velocity = Vec2(sin(ang), cos(ang)) * ship.stats.maxSpeed
            ship.throttleSpeed = ship.stats.maxSpeed
            let brain = AIBrain(aiType: .warship, govt: defense.govt)
            brain.behaviorOverride = .attackPlayer   // defenders exist to repel the player
            ship.brain = brain
            ship.spobDefenderOf = defense.spobID
            ship.dudeID = defense.dudeID
            launched.append(addNPC(ship, arrival: .launch))
        }
        defense.poolRemaining -= launched.count
        return launched.count
    }
}
