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

    /// True if the ship has an instant-jump / jump-control outfit (`oütf` ModType
    /// 37): jumps skip the slow turn-and-align spin-up and fire almost instantly.
    func hasInstantJump(galaxy: Galaxy) -> Bool {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.instantJump ?? false
    }

    /// How much faster than stock the jump sequence runs, from hyperspace-speed
    /// outfits (`oütf` ModType 22). 1.0 = stock; each point of bonus is +1%,
    /// clamped so it stays a speed-up and never gets absurd. The scene divides
    /// its jump-phase durations by this.
    func jumpSpeedFactor(galaxy: Galaxy) -> Double {
        let bonus = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.hyperspaceSpeedBonus ?? 0
        return min(4.0, max(1.0, 1.0 + Double(bonus) / 100.0))
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
        // Bible `Flags 0x0010`: "Remove any items of this type after purchase
        // — useful for permits and other intangible purchases" (OUTFITTERS.md
        // §6). The effect (e.g. an unlocked NCB bit via a mission/plugin, or
        // just the one-time credits charge itself) has already happened above;
        // this just keeps the item from sitting in inventory as an ownable
        // good afterward — grant-then-immediately-remove nets the same "you
        // paid, it's gone" observable behavior the Bible describes.
        if o.flags & 0x0010 != 0 {
            state.removeOutfit(o.id)
        }
        save()
        return true
    }

    /// EV Nova refunds outfits at full purchase price.
    @discardableResult
    func sellOutfit(_ o: OutfRes) -> Bool {
        guard owned(outfit: o.id) > 0 else { return false }
        // Bible `Flags 0x0008`: "This item can't be sold" (OUTFITTERS.md §6).
        guard o.flags & 0x0008 == 0 else { return false }
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
        state.shipName = ship.displayName
        // Outfits carry over (EV Nova keeps persistent items); cargo stays, but is
        // dropped if it no longer fits the new, smaller hold — clamped on takeoff.
        save()
        return true
    }

    // MARK: Escort economics (ESCORTS.md §2.2, §5 — model-layer only)
    //
    // The Bible's real player-facing escort system (bar "hire" flow, upgrade,
    // resale of a captured/hired escort) runs entirely on `shïp` fields, not
    // `përs` — see ESCORTS.md §2. No hire-escort dialog, requisition dialog,
    // or persistent escort roster exists in this codebase yet (`PlayerState`
    // has no `escorts`-style field, and adding one is out of scope for this
    // file), so these functions implement the *economics* (availability roll,
    // hire/upgrade charge, sell refund) as pure credit transactions against
    // `state.credits`; they don't own or validate an escort's fleet
    // membership. Wiring an actual roster + UI (the hire-escort/
    // requisition-escort dialogs and "escort control menu" ESCORTS.md §2.2
    // names) is a follow-up once that data model exists.

    /// Whether `ship` is offered for hire in the bar today. Bible `HireRandom`:
    /// "The percent chance that a ship of this type will be available for hire
    /// in the bar on a given day. A HireRandom of 0 means this ship will never
    /// be made available for hire" (ESCORTS.md §2.2) — note the zero-behavior
    /// matches `shïp.BuyRandom`'s "never" default, not `oütf.BuyRandom`'s
    /// "always" default. Mirrors the deterministic FNV-1a-hash-of-(day, spöb,
    /// item) roll `NovaEconomy`'s private `onOfferToday` uses for the sibling
    /// `BuyRandom` stocking mechanic (`NovaEconomy.swift`) — duplicated here
    /// rather than shared since that helper is private and outside this
    /// file's edit scope; same stable-within-a-day, no-save-state contract.
    func escortAvailableToday(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        guard ship.hireRandom > 0 else { return false }   // HireRandom 0 = never hireable
        let percent = min(ship.hireRandom, 100)
        var hash: UInt64 = 14_695_981_039_346_656_037            // FNV-1a offset basis
        for value in [day, spob.id, ship.id] {
            for byte in withUnsafeBytes(of: Int64(value).bigEndian, Array.init) {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211                 // FNV-1a prime
            }
        }
        let roll = Int(hash % 100) + 1                           // 1...100
        return roll <= percent
    }

    /// Hire `ship` as an escort at `spob` today. The Bible documents
    /// `HireRandom` (availability) and the upgrade/resale fields but never a
    /// distinct "hire price" field — `Cost` is introduced once, for outright
    /// shipyard purchase (ESCORTS.md §2.2 "Pricing gap"). Charging `ship.cost`
    /// here is that doc's flagged inference, not a quoted Bible rule. Returns
    /// false if not on offer today or unaffordable; does not (can't yet, see
    /// above) add the hired ship to any roster.
    @discardableResult
    func hireEscort(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        guard escortAvailableToday(ship, at: spob, day: day) else { return false }
        guard state.credits >= ship.cost else { return false }
        state.credits -= ship.cost
        save()
        return true
    }

    /// Upgrade an escort of hull `ship` to `ship.escortUpgradesTo`, charging
    /// `ship.escortUpgradeCost`. Bible `UpgradeTo`/`EscUpgrdCost`: "the ID of
    /// the ship type that it can be upgraded to" / "the cost to upgrade an
    /// escort ship of this type to the next more advanced version"
    /// (ESCORTS.md §2.2). `escortUpgradesTo <= 0` means "not upgradeable".
    /// Returns the upgraded hull's `shïp` id on success (caller is
    /// responsible for actually swapping the roster entry once one exists).
    @discardableResult
    func upgradeEscort(_ ship: ShipRes) -> Int? {
        guard ship.escortUpgradesTo > 0 else { return nil }
        guard state.credits >= ship.escortUpgradeCost else { return nil }
        state.credits -= ship.escortUpgradeCost
        save()
        return ship.escortUpgradesTo
    }

    /// Credits refunded for selling off a captured/hired escort of hull
    /// `ship`. Bible `EscSellValue`: "The amount of cash the player gets for
    /// selling off a captured escort of this type." ≤0 defaults to 10% of the
    /// ship's original `Cost` (ESCORTS.md §2.2) — confirmed the common case:
    /// all 284 swept retail `shïp` records have `EscSellValue == 0`, so this
    /// fallback is what real data actually exercises, not a rare edge case.
    func escortSellValue(for ship: ShipRes) -> Int {
        ship.escortSellValue > 0 ? ship.escortSellValue : Int(Double(ship.cost) * 0.1)
    }

    /// Sell off an escort of hull `ship`, crediting `escortSellValue(for:)`.
    @discardableResult
    func sellEscort(_ ship: ShipRes) -> Bool {
        state.credits += escortSellValue(for: ship)
        save()
        return true
    }
}
