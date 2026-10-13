import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The player's escort wing in flight, as a frontend sees it: the Escort Commands
/// panel (E, keys 1–5, then F / D / V / C / Alt-C — `EscortCommandPanel`, drawn
/// from STR# 2002), the Escorts window opened by hailing your own escort
/// (DITL #1022: roster + Release), and the roster ↔ live-wing bookkeeping.
/// Extracted from `GameScene` / `GameContainerView` for the Godot frontend.
public final class FlightEscorts {

    /// One row of the panel (`EscortPanelDisplay` on Apple).
    public struct PanelRow: Sendable, Equatable {
        public var label: String
        public var order: String
        public var enabled: Bool
        public var selected: Bool
    }

    /// What the panel shows: the title (#133), a row for All (#144) and each
    /// EscortType (#140–#143) with that group's order (#145 defend, #146 attack,
    /// #147 hold, #148 return to hangar, #149 formation), empty groups greyed,
    /// the selected row lit, and the fade level (0…32).
    public struct PanelDisplay: Sendable, Equatable {
        public var title: String
        public var rows: [PanelRow]
        public var level: Int
    }

    /// One escort in the wing.
    public struct Member: Sendable, Equatable {
        public var entityID: Int
        public var recordID: Int?
        public var name: String
        public var shipTypeID: Int
        public var shieldFraction: Double
        public var armorFraction: Double
        public var isFighter: Bool
        public var disabled: Bool
        /// "Hired · 100cr/day", "Captured" — from the persistent record.
        public var originLabel: String
        /// Release/Dismiss is offered for roster escorts (not bay fighters).
        public var canRelease: Bool
    }

    public private(set) var panel = EscortCommandPanel()
    private var clock: Double = 0          // seconds of flight
    private var rawCalls = 0.0

    public init() {}

    private var tickCount60: Double { clock * 60 }

    /// A new world: the panel closes.
    public func reset() {
        panel = EscortCommandPanel()
        clock = 0
        rawCalls = 0
    }

    // MARK: Panel

    public enum PressE: Equatable, Sendable { case opened, noEscorts(String), closed }

    /// E: show the panel (snd 150), or "no escorts" (#51, snd 153), or hide it.
    public func pressE(world: World, game: NovaGame) -> PressE {
        switch panel.pressE(hasEscorts: world.playerEscortRoster().any, now: tickCount60) {
        case .opened: return .opened
        case .noEscorts: return .noEscorts(game.stringList(2002)?.string(at: 51) ?? "")
        case .closed: return .closed
        }
    }

    /// A number key (0 = key 1 … 4 = key 5) while the panel is up: pick a group
    /// (snd 152 when one is picked). Returns whether the key was consumed.
    public func pressGroupKey(_ k: Int, world: World) -> (consumed: Bool, picked: Bool) {
        guard panel.isOpen else { return (false, false) }
        let roster = world.playerEscortRoster()
        let picked = panel.pressGroupKey(k, hasCategory: { roster.perCategory[$0] > 0 }, now: tickCount60)
        return (true, picked)
    }

    /// F / D / V / C / Alt-C: the order goes to the selected group while the
    /// panel is up, to every escort otherwise. Returns the "New escort orders
    /// assigned" readout the engine raised, if anything changed.
    @discardableResult
    public func order(_ code: Int, world: World) -> String? {
        let category = panel.order(code)
        let text = world.originalAI.commandPlayerEscortGroup(category: category, command: code, world: world)
        world.lastEscortOrderChanged = text != nil
        if world.lastEscortOrderChanged { panel.orderTaken(now: tickCount60) }
        return text
    }

    /// An order from the Escorts window to one EscortType group (nil = all),
    /// independent of the panel (`GameScene.commandEscortGroup`).
    @discardableResult
    public func orderGroup(category: Int?, command: Int, world: World) -> String? {
        let text = world.originalAI.commandPlayerEscortGroup(category: category, command: command, world: world)
        world.lastEscortOrderChanged = text != nil
        return text
    }

    /// Labels for the Escorts window: the group names (#144 All, #140–#143) and
    /// the order names (#145 defend, #146 attack, #147 hold, #148 return to
    /// hangar, #149 formation), indexed by `OriginalEscortCommand` code.
    public static func windowLabels(game: NovaGame) -> (title: String, groups: [String], orders: [Int: String]) {
        let list = game.stringList(2002)
        func s(_ i: Int) -> String { list?.string(at: i) ?? "" }
        return (s(133), [s(144), s(140), s(141), s(142), s(143)],
                [OriginalEscortCommand.defend: s(145), OriginalEscortCommand.attack: s(146),
                 OriginalEscortCommand.hold: s(147), OriginalEscortCommand.returnToHangar: s(148),
                 OriginalEscortCommand.formation: s(149)])
    }

