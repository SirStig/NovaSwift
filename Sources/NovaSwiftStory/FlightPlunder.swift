import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// Boarding a disabled hulk and the Plunder window (`PlunderView`, DLOG/DITL
/// #1011), as rules a frontend drives — extracted from the Apple app's
/// `GameContainerView` / `GameScene` so the Godot frontend plunders with the same
/// odds, messages and self-destruct risk (`NovaUi_RunBoardingPlunderWindow`
/// 0x00482940, `Player_HandleBoardTargetCommand` 0x0045a3d0).
///
/// The loot itself (credits, the cargo/fuel/ammo rolls, capture odds) is the
/// engine's `World` boarding code; this class sequences it: which hulk is
/// boardable, the panic roll before each press, what each button credits to the
/// pilot, and what text it shows.
public final class FlightPlunder {

    /// How close (world units) the player must be to a disabled hulk to board it.
    public static let boardingRange: Double = 280

    /// The window's readout and which buttons are live.
    public struct View: Sendable, Equatable {
        public var shipID: Int
        public var name: String
        /// (commodity name, tons) rows; empty once looted.
        public var cargo: [(name: String, tons: Int)]
        public var credits: Int
        public var ammo: Int
        public var energy: Int
        /// Percent odds, nil = this hull can't be captured.
        public var captureChance: Int?
        public var cargoTons: Int { cargo.reduce(0) { $0 + $1.tons } }

        public static func == (a: View, b: View) -> Bool {
            a.shipID == b.shipID && a.name == b.name && a.credits == b.credits && a.ammo == b.ammo
                && a.energy == b.energy && a.captureChance == b.captureChance
                && a.cargo.map(\.name) == b.cargo.map(\.name) && a.cargo.map(\.tons) == b.cargo.map(\.tons)
        }
    }

    public enum Action: Int, Sendable { case energy = 0, cargo, credits, ammo, capture }

    /// What a Board press came to.
    public enum Boarding: Equatable, Sendable {
        /// Nothing in reach: snd 153.
        case nothing
        /// A former escort/fighter was taken back aboard (no plunder window): the
        /// line to show (STR# 2002 #127–#129), snd 154.
        case recovered(String?)
        /// The plunder window is open (`view`); the boarding crime is recorded
        /// and a përs's outfit loot handed over.
        case window
    }

    /// The captured-ship question (DLOG 1018) and what's needed to answer it.
    public struct CaptureChoice: Sendable, Equatable {
        public var shipID: Int
        public var shipTypeID: Int
        public var name: String
    }

    /// One press's outcome.
    public struct Result: Sendable {
        /// Lines for the status line.
        public var messages: [String] = []
        /// The window closed (hulk self-destructed, or the capture left it).
        public var closed = false
        /// A greyed button was pressed: snd 153.
        public var refused = false
        /// A successful capture waiting for "use as escort / take command".
        public var choice: CaptureChoice?
    }

    public private(set) var shipID: Int?
    private var panic: World.PlunderPanic?

    public init() {}

    public var isOpen: Bool { shipID != nil }

    // MARK: Board

    /// The Board command: the targeted hulk if disabled and in range, else the
    /// nearest disabled one in range (`GameScene.attemptBoard`).
    public func board(world: World, game: NovaGame, pilot: inout PlayerState) -> Boarding {
        shipID = nil
        guard world.player.isAlive else { return .nothing }
        let pos = world.player.position
        func boardable(_ s: Ship) -> Bool {
            s.isAlive && s.disabled && s !== world.player && (s.position - pos).length <= Self.boardingRange
        }
        var hulk: Ship?
        if let tid = world.player.currentTargetID, let s = world.ship(id: tid), boardable(s) {
            hulk = s
        } else if let nearest = world.npcs.filter(boardable)
            .min(by: { ($0.position - pos).length < ($1.position - pos).length }) {
            world.selectTarget(id: nearest.entityID)   // lock it so the plunder targets it
            hulk = nearest
        }
        guard let hulk, let manifest = world.board(shipID: hulk.entityID) else { return .nothing }
        let strs = game.stringList(2002)
        // AI-38 / AI-41: a former escort is repaired back into the wing, and a
        // fighter the player's bays carry goes into a bay — no plunder window.
        if let recovery = world.recoverOnBoarding(shipID: hulk.entityID) {
            switch recovery {
            case let .escortRepaired(cargo):
                for (type, tons) in cargo { pilot.cargo[type, default: 0] += tons }
                return .recovered(strs?.string(at: 127))
            case .fighterRepaired: return .recovered(strs?.string(at: 128))
            case .fighterCaptured: return .recovered(strs?.string(at: 129))
            }
        }
        shipID = manifest.shipID
        panic = World.PlunderPanic(rand: { Int.random(in: 0..<$0) })
        grantLoot(manifest: manifest, world: world, game: game, pilot: &pilot)
        return .window
    }

