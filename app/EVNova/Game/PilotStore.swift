import Foundation
import SwiftUI
import EVNovaKit
import EVNovaEngine
import EVNovaStory

/// The persistent player pilot: the single source of truth for credits, cargo,
/// installed outfits, current hull and location. It wraps `EVNovaStory`'s
/// `PlayerState` (which the story engine also reads/mutates) in an observable,
/// disk-backed store so the spaceport UI can shop against it and the game can
/// save/resume.
///
/// This is our own save format (JSON), **not** EV Nova's obfuscated `.plt` — the
/// classic pilot file is unresearched, so we persist `PlayerState` directly.
@MainActor
final class PilotStore: ObservableObject {
    /// The live pilot. Published so shopping and the HUD update in place.
    @Published var state: PlayerState
    /// True once a real pilot exists (loaded from disk or started from `chär`).
    @Published private(set) var started: Bool
    /// The roster save this live pilot belongs to (nil until bound by the
    /// multi-pilot roster). Durable multi-file saves + backups persist under this
    /// id via `PilotRoster`; `save()` here is the frequent crash-safe autosave.
    @Published private(set) var rosterID: UUID?

    // MARK: Location on disk

    private static var saveURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("EVNova", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pilot.json")
    }

    // MARK: Lifecycle

    init() {
        if let data = try? Data(contentsOf: PilotStore.saveURL),
           let loaded = try? JSONDecoder().decode(PlayerState.self, from: data) {
            state = loaded
            started = true
            rosterID = loaded.rosterID   // restore across relaunch, not just in-session
        } else {
            state = PlayerState()   // placeholder until `newGame` / `ensureStarted`
            started = false
        }
    }

    /// Whether a resumable save exists on disk.
    var hasSave: Bool { FileManager.default.fileExists(atPath: PilotStore.saveURL.path) }

    /// Bootstrap a fresh pilot from the scenario's `chär`, unless one is already
    /// underway. Called when the game screen first appears.
    func ensureStarted(game: NovaGame) {
        guard !started else { return }
        newGame(game: game)
    }

    /// Start a brand-new pilot from the scenario defaults (`chär`: starting hull,
    /// credits and system).
    func newGame(game: NovaGame) {
        let ch = game.startingChar()
        let shipID = ch?.startingShip ?? game.ships().first?.id ?? 128
        let shipName = game.ship(shipID)?.name ?? "Ship"
        let system = ch?.startingSystem ?? game.startingSystem()?.id ?? 128
        state = PlayerState(pilotName: "Captain",
                            shipType: shipID,
                            shipName: shipName,
                            credits: ch?.startingCredits ?? 10_000,
                            currentSystem: system)
        started = true
        save()
    }

