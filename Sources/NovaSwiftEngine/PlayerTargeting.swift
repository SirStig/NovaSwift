import Foundation

/// The original's player target commands (UI-07): the ship-target cycle
/// (`Ship_FindNextPlayerCycleTarget` 0x00461bd0 and its previous twin
/// 0x00461f60) and the two "nearest" scans (0x00462bd0 hostile, 0x00462850
/// engaged). None of them has a range limit.
///
/// The cycle walks ships in slot order. NovaSwift has no slot table; `npcs` is
/// kept in spawn order, which is the order the original's slots fill in a
/// fresh system (a freed slot being reused by a later ship is not modelled).
/// The port's nearest-first, wrapping, range-capped cycle survives as the
/// `nearestFirstTargeting` enhancement, driven by the app.
extension World {

    /// Whether `ship` belongs to the player's squad for cycling: led by the
    /// player, or by a ship the player leads (a fighter off an escort carrier).
    public func isInPlayerSquad(_ ship: Ship) -> Bool {
        guard let leader = ship.brain?.leaderID else { return false }
        if leader == Self.playerEntityID { return true }
        return self.ship(id: leader)?.brain?.leaderID == Self.playerEntityID
    }

    /// The ships the cycle may stop on, in slot (spawn) order. Plain cycling
    /// takes every ship outside the squad; `squad` takes only the squad. The
    /// two halves never mix.
    public func playerCycleCandidates(squad: Bool) -> [Ship] {
        npcs.filter { npc in
            npc.isAlive && canTarget(npc, by: player) && isInPlayerSquad(npc) == squad
        }
    }

    /// Step the ship target one place along the cycle. Past the last eligible
    /// ship (or before the first, going back) it clears to "No Target"; the next
    /// press starts over from the start. Returns the new target, if any.
    @discardableResult
    public func cyclePlayerTarget(forward: Bool = true, squad: Bool = false) -> Ship? {
        let order = playerCycleCandidates(squad: squad)
        let next: Ship?
        if let current = player.currentTargetID, let at = npcs.firstIndex(where: { $0.entityID == current }) {
            // Resume from the current ship's slot even when it is no longer a
            // candidate (it cloaked, or the modifier changed).
            let slots = order.compactMap { s in npcs.firstIndex { $0 === s }.map { (s, $0) } }
            next = forward ? slots.first { $0.1 > at }?.0 : slots.last { $0.1 < at }?.0
        } else {
            next = forward ? order.first : order.last
        }
        guard let next else {
            player.currentTargetID = nil
            return nil
        }
        return selectTarget(id: next.entityID)
    }

    /// Whether `npc` is coming after the player's squad —
    /// `Ship_IsThreatToPlayerSquad` 0x0040f6d0: active, not disabled, its
    /// maneuver timer run out, not in a disengaged AI state, and targeting
    /// the player or a ship the player leads.
    public func isThreatToPlayerSquad(_ npc: Ship) -> Bool {
        originalAI.isThreatToPlayerSquad(npc, world: self)
    }

    /// `Ship_IsAnyShipThreatToPlayerSquad` 0x00410060.
    public var isAnyShipThreatToPlayerSquad: Bool {
        npcs.contains { $0.isAlive && isThreatToPlayerSquad($0) }
    }

    /// How the IFF and the target reticle class a ship.
    public enum IFFClass: Equatable, Sendable { case disabled, threat, squad, other }

    /// The radar IFF class of `npc` — `Ship_GetShipRadarColor` 0x00465f00:
    /// disabled grey, then a threat to the squad red, then the squad green
    /// (led by the player and not a defense-fleet ship, or led by a ship the
    /// player leads), everything else blue. Government plays no part.
    public func radarIFFClass(of npc: Ship) -> IFFClass {
        if npc.disabled { return .disabled }
        if isThreatToPlayerSquad(npc) { return .threat }
        return isSquadForIFF(npc) ? .squad : .other
    }

    /// The target reticle's frame set (`NovaUi_UpdateShipTargetReticle`
    /// 0x0042ede0): disabled (frames 12–15), the squad (8–11), a threat
    /// (0–3), else 4–7 — the squad is tested before the threat here.
    public func reticleClass(of npc: Ship) -> IFFClass {
        if npc.disabled { return .disabled }
        if isSquadForIFF(npc) { return .squad }
        return isThreatToPlayerSquad(npc) ? .threat : .other
    }

    private func isSquadForIFF(_ npc: Ship) -> Bool {
        guard let leader = npc.brain?.leaderID else { return false }
        if leader == Self.playerEntityID { return originalAI.record(for: npc.entityID)?.defenseHome == nil }
        return ship(id: leader)?.brain?.leaderID == Self.playerEntityID
    }

    /// R: the nearest ship threatening the player's squad, not disabled, with
    /// no range limit (0x00462bd0). Leaves the target alone when there is none.
    @discardableResult
    public func selectNearestHostileThreat() -> Ship? {
        nearestOriginal { !$0.disabled && isThreatToPlayerSquad($0) }
    }

    /// Alt-R: the nearest ship outside the player's squad, disabled hulks
    /// included, with no range limit (0x00462850).
    @discardableResult
    public func selectNearestEngaged() -> Ship? {
        nearestOriginal { _ in true }
    }

    private func nearestOriginal(_ accept: (Ship) -> Bool) -> Ship? {
        let p = player.position
        let best = npcs.filter { npc in
            npc.isAlive && canTarget(npc, by: player) && !isInPlayerSquad(npc) && accept(npc)
        }.min { ($0.position - p).length < ($1.position - p).length }
        guard let best else { return nil }
        return selectTarget(id: best.entityID)
    }
}