    /// A përs's ItemClass outfit loot is handed over on boarding.
    private func grantLoot(manifest: World.BoardingManifest, world: World, game: NovaGame, pilot: inout PlayerState) {
        let loot = world.takePlunderOutfits(from: manifest.shipID)
        guard !loot.isEmpty else { return }
        for oid in loot { pilot.grantOutfit(oid) }
        // "You retrieved a <outfit> from this ship." (#106 / #108, 0x00482940):
        // the original hands over one outfit type per boarding, so the first
        // type in the loot names the line.
        guard let first = loot.first, let outfit = game.outfit(first) else { return }
        let count = loot.filter { $0 == first }.count
        pendingMessages.append(OriginalText(game: game).retrievedOutfit(
            count: count, singular: outfit.lowercaseDisplayName, plural: outfit.lowercasePluralDisplayName))
    }

    /// Lines raised by boarding itself (loot), drained by the frontend.
    public private(set) var pendingMessages: [String] = []
    public func drainMessages() -> [String] {
        defer { pendingMessages.removeAll() }
        return pendingMessages
    }

    // MARK: Readout

    public func view(world: World, game: NovaGame, pilot: PlayerState, galaxy: Galaxy) -> View? {
        guard let id = shipID, let m = world.boardingManifest(for: id) else { return nil }
        let free = PilotEconomy.freeMass(pilot, galaxy: galaxy)
        return View(shipID: id, name: m.name,
                    cargo: m.cargo.map { (Self.commodityName($0.commodity, game), $0.tons) },
                    credits: m.credits,
                    ammo: world.ammoAboard(id, freeMass: free),
                    energy: Int(world.fuelAboard(id).rounded()),
                    captureChance: m.captureChance)
    }

    /// Whether `action`'s button is live for `view` (the original greys the rest).
    public static func enabled(_ action: Action, _ v: View) -> Bool {
        switch action {
        case .energy: return v.energy > 0
        case .cargo: return v.cargoTons > 0
        case .credits: return v.credits > 0
        case .ammo: return v.ammo > 0
        case .capture: return v.captureChance != nil
        }
    }

    static func commodityName(_ id: Int, _ game: NovaGame) -> String {
        if let c = Commodity(rawValue: id) { return game.commodityName(c) }
        return "Cargo"
    }

    // MARK: Buttons

    /// A loot button. After a loot action the hulk may blow itself up first
    /// (`rand(100) ≤ panic`, STR# 2002 #113), ending the boarding.
    public func press(_ action: Action, world: World, game: NovaGame, galaxy: Galaxy,
                      pilot: inout PlayerState) -> Result {
        var r = Result()
        guard let id = shipID, let v = view(world: world, game: game, pilot: pilot, galaxy: galaxy) else {
            r.closed = true
            return r
        }
        guard Self.enabled(action, v) else { r.refused = true; return r }
        if var p = panic {
            let blows = p.rollsSelfDestruct(rand: { Int.random(in: 0..<$0) })
            panic = p
            if blows { return selfDestruct(id, world: world, game: game) }
        }
        let text = OriginalText(game: game)
        switch action {
        case .credits:
            let credits = world.takePlunderCredits(from: id)
            guard credits > 0 else { return r }
            panic?.looted(.credits)
            pilot.credits += credits
            r.messages.append(text.plunderedCredits)   // #116 #33 #108
        case .cargo:
            // The hold the fleet shares: the live ship's, folded into the pilot first.
            pilot.cargo = world.player.cargo
            let room = PilotEconomy.cargoFree(pilot, galaxy: galaxy)
            let taken = world.takePlunderCargo(from: id, room: room)
            panic?.looted(.cargo)
            if let (commodity, tons) = taken.first {
                pilot.cargo = world.player.cargo   // the engine already loaded the ship
                let name = Commodity(rawValue: commodity).map { game.commodityName($0) } ?? ""
                r.messages.append(text.plunderedCargo(tons: tons, name: name))
            } else {
                r.messages.append(text.plunderCargoNoRoom)
            }
        case .energy:
            // 0x00482940, slot 6: #6 when nothing fits, #5 when the tank is
            // still short afterwards, #4 when it is full.
            let took = world.takePlunderFuel(from: id)
            guard took >= 1 else { r.messages.append(text.plunderedEnergy(tookAny: false, tankFull: false)); return r }
            panic?.looted(.fuel)
            pilot.fuel = world.player.fuel
            r.messages.append(text.plunderedEnergy(tookAny: true, tankFull: world.player.fuel >= world.player.maxFuel))
        case .ammo:
            // Asked before the take: a bank emptied by it no longer qualifies.
            let ammoOutfit = world.ammoPlunderOutfit(of: id)
            let rounds = world.takePlunderAmmo(from: id, freeMass: PilotEconomy.freeMass(pilot, galaxy: galaxy))
            guard rounds > 0, let ammoOutfit else { r.messages.append(text.misc(117)); return r }
            panic?.looted(.ammo)
            r.messages.append(text.plunderedAmmo(rounds: rounds, singular: ammoOutfit.lowercaseDisplayName,
                                                 plural: ammoOutfit.lowercasePluralDisplayName))
        case .capture:
            return capture(id, world: world, game: game, pilot: &pilot)
        }
        return r
    }