    func save() {
        guard started, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: PilotStore.saveURL, options: .atomic)
    }

    /// Adopt a pilot created or loaded by the multi-pilot roster as the live,
    /// in-session pilot. Everything downstream (ship build, spaceport, HUD) reads
    /// `state`, so this is all that's needed to "play as" a roster pilot.
    func begin(state: PlayerState, rosterID: UUID) {
        self.state = state
        self.state.rosterID = rosterID
        self.rosterID = rosterID
        self.started = true
        save()
    }

    /// Bind this session to a durable roster id after the fact (e.g. the first
    /// autosave attempt for a session that started outside the normal
    /// create/play flow, like the no-data demo path). No-op if already bound.
    func bind(rosterID: UUID) {
        guard self.rosterID == nil else { return }
        self.rosterID = rosterID
        self.state.rosterID = rosterID
        save()
    }

    /// Wipe the save (for "New Pilot").
    func reset() {
        try? FileManager.default.removeItem(at: PilotStore.saveURL)
        state = PlayerState()
        started = false
        rosterID = nil
    }

    // MARK: Derived, data-dependent queries

    /// Effective cargo capacity of the current hull + installed outfits, in tons.
    func cargoCapacity(galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.cargoCapacity
            ?? galaxy.game.ship(state.shipType)?.cargoSpace ?? 0
    }
    func cargoUsed() -> Int { state.usedCargoSpace }
    func cargoFree(galaxy: Galaxy) -> Int { max(0, cargoCapacity(galaxy: galaxy) - cargoUsed()) }

    /// Free outfit mass remaining (hull free mass minus installed outfit mass).
    func freeMass(galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.freeMass
            ?? galaxy.game.ship(state.shipType)?.freeMass ?? 0
    }

    func owned(outfit id: Int) -> Int { state.outfits[id] ?? 0 }
    func held(cargo id: Int) -> Int { state.cargo[id] ?? 0 }

    /// Hyperlane hops a single hyperspace jump can cross, from installed outfits
    /// (multi-jump drives). 1 = standard single-jump.
    func maxJumpHops(galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.maxJumpHops ?? 1
    }

    /// True if any installed outfit is a map/chart (reveals the whole galaxy).
    func ownsMapOutfit(game: NovaGame) -> Bool {
        state.outfits.keys.contains { game.outfit($0)?.has(.map) ?? false }
    }

    // MARK: Transactions (return the number actually transacted)

    @discardableResult
    func buyCommodity(_ c: Commodity, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        guard unitPrice > 0 else { return 0 }
        let affordable = state.credits / unitPrice
        let n = max(0, min(tons, cargoFree, affordable))
        guard n > 0 else { return 0 }
        state.credits -= n * unitPrice
        state.cargo[c.cargoID, default: 0] += n
        save()
        return n
    }

    @discardableResult
    func sellCommodity(_ c: Commodity, tons: Int, unitPrice: Int) -> Int {
        let held = state.cargo[c.cargoID] ?? 0
        let n = max(0, min(tons, held))
        guard n > 0 else { return 0 }
        state.credits += n * unitPrice
        let left = held - n
        if left > 0 { state.cargo[c.cargoID] = left } else { state.cargo[c.cargoID] = nil }
        save()
        return n
    }

    /// Can the player buy `outfit` here (affordable, fits, under its own max)?
    func canBuyOutfit(_ o: OutfRes, galaxy: Galaxy) -> Bool {
        guard state.credits >= o.cost else { return false }
        if o.mass > 0, freeMass(galaxy: galaxy) < o.mass { return false }
        if o.maxInstallable > 0, owned(outfit: o.id) >= o.maxInstallable { return false }
        return true
    }

    @discardableResult
    func buyOutfit(_ o: OutfRes, galaxy: Galaxy) -> Bool {
        guard canBuyOutfit(o, galaxy: galaxy) else { return false }
        state.credits -= o.cost
        state.grantOutfit(o.id)
        save()
        return true
    }

    /// EV Nova refunds outfits at full purchase price.
    @discardableResult
    func sellOutfit(_ o: OutfRes) -> Bool {
        guard owned(outfit: o.id) > 0 else { return false }
        state.credits += o.cost
        state.removeOutfit(o.id)
        save()
        return true
    }

    /// Trade-in value of the current hull toward a new one (25% of hull cost).
    func tradeInValue(game: NovaGame) -> Int {
        Int(Double(game.ship(state.shipType)?.cost ?? 0) * 0.25)
    }

    /// Net price to switch to `ship` (its cost minus the current hull's trade-in).
    func netPrice(of ship: ShipRes, game: NovaGame) -> Int {
        max(0, ship.cost - tradeInValue(game: game))
    }

    @discardableResult
    func buyShip(_ ship: ShipRes, game: NovaGame) -> Bool {
        let price = netPrice(of: ship, game: game)
        guard state.credits >= price, ship.id != state.shipType else { return false }
        state.credits -= price
        state.shipType = ship.id
        state.shipName = ship.name
        // Outfits carry over (EV Nova keeps persistent items); cargo stays, but is
        // dropped if it no longer fits the new, smaller hold — clamped on takeoff.
        save()
        return true
    }
}
