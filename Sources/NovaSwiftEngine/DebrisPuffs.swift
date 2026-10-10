import Foundation

/// One of the 32 fading debris puffs a disabled ship sheds (0x00428090,
/// updated per raw call by 0x0043b170). `life < 0` marks a free slot.
public struct DebrisPuff {
    public var position = Vec2()
    public var velocity = Vec2()    // px per raw call
    public var life: Double = -1
    /// Opacity: opaque while life >= 32, fading over the last 32 ticks.
    public var opacity: Double { life >= 32 ? 1 : max(0, life / 32) }
}

extension World {
    /// Claim the first free slot (0x00428090): life `Range(100) + 150`, the
    /// ship's position and velocity, plus a polar kick of
    /// `(Range(10) + 10) × 0.1` px per raw call at `Range(360)` degrees.
    func spawnDebrisPuff(from ship: Ship) {
        guard let slot = debrisPuffs.firstIndex(where: { $0.life < 0 }) else { return }
        let life = Double(rng.range(100) + 150)
        let bearing = Double(rng.range(360)) * .pi / 180
        let speed = Double(rng.range(10) + 10) * 0.1
        // Ship velocity is px/s; the pool moves in px per raw call (30 Hz).
        var v = Vec2(ship.velocity.x / 30, ship.velocity.y / 30)
        v.x += cos(bearing) * speed
        v.y += sin(bearing) * speed
        debrisPuffs[slot] = DebrisPuff(position: ship.position, velocity: v, life: life)
    }

    /// The shed cadence in Ship_HandleShip (0x00433050): while the hull is
    /// at or below half armor and still alive (armor > 0, never during the death delay), with pods left, one puff every
    /// `max(10, round(armor / PodCount × 0.4))` raw calls, the first at once.
    /// Raw calls between puffs: `max(10, round(shïp.Armor / PodCount × 0.4))`
    /// (integer division first, as the original does).
    static func debrisPuffPeriod(hullArmor: Int, podCount: Int) -> Int {
        max(10, Int((Double(hullArmor / podCount) * 0.4).rounded()))
    }

    func tickDebrisPuffs(rawCalls: Int) {
        guard rawCalls > 0, let game = galaxy?.game else { return }
        for npc in npcs + [player] where npc.isAlive {
            guard let hull = game.ship(npc.shipTypeID), hull.podCount > 0,
                  npc.armor <= npc.maxArmor * 0.5 else { continue }
            if npc.debrisPodsLeft == nil { npc.debrisPodsLeft = hull.podCount }
            guard let left = npc.debrisPodsLeft, left > 0 else { continue }
            let period = Self.debrisPuffPeriod(hullArmor: hull.armor, podCount: hull.podCount)
            for k in 0..<rawCalls {
                guard let now = npc.debrisPodsLeft, now > 0 else { break }
                if (rawCallCounter - rawCalls + 1 + k) % period == 0 || now == hull.podCount {
                    npc.debrisPodsLeft = now - 1
                    spawnDebrisPuff(from: npc)
                }
            }
        }
        for _ in 0..<rawCalls { advanceDebrisPuffs() }
    }

    private func advanceDebrisPuffs() {
        for i in debrisPuffs.indices where debrisPuffs[i].life >= 0 {
            debrisPuffs[i].position.x += debrisPuffs[i].velocity.x
            debrisPuffs[i].position.y += debrisPuffs[i].velocity.y
            debrisPuffs[i].life -= 1
        }
    }
}