    /// Abort: leaving clears the panic; the hulk stays adrift, disabled (EC-18).
    public func abort(world: World?) {
        if let id = shipID { world?.finishBoardingWithoutCapture(shipID: id) }
        shipID = nil
        panic = nil
    }

    private func selfDestruct(_ id: Int, world: World, game: NovaGame) -> Result {
        world.selfDestructHulk(id)
        shipID = nil
        panic = nil
        var r = Result()
        r.closed = true
        r.messages.append(game.stringList(2002)?.string(at: 113) ?? "The ship self-destructs!")
        return r
    }

    /// Capture, in the original's order: `Rand(100)` against the odds, a
    /// one-in-ten scuttle, the room for another escort, then the player's crew.
    private func capture(_ id: Int, world: World, game: NovaGame, pilot: inout PlayerState) -> Result {
        var r = Result()
        let strs = game.stringList(2002)
        let capturedPers = world.ship(id: id)?.personID
        switch world.resolveCapture(shipID: id) {
        case .failed:
            r.messages.append(strs?.string(at: 125) ?? "Capture attempt failed.")
            return r
        case .selfDestructs:
            return selfDestruct(id, world: world, game: game)
        case .noRoom:
            r.messages.append(strs?.string(at: 124) ?? "You can't command any more escorts.")
            return r
        case let .joinsAsEscort(type, name), let .offerChoice(type, name):
            guard PilotEconomy.canAddEscort(pilot) else {
                r.messages.append(strs?.string(at: 124) ?? "You can't command any more escorts.")
                return r
            }
            panic = nil
            shipID = nil
            r.closed = true
            // A captured përs is consumed (0x00423fa0) — it never spawns again.
            if let pid = capturedPers { pilot.recordPersDefeated(pid) }
            let choice = CaptureChoice(shipID: id, shipTypeID: type, name: name)
            // A captain with no crew of his own isn't asked: the prize escorts.
            if world.player.crew < 1 {
                r.messages.append(contentsOf: Self.useAsEscort(choice, world: world, game: game, pilot: &pilot))
            } else {
                r.choice = choice
            }
            return r
        }
    }

    // MARK: Capture outcomes

    /// "Use as escort": the captured hull joins the wing (free — no daily fee)
    /// and is registered in the persistent roster.
    public static func useAsEscort(_ cap: CaptureChoice, world: World, game: NovaGame,
                                   pilot: inout PlayerState) -> [String] {
        world.recruitCapturedEscort(shipID: cap.shipID)
        let name = cap.name.isEmpty ? (game.ship(cap.shipTypeID)?.name ?? "Escort") : cap.name
        let record = pilot.registerEscort(shipType: cap.shipTypeID, name: name, origin: .captured)
        world.ship(id: cap.shipID)?.escortRecordID = record.id
        applyOnCapture(shipType: cap.shipTypeID, game: game, pilot: &pilot)
        return [OriginalText(game: game).capturedAsEscortLine]   // #123
    }

    /// "Take command": the captured hull becomes the flagship and the old one
    /// joins the wing when there is room (STR# 2002 #304/#305). The caller
    /// rebuilds the flight world from the pilot's new hull. `name` is the new
    /// ship's name (default: the class and three digits 1–9, 0x00482940).
    public static func takeCommand(_ cap: CaptureChoice, name: String?, world: World, game: NovaGame,
                                   pilot: inout PlayerState) -> [String] {
        let kept = PilotEconomy.takeCommandOfCapturedHull(&pilot, hull: cap.shipTypeID, game: game)
        let line = game.stringList(2002)?.string(at: kept ? 304 : 305)
            ?? (kept ? "You retained your old ship as an escort." : "You were unable to retain your old ship as an escort.")
        pilot.shipName = name ?? world.capturedShipDefaultName(shipTypeID: cap.shipTypeID)
        applyOnCapture(shipType: cap.shipTypeID, game: game, pilot: &pilot)
        return [line]
    }

    /// Bible `shïp.OnCapture`: the control-bit expression run when the player
    /// captures a hull of this type, whichever outcome is chosen.
    public static func applyOnCapture(shipType: Int, game: NovaGame, pilot: inout PlayerState) {
        guard let onCapture = game.ship(shipType)?.onCapture,
              !onCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let engine = StoryEngine(game: game, player: pilot)
        engine.apply(set: onCapture, source: "shïp \(shipType) \"\(game.ship(shipType)?.name ?? "")\" OnCapture")
        pilot = engine.player
    }
}
