import Foundation
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The persistent player pilot: the single source of truth for credits, cargo,
/// installed outfits, current hull and location. It wraps `NovaSwiftStory`'s
/// `PlayerState` (which the story engine also reads/mutates) in an observable,
/// disk-backed store so the spaceport UI can shop against it and the game can
/// save/resume.
///
/// This is our own save format (JSON), **not** EV Nova's obfuscated `.plt` — the
/// classic pilot file is unresearched, so we persist `PlayerState` directly.
@MainActor
final class PilotStore: ObservableObject {
    /// The cap on simultaneous hired/captured/mission escorts — `EscortRecord`s
    /// in the roster, not bay-launched fighters (those aren't roster members;
    /// see `PlayerState.escortWing`). Not a Bible-documented field — no `shïp`/
    /// `flët` field or the EVN wiki describes a wing-size limit — this is a
    /// deliberate house rule. Lives in `PilotEconomy`; aliased here since
    /// external call sites reference `PilotStore.maxEscorts`.
    static let maxEscorts = PilotEconomy.maxEscorts

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
        // Per-instance so a second local-MP test instance keeps its own live
        // autosave (see `AppInstance`); plain `NovaSwift` normally.
        let dir = NovaStorage.root.appendingPathComponent(AppInstance.saveFolderName, isDirectory: true)
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

    /// Start a brand-new pilot from the scenario defaults. Delegates to
    /// `PilotFactory.makeDefault`, which is the single authoritative `chär`
    /// bootstrap: it rolls a *random* start system among the scenario's
    /// candidates (as EV Nova does — not always the first one), and applies the
    /// scenario's starting hull, credits, calendar date, combat rating, legal
    /// standings and OnStart control-bit script. Everything is data-driven from
    /// the `chär`; the only hardcoded values are the last-ditch fallbacks the
    /// factory itself uses when the data set has no `chär` at all.
    func newGame(game: NovaGame) {
        state = PilotFactory.makeDefault(name: "Captain", isMale: true, game: game)
        started = true
        Log.pilot.notice("PilotStore.newGame: started new live pilot, ship=\(self.state.shipType) system=\(self.state.currentSystem) credits=\(self.state.credits)")
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
    //
    // All the actual math (cargo/mass/pricing/transactions) now lives in the
    // portable `PilotEconomy` (Sources/NovaSwiftStory/PilotEconomy.swift) so
    // the Godot bridge can share it instead of reimplementing trade/outfit/
    // shipyard rules. These are thin forwarders that add the one thing
    // `PilotEconomy` deliberately doesn't own: autosave after a mutation.

    func cargoCapacity(galaxy: Galaxy) -> Int { PilotEconomy.cargoCapacity(state, galaxy: galaxy) }
    func cargoUsed() -> Int { PilotEconomy.cargoUsed(state) }
    func cargoFree(galaxy: Galaxy) -> Int { PilotEconomy.cargoFree(state, galaxy: galaxy) }
    func freeMass(galaxy: Galaxy) -> Int { PilotEconomy.freeMass(state, galaxy: galaxy) }
    func owned(outfit id: Int) -> Int { PilotEconomy.owned(state, outfit: id) }
    func held(cargo id: Int) -> Int { PilotEconomy.held(state, cargo: id) }
    func maxJumpHops(galaxy: Galaxy) -> Int { PilotEconomy.maxJumpHops(state, galaxy: galaxy) }
    func hasInstantJump(galaxy: Galaxy) -> Bool { PilotEconomy.hasInstantJump(state, galaxy: galaxy) }
    func jumpSpeedFactor(galaxy: Galaxy) -> Double { PilotEconomy.jumpSpeedFactor(state, galaxy: galaxy) }
    func hyperspaceNoJumpRadius(galaxy: Galaxy) -> Double { PilotEconomy.hyperspaceNoJumpRadius(state, galaxy: galaxy) }

    /// Systems revealed by map/chart outfits the player has acquired (`oütf`
    /// ModType 16). Unlike the old "owns a map ⇒ see the whole galaxy" flag,
    /// this is the concrete scoped set recorded at purchase/grant time (N jumps
    /// from where they bought it, or all-independent, or a govt class — see
    /// `NovaGame.mapRevealedSystems`). Empty on a fresh/legacy save.
    var chartedSystems: Set<Int> { state.chartedSystems ?? [] }

    // MARK: Transactions (return the number actually transacted)

    @discardableResult
    func buyCargo(id: Int, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        let n = PilotEconomy.buyCargo(&state, id: id, tons: tons, unitPrice: unitPrice, cargoFree: cargoFree)
        if n > 0 { save() }
        return n
    }

    @discardableResult
    func sellCargo(id: Int, tons: Int, unitPrice: Int) -> Int {
        let n = PilotEconomy.sellCargo(&state, id: id, tons: tons, unitPrice: unitPrice)
        if n > 0 { save() }
        return n
    }

    func tickJunkCargo(galaxy: Galaxy) {
        if PilotEconomy.tickJunkCargo(&state, galaxy: galaxy) { save() }
    }

    @discardableResult
    func collectCargo(id: Int, tons: Int, galaxy: Galaxy) -> Int {
        let n = PilotEconomy.collectCargo(&state, id: id, tons: tons, galaxy: galaxy)
        if n > 0 { save() }
        return n
    }

    @discardableResult
    func buyCommodity(_ c: Commodity, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        buyCargo(id: c.cargoID, tons: tons, unitPrice: unitPrice, cargoFree: cargoFree)
    }

    @discardableResult
    func sellCommodity(_ c: Commodity, tons: Int, unitPrice: Int) -> Int {
        sellCargo(id: c.cargoID, tons: tons, unitPrice: unitPrice)
    }

    func effectiveCost(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        PilotEconomy.effectiveCost(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
    }

    func rankPriceMultiplier(govt: Int, game: NovaGame) -> Double {
        PilotEconomy.rankPriceMultiplier(state, govt: govt, game: game)
    }

    func maxInstallable(_ o: OutfRes, galaxy: Galaxy) -> Int {
        PilotEconomy.maxInstallable(state, o, galaxy: galaxy)
    }

    func canBuyOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        PilotEconomy.canBuyOutfit(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
    }

    @discardableResult
    func buyOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        let ok = PilotEconomy.buyOutfit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        if ok { save() }
        return ok
    }

    @discardableResult
    func buyOutfit(_ o: OutfRes, count: Int, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        let bought = PilotEconomy.buyOutfit(&state, o, count: count, galaxy: galaxy, priceMultiplier: priceMultiplier)
        if bought > 0 { save() }
        return bought
    }

    @discardableResult
    func sellOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        let ok = PilotEconomy.sellOutfit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        if ok { save() }
        return ok
    }

