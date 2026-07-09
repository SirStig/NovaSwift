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
        if let data = try? Data(contentsOf: PilotStore.saveURL) {
            do {
                let loaded = try JSONDecoder().decode(PlayerState.self, from: data)
                state = loaded
                started = true
                rosterID = loaded.rosterID   // restore across relaunch, not just in-session
                Log.pilot.notice("PilotStore.init: loaded live pilot save (rosterID=\(loaded.rosterID?.uuidString ?? "none", privacy: .public))")
            } catch {
                // The file exists but didn't decode — a real data-loss risk, not
                // just "no save yet". Previously this silently fell through to a
                // blank pilot with no trace of why.
                Log.pilot.error("PilotStore.init: failed to decode live pilot save at \(PilotStore.saveURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                state = PlayerState()
                started = false
            }
        } else {
            state = PlayerState()   // placeholder until `newGame` / `ensureStarted`
            started = false
            Log.pilot.debug("PilotStore.init: no live pilot save found on disk")
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
        if ch == nil {
            Log.pilot.error("PilotStore.newGame: no starting chär scenario in game data; using hardcoded fallback ship/system/credits")
        }
        let shipID = ch?.startingShip ?? game.ships().first?.id ?? 128
        let shipName = game.ship(shipID)?.name ?? "Ship"
        let system = ch?.startingSystem ?? game.startingSystem()?.id ?? 128
        state = PlayerState(pilotName: "Captain",
                            shipType: shipID,
                            shipName: shipName,
                            credits: ch?.startingCredits ?? 10_000,
                            currentSystem: system)
        started = true
        Log.pilot.notice("PilotStore.newGame: started new live pilot, ship=\(shipID) system=\(system) credits=\(self.state.credits)")
        save()
    }

    func save() {
        guard started else { return }
        guard let data = try? JSONEncoder().encode(state) else {
            Log.pilot.error("PilotStore.save: failed to encode live pilot state; save skipped")
            return
        }
        do {
            try data.write(to: PilotStore.saveURL, options: .atomic)
        } catch {
            // NOTE: possible bug source — a write failure here (disk full,
            // sandbox/permission issue) previously vanished silently; the player
            // would keep playing believing they were autosaved. Now at least
            // it's visible in the log; the underlying failure mode is still
            // unhandled (no retry/user-facing warning).
            Log.pilot.error("PilotStore.save: failed to write live pilot save to \(PilotStore.saveURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Adopt a pilot created or loaded by the multi-pilot roster as the live,
    /// in-session pilot. Everything downstream (ship build, spaceport, HUD) reads
    /// `state`, so this is all that's needed to "play as" a roster pilot.
    func begin(state: PlayerState, rosterID: UUID) {
        self.state = state
        self.state.rosterID = rosterID
        self.rosterID = rosterID
        self.started = true
        Log.pilot.notice("PilotStore.begin: adopted roster pilot \(rosterID, privacy: .public) as the live pilot")
        save()
    }

    /// Bind this session to a durable roster id after the fact (e.g. the first
    /// autosave attempt for a session that started outside the normal
    /// create/play flow, like the no-data demo path). No-op if already bound.
    func bind(rosterID: UUID) {
        guard self.rosterID == nil else {
            Log.pilot.debug("PilotStore.bind: already bound to roster \(self.rosterID!, privacy: .public); ignoring rebind to \(rosterID, privacy: .public)")
            return
        }
        self.rosterID = rosterID
        self.state.rosterID = rosterID
        Log.pilot.notice("PilotStore.bind: bound previously-unbound live pilot to roster \(rosterID, privacy: .public)")
        save()
    }

    /// Wipe the save (for "New Pilot").
    func reset() {
        do {
            try FileManager.default.removeItem(at: PilotStore.saveURL)
        } catch {
            Log.pilot.debug("PilotStore.reset: no live save to remove, or removal failed: \(String(describing: error), privacy: .public)")
        }
        state = PlayerState()
        started = false
        rosterID = nil
        Log.pilot.notice("PilotStore.reset: live pilot save cleared")
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