    /// Advance the panel's hold/fade by `dt` seconds of flight.
    public func tick(dt: Double, world: World) {
        clock += dt
        rawCalls += dt * OriginalClock.rawCallsPerSecond
        let frames = Int(rawCalls)
        rawCalls -= Double(frames)
        let roster = world.playerEscortRoster()
        panel.tick(frames: frames, now: tickCount60, liveEscorts: roster.live,
                   fighterOut: { roster.fighterOut[$0] })
    }

    public func display(world: World, game: NovaGame) -> PanelDisplay? {
        guard panel.isOpen else { return nil }
        let roster = world.playerEscortRoster()
        let list = game.stringList(2002)
        func s(_ i: Int) -> String { list?.string(at: i) ?? "" }
        func orderText(_ o: Int) -> String {
            switch o {
            case 1: return s(145)
            case 2: return s(146)
            case 3: return s(148)
            case 4: return s(147)
            default: return s(149)
            }
        }
        var rows = [PanelRow(label: s(144), order: "", enabled: roster.any, selected: panel.group == -1)]
        for c in 0..<4 {
            let live = roster.perCategory[c] > 0
            rows.append(PanelRow(label: s(140 + c), order: live ? orderText(panel.orders[c]) : "",
                                 enabled: live, selected: panel.group == c))
        }
        return PanelDisplay(title: s(133), rows: rows, level: panel.level)
    }

    // MARK: Escorts window

    public func members(world: World, pilot: PlayerState) -> [Member] {
        world.playerEscorts.map { s in
            let rec = s.escortRecordID.flatMap { pilot.escort(id: $0) }
            var origin = ""
            if let rec { origin = rec.origin == .hired ? "Hired · \(rec.dailyFee)cr/day" : "Captured" }
            return Member(entityID: s.entityID, recordID: s.escortRecordID, name: s.name,
                          shipTypeID: s.shipTypeID, shieldFraction: s.shieldFraction,
                          armorFraction: s.armorFraction, isFighter: s.carrierID != nil,
                          disabled: s.disabled, originLabel: origin,
                          canRelease: rec != nil && s.carrierID == nil)
        }
    }

    /// Release the escort with persistent `recordID` (0x004853a0, EC-22): it first
    /// takes its share of the fleet's cargo (EC-21), leaves the roster (a hired
    /// one stops billing) and stays in the system as an ordinary NPC with its
    /// class's default AI.
    public static func release(recordID: Int, world: World, game: NovaGame, pilot: inout PlayerState) {
        if let rec = pilot.escort(id: recordID) {
            let missionCargo = StoryEngine(game: game, player: pilot).carriedMissionCargo()
            _ = PilotEconomy.transferCargoToEscort(&pilot, recipientHolds: game.ship(rec.shipType)?.cargoSpace ?? 0,
                                                   missionCargo: missionCargo, galaxy: Galaxy(game: game))
        }
        _ = pilot.removeEscort(id: recordID)
        for ship in world.playerEscorts where ship.escortRecordID == recordID {
            ship.escortRecordID = nil
            let inherent = game.ship(ship.shipTypeID)?.inherentAI ?? 0
            world.releaseFromPlayerCommand(ship, aiType: AIType(raw: inherent))
        }
    }

    // MARK: Roster ↔ live wing

    private var recordByEntity: [Int: Int] = [:]

    /// Remember which live ship carries which roster record (call before each
    /// tick), so a ship destroyed in it can still be struck from the roster.
    public func track(world: World) {
        recordByEntity = [:]
        for s in world.playerEscorts { if let rid = s.escortRecordID { recordByEntity[s.entityID] = rid } }
    }

    /// An escort tied to a roster record was destroyed: remove it from the pilot.
    public func note(event: WorldEvent, pilot: inout PlayerState) -> String? {
        guard case let .shipDestroyed(entityID, _, _) = event, let rid = recordByEntity[entityID],
              let lost = pilot.removeEscort(id: rid) else { return nil }
        recordByEntity[entityID] = nil
        return "\(lost.name) was destroyed."
    }

    /// Respawn the persistent roster's escorts in a fresh world (a launch or a
    /// takeoff): each saved record gets a live ship around the player on a random
    /// bearing 50–100 px out, on the player's heading (#21, 0x00422400).
    public static func respawnRoster(world: World, pilot: PlayerState) {
        guard let galaxy = world.galaxy else { return }
        let live = Set(world.playerEscorts.compactMap { $0.escortRecordID })
        for rec in pilot.escortWing where !live.contains(rec.id) {
            let player = world.player
            let heading = AIBrain.wingHeading(for: player)
            guard let ship = galaxy.makeLoadedShip(rec.shipType, government: independentGovt,
                                                   at: player.position, angle: heading,
                                                   skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng))
            else { continue }
            let bearing = Double(world.rng.range(360)) * .pi / 180
            let dist = Double(world.rng.range(50) + 50)
            ship.position = player.position + Vec2.heading(bearing) * dist
            ship.angle = player.angle
            ship.velocity = player.velocity
            world.addNPC(ship, arrival: .populate)
            world.recruitEscort(ship)
            ship.escortRecordID = rec.id
        }
    }
}
