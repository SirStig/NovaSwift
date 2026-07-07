import Foundation
import EVNovaKit

/// The special "government" id used for the player and for truly independent
/// ships (EV Nova uses −1 for independent). Independent ships are hostile to no
/// one by default and are only fought if provoked.
public let independentGovt = -1

/// Resolves who fights whom, exactly the way EV Nova's `gövt` relations work:
/// governments carry *class* memberships plus lists of ally/enemy classes, and
/// two governments are enemies when one's enemy-classes intersect the other's
/// classes. Xenophobes attack anyone who isn't an ally. The player is tracked
/// separately through a per-government legal record.
public final class Diplomacy {
    /// government id → decoded record.
    public private(set) var govts: [Int: GovtRes]
    /// Player's standing with each government (negative = criminal there).
    public private(set) var playerRecord: [Int: Int] = [:]
    /// Record at or below which a government turns on the player.
    public var hostileThreshold = -1

    public init(govts: [GovtRes]) {
        self.govts = Dictionary(uniqueKeysWithValues: govts.map { ($0.id, $0) })
    }

    public func govt(_ id: Int) -> GovtRes? { govts[id] }

    // MARK: Government ↔ government

    /// Does government `a` consider `b` an enemy? Directional (mirrors the data),
    /// but combat should treat a pair as enemies if *either* side does — see
    /// `areEnemies`.
    public func considersHostile(_ a: Int, toward b: Int) -> Bool {
        guard a != b else { return false }
        guard let ga = govts[a] else { return false }        // independent / unknown: peaceful
        let bClasses = govts[b]?.classes ?? []
        if !Set(ga.enemies).isDisjoint(with: bClasses) { return true }
        if ga.xenophobic {                                    // attacks all non-allies
            let allied = !Set(ga.allies).isDisjoint(with: bClasses)
            return !allied
        }
        return false
    }

    /// Symmetric hostility: fights break out if either government is hostile.
    public func areEnemies(_ a: Int, _ b: Int) -> Bool {
        considersHostile(a, toward: b) || considersHostile(b, toward: a)
    }

    /// Are these governments explicitly allied (one lists the other's class)?
    public func areAllied(_ a: Int, _ b: Int) -> Bool {
        if a == b { return true }
        let bClasses = govts[b]?.classes ?? []
        let aClasses = govts[a]?.classes ?? []
        if let ga = govts[a], !Set(ga.allies).isDisjoint(with: bClasses) { return true }
        if let gb = govts[b], !Set(gb.allies).isDisjoint(with: aClasses) { return true }
        return false
    }

    // MARK: Government ↔ player

    public func isCriminal(with govt: Int) -> Bool {
        (playerRecord[govt] ?? 0) <= hostileThreshold
    }

    /// Does government `g` want to attack the player right now?
    public func isHostileToPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g] else { return false }
        if gov.neverAttacksPlayer { return false }
        if gov.alwaysAttacksPlayer { return true }
        if gov.xenophobic { return true }
        if gov.nosy && isCriminal(with: g) { return true }
        return isCriminal(with: g)
    }

    /// Apply a legal-record change to a government (e.g. the player fired on one
    /// of its ships). Also propagates a smaller hit to explicit allies.
    public func recordCrime(against govt: Int, penalty: Int) {
        playerRecord[govt, default: 0] -= penalty
        for (id, other) in govts where id != govt {
            if !Set(other.classes).isDisjoint(with: govts[govt]?.allies ?? []) {
                playerRecord[id, default: 0] -= penalty / 2
            }
        }
    }
}
