import NovaSwiftEngine
import NovaSwiftNet

extension WorldSnapshot {
    /// Build the authority's snapshot of its live `World` for co-located clients.
    ///
    /// Ship tagging is **recipient-agnostic** (one snapshot is broadcast to every
    /// client): the local player and every remote player are tagged `.remote` and
    /// carry their `playerID`; NPCs are `.ai` with a nil `playerID`. Each receiving
    /// client picks out *its own* ship by matching `playerID == localPlayerID` (it
    /// predicts that ship locally and ignores the echoed state) — so no per-client
    /// re-tagging is needed. `localPlayerID` is the authority's own player id, which
    /// the authority's `player` (entity 0) is stamped with.
    ///
    /// NPC sync is included (players in a shared system see the same ambient/combat
    /// traffic); mission/effect/projectile state is a later layer.
    public static func build(from world: World, localPlayerID: String,
                             tick: UInt32, ackInputSeq: UInt32) -> WorldSnapshot {
        var ships: [ShipNetState] = []
        ships.reserveCapacity(world.allShips.count)
        for ship in world.allShips where ship.isAlive {
            let playerID: String?
            let control: NetControlSource
            if ship.isPlayer {
                playerID = localPlayerID
                control = .remote           // "another player" from a client's view
            } else if let info = ship.remotePlayer {
                playerID = info.peerID
                control = .remote
            } else {
                playerID = nil
                control = .ai
            }
            ships.append(ShipNetState(
                id: ship.entityID, playerID: playerID, shipTypeID: ship.shipTypeID,
                government: ship.government, name: ship.name,
                x: ship.position.x, y: ship.position.y,
                vx: ship.velocity.x, vy: ship.velocity.y,
                angle: ship.angle, shield: ship.shield, armor: ship.armor,
                control: control))
        }
        // Live shots, so co-located clients see fire (visual only — damage already
        // rides ship health). Skip any visual echoes we might be holding ourselves.
        var shots: [ProjectileNetState] = []
        shots.reserveCapacity(world.projectiles.count)
        for p in world.projectiles where p.alive && !p.visualOnly {
            shots.append(ProjectileNetState(
                ownerID: p.ownerID, x: p.position.x, y: p.position.y,
                vx: p.velocity.x, vy: p.velocity.y, facing: p.facing, life: p.life,
                weaponID: p.weaponID, graphicSpinID: p.graphicSpinID,
                spinShots: p.spinShots, translucentShots: p.translucentShots))
        }
        return WorldSnapshot(tick: tick, ackInputSeq: ackInputSeq, ships: ships, shots: shots)
    }
}
