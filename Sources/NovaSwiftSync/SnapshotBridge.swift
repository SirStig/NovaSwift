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
                id: ship.entityID, playerID: playerID, name: ship.name,
                x: ship.position.x, y: ship.position.y,
                vx: ship.velocity.x, vy: ship.velocity.y,
                angle: ship.angle, shield: ship.shield, armor: ship.armor,
                control: control))
        }
        return WorldSnapshot(tick: tick, ackInputSeq: ackInputSeq, ships: ships)
    }
}
