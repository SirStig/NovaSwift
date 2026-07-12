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
    let waveSize: Int
    /// Defenders not yet launched. Waves peel off this until it hits zero; once
    /// it's zero and no defenders remain alive, the next demand wins.
    var poolRemaining: Int
}

// EV Nova's planetary domination ("Demand Tribute"). The player targets a
// stellar and demands tribute; a governed planet with a defense fleet answers
// with force, launching `DefenseDude` ships in waves until its `DefCount` pool
// is spent. Destroy them all and demand again, and the planet surrenders — it's
// dominated and pays `Tribute` credits per day thereafter (the day clock, in
// NovaSwiftStory, does the paying). A combat-rating gate (an engine addition on
// top of the stock defeat-the-fleet gate) lets a weak player be laughed off
// before a fight even starts. See docs/reverse-engineering/DOMINATION.md.
extension World {

    /// The combat rating a tribute demand on `spob` requires before the planet
    /// takes it seriously — scaled by how many defenders it fields. 0 when the
    /// rating gate is disabled (`tributeRatingPerDefender == 0`).
    public func tributeRatingRequired(for spob: SpobRes) -> Int {
        spob.defenseTotal * max(0, tributeRatingPerDefender)
    }

    /// Demand tribute from stellar `spobID`. Drives the whole domination flow:
    /// refuses (with a reason) if the planet can't or won't submit, launches a
    /// defense wave if it fights back, reports the fight is ongoing if it's
    /// already defending, or dominates the planet once its defenders are broken.
    /// The player must be in the same system as the stellar (the world is
    /// single-system); pass the id of a stellar present in `systemContext`.
    @discardableResult
    public func demandTribute(spobID: Int) -> TributeOutcome {
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
        // No defense fleet → nothing to break, so it can't be forced to submit.
        guard spob.hasDefenseFleet else {
            emit(.tributeRefused(spobID: spobID, reason: .noDefenseFleet))
            return .refused(.noDefenseFleet)
        }

        // An active contest: relaunch has been topping up waves as they die.
        if var defense = stellarDefenses[spobID] {
            let aliveDefenders = liveDefenders(of: spobID)
            if defense.poolRemaining == 0 && aliveDefenders == 0 {
                // Defenses broken — the planet yields.
                stellarDefenses[spobID] = nil
                dominatedStellars.insert(spobID)
                emit(.stellarDominated(spobID: spobID))
                return .dominated
            }
            // Still defenders in play (alive, or a wave yet to launch). If the
            // field happens to be clear this instant, launch the next wave now
            // rather than make the player wait a frame for the relaunch tick.
            if aliveDefenders == 0, defense.poolRemaining > 0 {
                let n = launchDefenseWave(&defense, spob: spob)
                stellarDefenses[spobID] = defense
                return .defending(launched: n)
            }
            return .stillDefending
        }

        // First demand on this planet. Combat-rating gate first: a weak player is
        // laughed off before any shots are fired.
        let required = tributeRatingRequired(for: spob)
        if required > 0, playerCombatRating < required {
            emit(.tributeRefused(spobID: spobID, reason: .combatRatingTooLow(required: required)))
            return .refused(.combatRatingTooLow(required: required))
        }

        // Open the contest and scramble the first wave.
        let govt = spob.government >= 128 ? spob.government
                 : (galaxy.game.dude(spob.defenseDude)?.govt ?? independentGovt)
        var defense = StellarDefense(spobID: spobID, dudeID: spob.defenseDude, govt: govt,
                                     waveSize: spob.defenseWaveSize, poolRemaining: spob.defenseTotal)
        let n = launchDefenseWave(&defense, spob: spob)
        stellarDefenses[spobID] = defense
        return .defending(launched: n)
    }

    /// Number of a stellar's defense ships still alive in the system. Public so
    /// the app can show "defenders remaining" while a tribute fight is on.
    public func liveDefenders(of spobID: Int) -> Int {
        npcs.reduce(0) { $0 + (($1.spobDefenderOf == spobID && $1.isAlive) ? 1 : 0) }
    }

    /// Per-frame upkeep for active tribute contests: as a planet's current wave
    /// is wiped out, scramble the next one from its remaining pool, until the
    /// pool is spent. Called from `step`.
    func updateStellarDefenses() {
        guard !stellarDefenses.isEmpty else { return }
        for (spobID, var defense) in stellarDefenses {
            guard defense.poolRemaining > 0 else { continue }
            if liveDefenders(of: spobID) == 0, let spob = galaxy?.game.spob(spobID) {
                _ = launchDefenseWave(&defense, spob: spob)
                stellarDefenses[spobID] = defense
            }
        }
    }

    /// Launch one wave (up to `waveSize`) of `defense`'s defenders from the
    /// planet, tagged to it and set to attack the player. Decrements the pool and
    /// emits `stellarDefendersLaunched`. Returns how many actually launched.
    private func launchDefenseWave(_ defense: inout StellarDefense, spob: SpobRes) -> Int {
        guard let galaxy = galaxy, let dude = galaxy.game.dude(defense.dudeID),
              defense.poolRemaining > 0 else { return 0 }
        let want = min(defense.waveSize, defense.poolRemaining)
        // Launch from the planet's own position if we have its geometry, else the
        // system centre.
        let origin = systemContext.bodies.first { $0.id == defense.spobID }?.position ?? systemContext.center
        var launched: [Int] = []
        for _ in 0..<want {
            let roll = rng.int(in: 0...9999)
            guard let shipID = dude.pickShip(roll: roll) else { continue }
            let jitter = Vec2(rng.double(in: -60...60), rng.double(in: -60...60))
            let ang = rng.double(in: 0...(2 * .pi))
            guard let ship = galaxy.makeLoadedShip(shipID, government: defense.govt,
                                                   at: origin + jitter, angle: ang,
                                                   skillRoll: rng.double(in: -1...1)) else { continue }
            let brain = AIBrain(aiType: dude.aiType == .unknown ? .warship : dude.aiType, govt: defense.govt)
            brain.behaviorOverride = .attackPlayer   // defenders exist to repel the player
            ship.brain = brain
            ship.spobDefenderOf = defense.spobID
            launched.append(addNPC(ship, arrival: .launch))
        }
        defense.poolRemaining -= launched.count
        if !launched.isEmpty {
            emit(.stellarDefendersLaunched(spobID: defense.spobID, count: launched.count,
                                                    remainingPool: defense.poolRemaining))
        }
        return launched.count
    }
}