    @discardableResult
    func sellOutfit(_ o: OutfRes, count: Int, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        let sold = PilotEconomy.sellOutfit(&state, o, count: count, galaxy: galaxy, priceMultiplier: priceMultiplier)
        if sold > 0 { save() }
        return sold
    }

    func tradeInValue(game: NovaGame) -> Int { PilotEconomy.tradeInValue(state, game: game) }

    func netPrice(of ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Int {
        PilotEconomy.netPrice(state, of: ship, game: game, priceMultiplier: priceMultiplier)
    }

    @discardableResult
    func buyShip(_ ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Bool {
        let ok = PilotEconomy.buyShip(&state, ship, game: game, priceMultiplier: priceMultiplier)
        if ok { save() }
        return ok
    }

    // MARK: Escort economics (ESCORTS.md §2.2, §5 — model-layer only)
    //
    // See `PilotEconomy`'s own escort-economics section for the design note;
    // these remain thin autosave-adding forwarders like everything else here.

    func escortAvailableToday(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        PilotEconomy.escortAvailableToday(ship, at: spob, day: day)
    }

    func escortHireStock(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
        PilotEconomy.escortHireStock(ship, at: spob, day: day)
    }

    func escortHireRemaining(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
        PilotEconomy.escortHireRemaining(state, ship, at: spob, day: day)
    }

    @discardableResult
    func hireEscort(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        let ok = PilotEconomy.hireEscort(&state, ship, at: spob, day: day)
        if ok { save() }
        return ok
    }

    @discardableResult
    func requestEscortUpgrade(recordID: Int, game: NovaGame) -> Int? {
        let target = PilotEconomy.requestEscortUpgrade(&state, recordID: recordID, game: game)
        if target != nil { save() }
        return target
    }

    func cancelEscortUpgrade(recordID: Int) {
        PilotEconomy.cancelEscortUpgrade(&state, recordID: recordID)
        save()
    }

    typealias EscortUpgradeResult = PilotEconomy.EscortUpgradeResult

    @discardableResult
    func applyPendingEscortUpgrades(at spob: SpobRes, game: NovaGame) -> [EscortUpgradeResult] {
        let results = PilotEconomy.applyPendingEscortUpgrades(&state, at: spob, game: game)
        if !results.isEmpty { save() }
        return results
    }

    func escortSellValue(for ship: ShipRes) -> Int { PilotEconomy.escortSellValue(for: ship) }

    @discardableResult
    func sellEscort(recordID: Int, game: NovaGame) -> Int? {
        let value = PilotEconomy.sellEscort(&state, recordID: recordID, game: game)
        if value != nil { save() }
        return value
    }
}
