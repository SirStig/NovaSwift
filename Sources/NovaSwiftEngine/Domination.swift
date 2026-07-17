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

        // An active contest: the per-frame trickle keeps the field topped up as
        // defenders fall.
        if var defense = stellarDefenses[spobID] {
            let aliveDefenders = liveDefenders(of: spobID)
            if defense.poolRemaining == 0 && aliveDefenders == 0 {
                // Defenses broken — the planet yields. A disabled defender no
                // longer counts as "up" (see `liveDefenders`), so a field of
                // disabled hulks with the pool spent surrenders too, rather than
                // making the player hunt the hulks down.
                stellarDefenses[spobID] = nil
                dominatedStellars.insert(spobID)
                emit(.stellarDominated(spobID: spobID))
                return .dominated
            }
            // Still contesting. Top up now so a re-demand at a thin moment doesn't
            // wait a frame for the trickle tick, then report the fight is ongoing.
            _ = topUpDefenders(&defense, spob: spob)
            stellarDefenses[spobID] = defense
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
        let n = topUpDefenders(&defense, spob: spob)
        // Only the opening scramble announces on the HUD; the silent trickle that
        // replaces losses does not, so a long fight doesn't spam a line per ship.
        if n > 0 {
            emit(.stellarDefendersLaunched(spobID: spobID, count: n, remainingPool: defense.poolRemaining))
        }
        stellarDefenses[spobID] = defense
        return .defending(launched: n)
    }

    /// Number of a stellar's defense ships still up and fighting in the system —
    /// alive and not disabled. Public so the app can show "defenders remaining"
    /// while a tribute fight is on. A *disabled* defender counts as down (like a
    /// destroyed one): it frees a slot for a replacement and no longer blocks the
    /// planet's surrender, so the player never has to chase disabled hulks around.
    public func liveDefenders(of spobID: Int) -> Int {
        npcs.reduce(0) { $0 + (($1.spobDefenderOf == spobID && $1.isAlive && !$1.disabled) ? 1 : 0) }
    }

    /// Per-frame upkeep for active tribute contests: keep each planet's field
    /// topped up to its concurrent `waveSize`, launching one replacement for every
    /// defender that has fallen (destroyed or disabled) since last frame, until the
    /// pool is spent — a continuous trickle, not a wave that only refills once the
    /// field is empty. Called from `step`.
    func updateStellarDefenses() {
        guard !stellarDefenses.isEmpty else { return }
        for (spobID, var defense) in stellarDefenses {
            guard defense.poolRemaining > 0, let spob = galaxy?.game.spob(spobID) else { continue }
            if topUpDefenders(&defense, spob: spob) > 0 {
                stellarDefenses[spobID] = defense
            }
        }
    }

    /// Bring the live (up-and-fighting) defender count back up to the concurrent
    /// target (`waveSize`) by scrambling replacements from the remaining pool — one
    /// per open slot, so each destroyed or disabled defender draws exactly one
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
        return launched.count
    }
}
