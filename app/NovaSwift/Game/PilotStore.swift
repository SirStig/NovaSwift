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
        let dir = base.appendingPathComponent("NovaSwift", isDirectory: true)
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

    /// Systems revealed by map/chart outfits the player has acquired (`oütf`
    /// ModType 16). Unlike the old "owns a map ⇒ see the whole galaxy" flag,
    /// this is the concrete scoped set recorded at purchase/grant time (N jumps
    /// from where they bought it, or all-independent, or a govt class — see
    /// `NovaGame.mapRevealedSystems`). Empty on a fresh/legacy save.
    var chartedSystems: Set<Int> { state.chartedSystems ?? [] }

    // MARK: Transactions (return the number actually transacted)

    /// Buy `tons` of the cargo stored under `id` (a standard `Commodity.cargoID`
    /// 0-5, or a `jünk` resource id 128+). Junk cargo shares `state.cargo` keyed
    /// by its raw junk id so contraband scanning (`Contraband.isContraband`) and
    /// cargo-space accounting work uniformly across both trade systems.
    @discardableResult
    func buyCargo(id: Int, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        guard unitPrice > 0 else { return 0 }
        let affordable = state.credits / unitPrice
        let n = max(0, min(tons, cargoFree, affordable))
        guard n > 0 else { return 0 }
        state.credits -= n * unitPrice
        state.cargo[id, default: 0] += n
        save()
        return n
    }

    @discardableResult
    func sellCargo(id: Int, tons: Int, unitPrice: Int) -> Int {
        let held = state.cargo[id] ?? 0
        let n = max(0, min(tons, held))
        guard n > 0 else { return 0 }
        state.credits += n * unitPrice
        let left = held - n
        if left > 0 { state.cargo[id] = left } else { state.cargo[id] = nil }
        save()
        return n
    }

    /// Apply the two `jünk.Flags` cargo-bay side effects for one game-day of
    /// elapsed time (called once per calendar day, i.e. per jump/landing):
    /// Tribbles (0x0001) self-multiply to fill the remaining hold, and Perishable
    /// (0x0002) cargo decays away. The Bible documents the behaviors but not their
    /// rates, so this uses a modest, self-documenting model: tribbles grow ~50%/day
    /// (at least +1) capped at free cargo space; perishables lose ~25%/day (at
    /// least -1) until gone. Standard commodities (cargoID 0-5) are untouched.
    func tickJunkCargo(galaxy: Galaxy) {
        guard !state.cargo.isEmpty else { return }
        var changed = false
        for (id, qty) in state.cargo where qty > 0 {
            guard let j = galaxy.game.junk(id) else { continue }   // nil ⇒ standard commodity
            if j.multipliesInCargoHold {
                let room = cargoFree(galaxy: galaxy)
                guard room > 0 else { continue }
                let grown = min(room, max(1, qty / 2))
                state.cargo[id] = qty + grown
                changed = true
            } else if j.decaysInCargoHold {
                let lost = max(1, qty / 4)
                let left = qty - lost
                state.cargo[id] = left > 0 ? left : nil
                changed = true
            }
        }
        if changed { save() }
    }

    @discardableResult
    func buyCommodity(_ c: Commodity, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        buyCargo(id: c.cargoID, tons: tons, unitPrice: unitPrice, cargoFree: cargoFree)
    }

    @discardableResult
    func sellCommodity(_ c: Commodity, tons: Int, unitPrice: Int) -> Int {
        sellCargo(id: c.cargoID, tons: tons, unitPrice: unitPrice)
    }

    /// The price actually charged/refunded for `o` on the player's current hull.
    /// Applies Bible `Flags 0x0200` (mass-proportional price = shipMass × Cost)
    /// via `Galaxy.effectiveCost`; a flat-priced outfit returns its plain `cost`.
    /// `priceMultiplier` folds in the port's rank `PriceMod` discount (1.0 = none).
    func effectiveCost(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        let base = galaxy.effectiveCost(of: o, forShip: state.shipType)
        return priceMultiplier == 1 ? base : max(1, Int((Double(base) * priceMultiplier).rounded()))
    }

    /// Best (lowest) rank `PriceMod` multiplier for `govt` from the player's
    /// active ranks — 90 → 0.9 (a 10% discount); 1.0 when no active rank modifies
    /// this govt. Per the Bible, `ränk.PriceMod` is a "percentage modifier to the
    /// prices of goods, outfits and ships at spaceports owned by this govt", so a
    /// single helper feeds the commodity market, outfitter, and shipyard alike.
    func rankPriceMultiplier(govt: Int, game: NovaGame) -> Double {
        guard govt >= 128 else { return 1 }
        var best = 1.0
        for rankID in state.activeRanks {
            guard let r = game.rank(rankID), r.govt == govt, r.priceModifier > 0 else { continue }
            best = min(best, Double(r.priceModifier) / 100.0)
        }
        return best
    }

    /// The effective per-player cap on `o`, folding in any owned `ModType 27`
    /// ("increase maximum") expanders that point at it. 0 = unlimited.
    func maxInstallable(_ o: OutfRes, galaxy: Galaxy) -> Int {
        galaxy.game.effectiveMaxInstallable(of: o.id, ownedOutfits: state.outfits)
    }

    /// Can the player buy `outfit` here — affordable at its effective price, fits
    /// in free mass, under its (expander-adjusted) max, and with a free gun/turret
    /// mount if it's a fixed-gun/turret item (Bible `Flags 0x0001/0x0002`)?
    func canBuyOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        guard state.credits >= effectiveCost(o, galaxy: galaxy, priceMultiplier: priceMultiplier) else { return false }
        // Free-mass check uses the outfit's *effective* mass (Flags 0x0400
        // scales mass with the hull), matching how `freeMass` accounts for
        // already-installed outfits.
        let addedMass = galaxy.effectiveMass(of: o, forShip: state.shipType)
        if addedMass > 0, freeMass(galaxy: galaxy) < addedMass { return false }
        let cap = maxInstallable(o, galaxy: galaxy)
        if cap > 0, owned(outfit: o.id) >= cap { return false }
        // Bible `Flags 0x0001/0x0002`: a fixed gun / turret consumes one of the
        // hull's `MaxGuns`/`MaxTurrets` mounts. Block the purchase when none are
        // free (OUTFITTERS.md §6 — previously computed but not enforced).
        if o.isFixedGunOutfit || o.isTurretOutfit,
           let lo = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits) {
            if o.isFixedGunOutfit, lo.freeGunSlots < 1 { return false }
            if o.isTurretOutfit, lo.freeTurretSlots < 1 { return false }
        }
        return true
    }

    @discardableResult
    func buyOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        guard canBuyOutfit(o, galaxy: galaxy, priceMultiplier: priceMultiplier) else { return false }
        state.credits -= effectiveCost(o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        state.grantOutfit(o.id)
        // Acquisition-time modifier effects that mutate campaign state: a map
        // (ModType 16) charts its scoped systems from *here*; an amnesty
        // (ModType 21) clears the legal record. Shared with the mission-grant
        // path (`StoryEngine.grantOutfit`).
        state.applyOutfitAcquisition(o, game: galaxy.game, fromSystem: state.currentSystem)
        // Bible `OnPurchase`: an NCB *set* expression run as a side effect of
        // buying (e.g. a permit that flips a story bit). Distinct from a mission
        // grant, which does not "buy" and so does not fire this.
        runOutfitScript(o.onPurchase, game: galaxy.game)
        // Bible `Flags 0x0010`: "Remove any items of this type after purchase —
        // useful for permits and other intangible purchases" (OUTFITTERS.md §6).
        // The effects above (charted systems, cleared record, set bits) have
        // already landed; this just keeps the intangible item from sitting in
        // inventory — grant-then-immediately-remove nets "you paid, it's gone".
        if o.flags & 0x0010 != 0 {
            state.removeOutfit(o.id)
        }
        save()
        return true
    }

    /// EV Nova refunds outfits at full purchase price (the same effective,
    /// mass-proportional price they were bought at on this hull).
    @discardableResult
    func sellOutfit(_ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        guard owned(outfit: o.id) > 0 else { return false }
        // Bible `Flags 0x0008`: "This item can't be sold" (OUTFITTERS.md §6).
        guard o.flags & 0x0008 == 0 else { return false }
        state.credits += effectiveCost(o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        state.removeOutfit(o.id)
        // Bible `OnSell`: the sibling NCB set expression, run when the item is sold.
        runOutfitScript(o.onSell, game: galaxy.game)
        save()
        return true
    }

    /// Run an outfit's `OnPurchase`/`OnSell` NCB set expression against the live
    /// pilot, reusing the story engine's full set-op executor (bit set/clear,
    /// and any richer op a plugin encodes) so the effect matches how mission
    /// scripts run. No-op for the (overwhelmingly common) empty expression.
    private func runOutfitScript(_ expr: String, game: NovaGame) {
        guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let engine = StoryEngine(game: game, player: state)
        engine.apply(set: expr)
        state = engine.player
    }

    /// Trade-in value of the current hull *and* its installed outfits, toward
    /// a new ship. Per the Bible: "The cost of buying a ship is always the
    /// cost of the new ship minus 25% of the original cost of your current
    /// ship and upgrades" — the credit covers everything currently installed,
    /// not just the bare hull.
    func tradeInValue(game: NovaGame) -> Int {
        let shipMass = game.ship(state.shipType)?.mass ?? 0
        let hullCost = game.ship(state.shipType)?.cost ?? 0
        // Value each installed outfit at what it actually cost on this hull —
        // mass-proportional-price outfits (Flags 0x0200) were charged
        // shipMass × Cost, so they trade in on the same basis, not flat `Cost`.
        let outfitsCost = state.outfits.reduce(0) { sum, owned in
            guard let o = game.outfit(owned.key) else { return sum }
            return sum + o.effectiveCost(shipMass: shipMass) * owned.value
        }
        return Int(Double(hullCost + outfitsCost) * 0.25)
    }

    /// Net price to switch to `ship` (its cost minus the current hull+outfits
    /// trade-in). `priceMultiplier` discounts the *new ship's* cost via the port's
    /// rank `PriceMod`; the trade-in credit reflects original value and is unscaled.
    func netPrice(of ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Int {
        let hullCost = priceMultiplier == 1 ? ship.cost : Int((Double(ship.cost) * priceMultiplier).rounded())
        return max(0, hullCost - tradeInValue(game: game))
    }

    @discardableResult
    func buyShip(_ ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Bool {
        let price = netPrice(of: ship, game: game, priceMultiplier: priceMultiplier)
        guard state.credits >= price, ship.id != state.shipType else { return false }
        state.credits -= price
        state.shipType = ship.id
        state.shipName = ship.displayName
        // The old hull and everything installed on it are traded in together
        // (credited via `tradeInValue` above) — real EV Nova does NOT carry
        // outfits over to a new ship by default. The one exception is
        // `oütf.Flags 0x0004`, "this item stays with you when you trade
        // ships" (licenses/permits, star charts, and whatever else scenario
        // data flags this way) — everything else is gone with the old ship.
        state.outfits = state.outfits.filter { id, _ in
            (game.outfit(id)?.flags ?? 0) & 0x0004 != 0
        }
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

    /// How many of `ship` the station has to hire out today — a deterministic
    /// 1...5 per (day, spöb, hull), stable within the day. EV Nova's escort
    /// stock varied by type (you might find one warship but five fighters), and
    /// no `shïp` field encodes a count, so this stands in for it, seeded like the
    /// availability roll but with an extra salt so the *count* doesn't track the
    /// *availability* roll. Only meaningful once `escortAvailableToday` passes.
    func escortHireStock(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037            // FNV-1a offset basis
        for value in [day, spob.id, ship.id, 0x1E5C07] {         // extra salt decorrelates count from availability
            for byte in withUnsafeBytes(of: Int64(value).bigEndian, Array.init) {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211                 // FNV-1a prime
            }
        }
        return 1 + Int(hash % 5)                                 // 1...5
    }

    /// How many of `ship` are still available to hire at `spob` today, after any
    /// the player has already hired here today.
    func escortHireRemaining(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
        max(0, escortHireStock(ship, at: spob, day: day)
            - state.escortsHired(shipType: ship.id, spob: spob.id, day: day))
    }

    /// Hire `ship` as an escort at `spob` today: charge the up-front hire fee
    /// (`ShipRes.escortHireFee` = 10% of Cost — see that property for why this is
    /// an engine constant, not a Bible field) and register it in the persistent
    /// escort roster as a `.hired` ship, snapshotting its recurring daily fee.
    /// The live ship spawns from the roster the next time a system world is built
    /// (i.e. on takeoff), which is when a hired escort joins you in EV Nova.
    /// Returns false if not on offer today or the hire fee is unaffordable.
    @discardableResult
    func hireEscort(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        guard escortAvailableToday(ship, at: spob, day: day) else { return false }
        // The station's daily stock of this hull is finite; don't over-hire.
        guard escortHireRemaining(ship, at: spob, day: day) > 0 else { return false }
        let fee = ship.escortHireFee
        guard state.credits >= fee else { return false }
        state.credits -= fee
        state.registerEscort(shipType: ship.id, name: ship.name, origin: .hired,
                             hireFee: fee, dailyFee: ship.escortDailyFee)
        state.recordEscortHire(shipType: ship.id, spob: spob.id, day: day)
        save()
        return true
    }

    /// Upgrade escort record `recordID` to its hull's `UpgradeTo`, charging
    /// `EscUpgrdCost`. Bible `UpgradeTo`/`EscUpgrdCost` (ESCORTS.md §2.2). Swaps
    /// the record's hull (and, for a hired escort, its daily fee) to the more
    /// advanced ship; the live ship takes the new hull the next time the wing is
    /// respawned (on takeoff / entering a system), i.e. the upgrade "applies at
    /// the next landing" as in EV Nova. Returns the new hull's id, or nil if the
    /// escort can't upgrade or the cost is unaffordable.
    @discardableResult
    func upgradeEscort(recordID: Int, game: NovaGame) -> Int? {
        guard let rec = state.escort(id: recordID), let ship = game.ship(rec.shipType),
              ship.escortUpgradesTo > 0, let target = game.ship(ship.escortUpgradesTo) else { return nil }
        guard state.credits >= ship.escortUpgradeCost else { return nil }
        state.credits -= ship.escortUpgradeCost
        state.upgradeEscort(id: recordID, to: target.id, dailyFee: target.escortDailyFee)
        save()
        return target.id
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

    /// Sell captured escort `recordID` for its `escortSellValue`, removing it from
    /// the roster. Returns the credits received, or nil if the record is unknown.
    /// (Hired escorts are released, not sold — this is for captured ships.)
    @discardableResult
    func sellEscort(recordID: Int, game: NovaGame) -> Int? {
        guard let rec = state.escort(id: recordID), let ship = game.ship(rec.shipType) else { return nil }
        let value = escortSellValue(for: ship)
        state.credits += value
        state.removeEscort(id: recordID)
        save()
        return value
    }
}
