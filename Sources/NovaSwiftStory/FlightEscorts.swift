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

    /// A new world: the panel closes and the entity tags go stale (entity ids
    /// restart with each `World`). The escorts carried through a jump survive —
    /// `respawn` consumes them.
    public func reset() {
        panel = EscortCommandPanel()
        clock = 0
        rawCalls = 0
        recordByEntity = [:]
        droppedRecords = []
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
    /// Records of escorts that dropped out of the wing disabled and have not been
    /// repaired back (`GameScene.droppedEscortRecords`).
    private var droppedRecords: Set<Int> = []

    /// An escort's state carried through a jump (AI-38): `0x0041af90` resets it
    /// without refilling — only a launch or shipyard pass refills.
    private struct Carried {
        var shield: Double, armor: Double, fuel: Double
        var ammo: [Int]
        var docked: [Int]
    }
    private var carried: [Int: Carried] = [:]

    /// How the wing is brought into a freshly built world.
    public enum Arrival: Equatable, Sendable {
        /// A launch / load: around the player at full strength.
        case populate
        /// A hyperspace jump: dropped in behind the slot, damage carried.
        case jump
        /// A gate transport: out of that gate on the player's heading, damage carried.
        case gate(Int)
    }
    private var arrival: Arrival = .populate

    /// Remember which live ship carries which roster record (call before each
    /// tick), so a ship destroyed or disabled in it can still be struck from the
    /// roster. Tags accumulate within a world: a disabled escort leaves the live
    /// wing but keeps its record until it is repaired, lost or abandoned.
    public func track(world: World) {
        for s in world.playerEscorts { if let rid = s.escortRecordID { recordByEntity[s.entityID] = rid } }
    }

    /// The fleet's cargo share an escort leaving the wing carries off (EC-21):
    /// a non-mission freighter hull (`InherentAI < 3`) takes it.
    @discardableResult
    private func transferCargo(recordID: Int, game: NovaGame, pilot: inout PlayerState) -> [Int: Int] {
        guard let rec = pilot.escort(id: recordID), rec.missionID == nil,
              let hull = game.ship(rec.shipType), hull.inherentAI < 3 else { return [:] }
        let missionCargo = StoryEngine(game: game, player: pilot).carriedMissionCargo()
        return PilotEconomy.transferCargoToEscort(&pilot, recipientHolds: hull.cargoSpace,
                                                  missionCargo: missionCargo, galaxy: Galaxy(game: game))
    }

    /// World events that change the roster (`GameScene.processWorldEvents` +
    /// the container's escort callbacks). Returns a status line when one is due.
    public func note(event: WorldEvent, pilot: inout PlayerState, world: World? = nil,
                     game: NovaGame? = nil) -> String? {
        switch event {
        case let .escortLeftWingDisabled(entityID, freighter):
            // AI-38: a disabled escort drops out of the wing; a freighter first
            // takes its cargo share and carries it until repaired back or lost.
            guard let rid = recordByEntity[entityID] else { return nil }
            droppedRecords.insert(rid)
            if freighter, let game {
                let moved = transferCargo(recordID: rid, game: game, pilot: &pilot)
                world?.ship(id: entityID)?.cargo = moved
            }
            return nil
        case .escortRejoined(let entityID, _):
            if let rid = recordByEntity[entityID] { droppedRecords.remove(rid) }
            return nil
        case let .fighterRecoveredToBay(entityID, _):
            guard let rid = recordByEntity[entityID] else { return nil }
            recordByEntity[entityID] = nil
            droppedRecords.remove(rid)
            _ = pilot.removeEscort(id: rid)
            return nil
        case let .shipCapturedByNPC(entityID, _, _):
            // AI-29: a boarder took one of the player's escorts.
            guard let rid = recordByEntity[entityID] else { return nil }
            recordByEntity[entityID] = nil
            if droppedRecords.remove(rid) != nil { _ = pilot.removeEscort(id: rid); return nil }
            return lose(recordID: rid, game: game, pilot: &pilot)
        case let .shipDestroyed(entityID, _, _):
            guard let rid = recordByEntity[entityID] else { return nil }
            recordByEntity[entityID] = nil
            if droppedRecords.remove(rid) != nil {
                return pilot.removeEscort(id: rid).map { "\($0.name) was destroyed." }
            }
            return lose(recordID: rid, game: game, pilot: &pilot)
        default:
            return nil
        }
    }

    /// An escort tied to a roster record is gone for good: a freighter takes its
    /// cargo share down with it, and the record leaves the pilot.
    private func lose(recordID: Int, game: NovaGame?, pilot: inout PlayerState) -> String? {
        if let game { transferCargo(recordID: recordID, game: game, pilot: &pilot) }
        return pilot.removeEscort(id: recordID).map { "\($0.name) was destroyed." }
    }

    /// Before a jump or gate transport replaces the world (`carryEscortsThroughJump`):
    /// an escort that dropped out disabled and was never repaired stays behind
    /// (its record goes); one still disabled in the wing is lost; the rest keep
    /// their shields, armor, fuel and ammunition into the next system. Returns the
    /// status lines for the escorts lost. Call `respawn` once the new world exists.
    public func carryThroughJump(world: World, pilot: inout PlayerState, game: NovaGame?,
                                 via next: Arrival) -> [String] {
        carried = [:]
        var lines: [String] = []
        for ship in world.npcs {
            guard let rid = recordByEntity[ship.entityID], droppedRecords.contains(rid) else { continue }
            recordByEntity[ship.entityID] = nil
            droppedRecords.remove(rid)
            _ = pilot.removeEscort(id: rid)
        }
        for ship in world.npcs where ship.isAlive && ship.brain?.leaderID == World.playerEntityID {
            guard let rid = recordByEntity[ship.entityID] else { continue }
            if ship.disabled {
                recordByEntity[ship.entityID] = nil
                if let line = lose(recordID: rid, game: game, pilot: &pilot) { lines.append(line) }
                continue
            }
            carried[rid] = Carried(shield: ship.shield, armor: ship.armor, fuel: ship.fuel,
                                   ammo: ship.weapons.map(\.ammo), docked: ship.fighterBays.map(\.docked))
        }
        arrival = next
        return lines
    }

    /// Respawn the persistent roster's escorts in a fresh world, each saved record
    /// getting a live ship (`GameScene.respawnEscorts` / `spawnRosterEscort`).
    /// After a launch or load it stands on its formation slot beside the player
    /// at a random bearing 50–100 px out (#21, 0x00422400); after a jump (AI-38) it
    /// takes the player's heading, drops in about 892 px behind its slot and
    /// carries the damage and ammunition it left the last system with; after a gate
    /// it comes out of that gate after a short hold (AI-12). Idempotent by record.
    public func respawn(world: World, pilot: PlayerState) {
        guard let galaxy = world.galaxy else { return }
        let live = Set(world.playerEscorts.compactMap { $0.escortRecordID })
        for rec in pilot.escortWing where !live.contains(rec.id) {
            let player = world.player
            let slot = world.playerEscorts.count
            let heading = AIBrain.wingHeading(for: player)
            guard let ship = galaxy.makeLoadedShip(rec.shipType, government: independentGovt,
                                                   at: player.position, angle: heading,
                                                   skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng))
            else { continue }
            ship.position = AIBrain.formationStation(leaderPosition: player.position, leaderRadius: player.radius,
                                                     heading: heading, slot: slot, escortRadius: ship.radius)
            ship.angle = heading
            ship.velocity = player.velocity
            if arrival != .populate {
                ship.angle = player.angle
                if case .gate = arrival {} else {
                    ship.position += Vec2.heading(ship.angle + .pi) * OriginalSpawnRules.escortJumpLag
                }
                if let c = carried[rec.id] {
                    ship.shield = min(ship.maxShield, c.shield)
                    ship.armor = min(ship.maxArmor, c.armor)
                    ship.fuel = min(ship.maxFuel, c.fuel)
                    if c.ammo.count == ship.weapons.count {
                        for (mount, ammo) in zip(ship.weapons, c.ammo) { mount.ammo = ammo }
                    }
                    if c.docked.count == ship.fighterBays.count {
                        for (bay, docked) in zip(ship.fighterBays, c.docked) { bay.docked = docked }
                    }
                }
                if case let .gate(gateID) = arrival {
                    _ = world.addEscortEmergingWithPlayer(ship, gateID: gateID)
                } else {
                    world.addNPC(ship, arrival: .hyperspace)
                }
            } else {
                let bearing = Double(world.rng.range(360)) * .pi / 180
                let dist = Double(world.rng.range(50) + 50)
                ship.position = player.position + Vec2.heading(bearing) * dist
                ship.angle = player.angle
                world.addNPC(ship, arrival: .populate)
            }
            world.recruitEscort(ship)
            ship.escortRecordID = rec.id
            recordByEntity[ship.entityID] = rec.id
        }
        arrival = .populate
        carried = [:]
    }

    /// Respawn with the launch arrival (kept for callers without a wing instance).
    public static func respawnRoster(world: World, pilot: PlayerState) {
        FlightEscorts().respawn(world: world, pilot: pilot)
    }
}
