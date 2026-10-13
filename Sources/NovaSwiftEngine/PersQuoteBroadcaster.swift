import Foundation
import NovaSwiftKit

/// The përs HailQuote broadcast of `Ship_HandleShip` 0x00433050 (lines
/// 220-320), kept in the engine so its rate can be tested.
///
/// Per raw sim call, per visible përs ship: every gate below must pass, then
/// `Rand(140) == 0` AND the overlay timer (`DAT_00597a12`) < 1 AND 2700 ticks
/// (45 s) since that ship's last quote — or the 0x0010 "begins to attack"
/// force. A quote runs through `NovaHud_ShowOverlayMessage`, the same timer
/// the distress calls (0x004112c0) wait on, so the two never overlap.
/// Flags: 0x0020 disabled-only · 0x0010 first threat to the squad · 0x0004
/// grudge · 0x0008 likes · 0x0400 LinkMission must be offerable · 0x0800 mute
/// in state 2 · 0x0080 once per ship · 0x1000 / 0x2000 / 0x4000 mute the quote
/// while the player's hull has `shïp` AiType (InherentAI, in-memory `+0x12`)
/// 1 / 2 / above 2 (`playerClassAllows`). The announcement (0x00426d10) sounds
/// snd 154, priority 1, as it shows.
public final class PersQuoteBroadcaster {
    public static let oneIn = 140
    public static let restSeconds = 45.0
    public static let overlayFrames = 0x1a4
    /// `Mission_ShowMissionShipAnnouncement` 0x00426d10 plays `DAT_00591570`
    /// (snd 154, "incoming") at priority 1 as it posts the line.
    public static let announcementBeep = 154

    /// The përs flag gates that depend on the player's own hull
    /// (0x00433050): 0x1000 mutes the quote while the player flies an
    /// AiType-1 hull, 0x2000 an AiType-2 hull, 0x4000 any hull above 2.
    public static func playerClassAllows(persFlags: UInt16, playerAIType: Int) -> Bool {
        if persFlags & 0x1000 != 0, playerAIType == 1 { return false }
        if persFlags & 0x2000 != 0, playerAIType == 2 { return false }
        if persFlags & 0x4000 != 0, playerAIType > 2 { return false }
        return true
    }

    private var clock = 0.0
    private var lastQuote: [Int: Double] = [:]
    private var quoted: Set<Int> = []
    public init() {}

    /// Forget per-ship latches (entity ids are reused by a new world).
    public func reset() { lastQuote = [:]; quoted = [] }

    /// Run `calls` raw sim calls' worth of rolls in one go. `barBusy` is the
    /// host's own status line being occupied (the overlay timer is read from
    /// the world). `roll` is a uniform [0,1) source. Returns the quotes
    /// posted (the world's overlay message is set for each).
    @discardableResult
    public func step(world: World, game: NovaGame, elapsed: Double, barBusy: Bool,
                     grudge: (Int) -> Bool, hostile: (Ship) -> Bool, missionAvailable: (PersRes) -> Bool,
                     roll: () -> Double) -> [String] {
        clock += elapsed
        let calls = elapsed / OriginalClock.rawCallSeconds
        let chance = 1 - pow(Double(Self.oneIn - 1) / Double(Self.oneIn), calls)
        var out: [String] = []
        let playerAIType = game.ship(world.player.shipTypeID)?.inherentAI ?? 0
        for npc in world.npcs where npc.isAlive {
            guard let pid = npc.personID, let pers = game.pers(pid), pers.hailQuote >= 1,
                  world.canTarget(npc, by: world.player), !world.player.isEffectivelyCloaked else { continue }
            if npc.disabled != pers.hailQuoteWhenDisabled { continue }
            if npc.personFlags & 0x0800 != 0, world.originalAI.record(for: npc.entityID)?.state == OriginalAIState.departJump { continue }
            var forced = false
            if pers.hailQuoteWhenAttacking, !npc.disabled {
                guard !quoted.contains(npc.entityID), world.isThreatToPlayerSquad(npc) else { continue }
                forced = true
            }
            if pers.hailQuoteWhenGrudge, !grudge(pid) { continue }
            if pers.hailQuoteWhenLikes, hostile(npc) { continue }
            if pers.quoteOnce, quoted.contains(npc.entityID) { continue }
            if !Self.playerClassAllows(persFlags: pers.flags, playerAIType: playerAIType) { continue }
            let rested = clock > (lastQuote[npc.entityID] ?? -.infinity) + Self.restSeconds
            let idle = !barBusy && world.overlayTicks < 1
            guard forced || (idle && rested && roll() < chance) else { continue }
            // 0x0400: no quote while the LinkMission can't be offered.
            if pers.noQuoteWithoutMission, !missionAvailable(pers) { continue }
            let quote = game.singleString(pers.hailQuote + 4999) ?? game.stringList(7101)?.string(at: pers.hailQuote)
            guard let quote, !quote.isEmpty else { continue }
            let text = quote.replacingOccurrences(of: "<OSN>", with: pers.name)
            world.postOverlayMessage(text, frames: Self.overlayFrames, beep: Self.announcementBeep)
            quoted.insert(npc.entityID)
            lastQuote[npc.entityID] = clock
            out.append(text)
        }
        return out
    }
}
