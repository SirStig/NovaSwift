import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The pilot economy: cargo, outfits, ships, and hired/captured escorts as
/// pure operations on a `PlayerState`. Extracted from what used to be
/// Apple-app-only logic (`app/NovaSwift/Game/PilotStore.swift`, an
/// `ObservableObject` coupling this math to SwiftUI) so every frontend —
/// Apple's SwiftUI/SpriteKit app AND the Godot bridge — shares one
/// implementation instead of each reimplementing trade/outfit/shipyard rules.
///
/// Every function here takes the caller's `PlayerState` explicitly (`inout`
/// for mutations, by value for reads) rather than owning one. This type has
/// **no** disk I/O, no `@Published`, no autosave — persistence, save timing,
/// and UI reactivity are entirely the caller's job (see `PilotStore`, which
/// wraps this for the Apple app and calls `save()` after each mutation; the
/// Godot bridge does the analogous thing over its own `PlayerState`).
public enum PilotEconomy {

    // MARK: Derived, data-dependent queries

    /// Effective cargo capacity of the current hull + installed outfits, in tons.
    public static func cargoCapacity(_ state: PlayerState, galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.cargoCapacity
            ?? galaxy.game.ship(state.shipType)?.cargoSpace ?? 0
    }
    public static func cargoUsed(_ state: PlayerState) -> Int { state.usedCargoSpace }
    public static func cargoFree(_ state: PlayerState, galaxy: Galaxy) -> Int {
        max(0, cargoCapacity(state, galaxy: galaxy) - cargoUsed(state))
    }

    /// Free outfit mass remaining (hull free mass minus installed outfit mass).
    public static func freeMass(_ state: PlayerState, galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.freeMass
            ?? galaxy.game.ship(state.shipType)?.freeMass ?? 0
    }

    public static func owned(_ state: PlayerState, outfit id: Int) -> Int { state.outfits[id] ?? 0 }
    public static func held(_ state: PlayerState, cargo id: Int) -> Int { state.cargo[id] ?? 0 }

    /// Hyperlane hops a single hyperspace jump can cross, from installed outfits
    /// (multi-jump drives). 1 = standard single-jump.
    public static func maxJumpHops(_ state: PlayerState, galaxy: Galaxy) -> Int {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.maxJumpHops ?? 1
    }

    /// True if the ship has an instant-jump / jump-control outfit (`oütf` ModType
    /// 37): jumps skip the slow turn-and-align spin-up and fire almost instantly.
    public static func hasInstantJump(_ state: PlayerState, galaxy: Galaxy) -> Bool {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.instantJump ?? false
    }

    /// How much faster than stock the jump sequence runs, from hyperspace-speed
    /// outfits (`oütf` ModType 22). 1.0 = stock; each point of bonus is +1%,
    /// clamped so it stays a speed-up and never gets absurd. The scene divides
    /// its jump-phase durations by this.
    public static func jumpSpeedFactor(_ state: PlayerState, galaxy: Galaxy) -> Double {
        let bonus = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.hyperspaceSpeedBonus ?? 0
        return min(4.0, max(1.0, 1.0 + Double(bonus) / 100.0))
    }

    /// The no-jump zone's radius around a system's centre (`oütf` ModType 23,
    /// summed across fitted outfits; Bible: "standard radius is 1000"), clamped
    /// so it can never invert to a negative/zero radius from a large enough
    /// reduction.
    public static func hyperspaceNoJumpRadius(_ state: PlayerState, galaxy: Galaxy) -> Double {
        let bonus = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits)?.hyperspaceDistBonus ?? 0
        return max(0, 1000 + Double(bonus))
    }

    // MARK: Transactions (return the number actually transacted)

    /// Buy `tons` of the cargo stored under `id` (a standard `Commodity.cargoID`
    /// 0-5, or a `jünk` resource id 128+). Junk cargo shares `state.cargo` keyed
    /// by its raw junk id so contraband scanning and cargo-space accounting work
    /// uniformly across both trade systems.
    @discardableResult
    public static func buyCargo(_ state: inout PlayerState, id: Int, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        guard unitPrice > 0 else { return 0 }
        let affordable = state.credits / unitPrice
        let n = max(0, min(tons, cargoFree, affordable))
        guard n > 0 else { return 0 }
        state.credits -= n * unitPrice
        state.cargo[id, default: 0] += n
        return n
    }

    @discardableResult
    public static func sellCargo(_ state: inout PlayerState, id: Int, tons: Int, unitPrice: Int) -> Int {
        let held = state.cargo[id] ?? 0
        let n = max(0, min(tons, held))
        guard n > 0 else { return 0 }
        state.credits += n * unitPrice
        let left = held - n
        if left > 0 { state.cargo[id] = left } else { state.cargo[id] = nil }
        return n
    }

    /// Apply the two `jünk.Flags` cargo-bay side effects for one game-day of
    /// elapsed time (called once per calendar day, i.e. per jump/landing):
    /// Tribbles (0x0001) self-multiply to fill the remaining hold, and Perishable
    /// (0x0002) cargo decays away. The Bible documents the behaviors but not
    /// their rates, so this uses a modest, self-documenting model: tribbles grow
    /// ~50%/day (at least +1) capped at free cargo space; perishables lose
    /// ~25%/day (at least -1) until gone. Standard commodities (cargoID 0-5) are
    /// untouched. Returns whether anything changed (so a caller can decide to save).
    @discardableResult
    public static func tickJunkCargo(_ state: inout PlayerState, galaxy: Galaxy) -> Bool {
        guard !state.cargo.isEmpty else { return false }
        var changed = false
        for (id, qty) in state.cargo where qty > 0 {
            guard let j = galaxy.game.junk(id) else { continue }   // nil ⇒ standard commodity
            if j.multipliesInCargoHold {
                let room = cargoFree(state, galaxy: galaxy)
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
        return changed
    }

    /// Add up to `tons` of cargo `id` for free (no credit cost), clamped to the
    /// ship's remaining hold. Used for mined asteroid yield (`röid.YieldType`).
    /// Returns the tonnage actually stowed.
    @discardableResult
    public static func collectCargo(_ state: inout PlayerState, id: Int, tons: Int, galaxy: Galaxy) -> Int {
        let n = max(0, min(tons, cargoFree(state, galaxy: galaxy)))
        guard n > 0 else { return 0 }
        state.cargo[id, default: 0] += n
        return n
    }

    @discardableResult
    public static func buyCommodity(_ state: inout PlayerState, _ c: Commodity, tons: Int, unitPrice: Int, cargoFree: Int) -> Int {
        buyCargo(&state, id: c.cargoID, tons: tons, unitPrice: unitPrice, cargoFree: cargoFree)
    }

    @discardableResult
    public static func sellCommodity(_ state: inout PlayerState, _ c: Commodity, tons: Int, unitPrice: Int) -> Int {
        sellCargo(&state, id: c.cargoID, tons: tons, unitPrice: unitPrice)
    }

    /// The price actually charged/refunded for `o` on the player's current hull.
    /// Applies Bible `Flags 0x0200` (mass-proportional price = shipMass × Cost)
    /// via `Galaxy.effectiveCost`; a flat-priced outfit returns its plain `cost`.
    /// `priceMultiplier` folds in the port's rank `PriceMod` discount (1.0 = none).
    public static func effectiveCost(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        let base = galaxy.effectiveCost(of: o, forShip: state.shipType)
        return priceMultiplier == 1 ? base : max(1, Int((Double(base) * priceMultiplier).rounded()))
    }

    /// Best (lowest) rank `PriceMod` multiplier for `govt` from the player's
    /// active ranks — 90 → 0.9 (a 10% discount); 1.0 when no active rank modifies
    /// this govt. Per the Bible, `ränk.PriceMod` is a "percentage modifier to the
    /// prices of goods, outfits and ships at spaceports owned by this govt", so a
    /// single helper feeds the commodity market, outfitter, and shipyard alike.
    public static func rankPriceMultiplier(_ state: PlayerState, govt: Int, game: NovaGame) -> Double {
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
    public static func maxInstallable(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Int {
        galaxy.game.effectiveMaxInstallable(of: o.id, ownedOutfits: state.outfits)
    }

    /// Can the player buy `outfit` here — affordable at its effective price, fits
    /// in free mass, under its (expander-adjusted) max, and with a free gun/turret
    /// mount if it's a fixed-gun/turret item (Bible `Flags 0x0001/0x0002`)?
    public static func canBuyOutfit(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        guard state.credits >= effectiveCost(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier) else { return false }
        // Free-mass check uses the outfit's *effective* mass (Flags 0x0400
        // scales mass with the hull), matching how `freeMass` accounts for
        // already-installed outfits.
        let addedMass = galaxy.effectiveMass(of: o, forShip: state.shipType)
        if addedMass > 0, freeMass(state, galaxy: galaxy) < addedMass { return false }
        // A negative `.freeCargo` modifier (e.g. "Mass Expansion"/"Mass Retool")
        // sells cargo hold tons for equipment mass. Bible `shïp.Holds`: a
        // negative-signed hull "prevent[s] the player from purchasing mass
        // expansions" outright; and regardless of the hull, nothing evicts
        // cargo already loaded, so a sale that would leave less room than
        // what's aboard has to be rejected here — it's the only gate.
        let cargoDelta = o.value(of: .freeCargo)
        if cargoDelta < 0, let lo = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits) {
            if lo.blocksMassExpansion { return false }
            if cargoUsed(state) > lo.cargoCapacity + cargoDelta { return false }
        }
        let cap = maxInstallable(state, o, galaxy: galaxy)
        if cap > 0, owned(state, outfit: o.id) >= cap { return false }
        // Bible `Flags 0x0001/0x0002`: a fixed gun / turret consumes one of the
        // hull's `MaxGuns`/`MaxTurrets` mounts. Block the purchase when none are free.
        if o.isFixedGunOutfit || o.isTurretOutfit,
           let lo = galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits) {
            if o.isFixedGunOutfit, lo.freeGunSlots < 1 { return false }
            if o.isTurretOutfit, lo.freeTurretSlots < 1 { return false }
        }
        return true
    }

    /// One unit of `buyOutfit`'s effect. `buyOutfit` and its bulk sibling below
    /// both build on this so a "buy 1000" from the quantity prompt is one
    /// caller-side save, not a thousand.
    private static func buyOutfitUnit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double) -> Bool {
        guard canBuyOutfit(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier) else { return false }
        state.credits -= effectiveCost(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        state.grantOutfit(o.id)
        // Acquisition-time modifier effects that mutate campaign state: a map
        // (ModType 16) charts its scoped systems from *here*; an amnesty
        // (ModType 21) clears the legal record. Shared with the mission-grant
        // path (`StoryEngine.grantOutfit`).
        state.applyOutfitAcquisition(o, game: galaxy.game, fromSystem: state.currentSystem)
        // Bible `OnPurchase`: an NCB *set* expression run as a side effect of
        // buying (e.g. a permit that flips a story bit). Distinct from a mission
        // grant, which does not "buy" and so does not fire this.
        runOutfitScript(&state, o.onPurchase, game: galaxy.game)
        // Bible `Flags 0x0010`: "Remove any items of this type after purchase —
        // useful for permits and other intangible purchases." The effects above
        // (charted systems, cleared record, set bits) have already landed; this
        // just keeps the intangible item from sitting in inventory.
        if o.flags & 0x0010 != 0 {
            state.removeOutfit(o.id)
        }
        return true
    }

    @discardableResult
    public static func buyOutfit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        buyOutfitUnit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
    }

    /// Buy up to `count` of `o` in one transaction — the real game's Alt-click
    /// "how many?" quantity dialog — stopping as soon as a further unit would
    /// fail (insufficient credits, free mass, or an installed-count/mount cap;
    /// the same constraints a single purchase enforces, just repeated). Returns
    /// how many were actually bought.
    @discardableResult
    public static func buyOutfit(_ state: inout PlayerState, _ o: OutfRes, count: Int, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        var bought = 0
        while bought < count, buyOutfitUnit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier) {
            bought += 1
        }
        return bought
    }

    /// One unit of `sellOutfit`'s effect — see `buyOutfitUnit`.
    private static func sellOutfitUnit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double) -> Bool {
        guard owned(state, outfit: o.id) > 0 else { return false }
        // Bible `Flags 0x0008`: "This item can't be sold."
        guard o.flags & 0x0008 == 0 else { return false }
        state.credits += effectiveCost(state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
        state.removeOutfit(o.id)
        // Bible `OnSell`: the sibling NCB set expression, run when the item is sold.
        runOutfitScript(&state, o.onSell, game: galaxy.game)
        return true
    }

    /// EV Nova refunds outfits at full purchase price (the same effective,
    /// mass-proportional price they were bought at on this hull).
    @discardableResult
    public static func sellOutfit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, priceMultiplier: Double = 1) -> Bool {
        sellOutfitUnit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier)
    }

    /// The sell-side counterpart of the bulk `buyOutfit(_:count:...)` above.
    @discardableResult
    public static func sellOutfit(_ state: inout PlayerState, _ o: OutfRes, count: Int, galaxy: Galaxy, priceMultiplier: Double = 1) -> Int {
        var sold = 0
        while sold < count, sellOutfitUnit(&state, o, galaxy: galaxy, priceMultiplier: priceMultiplier) {
            sold += 1
        }
        return sold
    }

    /// Run an outfit's `OnPurchase`/`OnSell` NCB set expression against the live
    /// pilot, reusing the story engine's full set-op executor (bit set/clear,
    /// and any richer op a plugin encodes) so the effect matches how mission
    /// scripts run. No-op for the (overwhelmingly common) empty expression.
    private static func runOutfitScript(_ state: inout PlayerState, _ expr: String, game: NovaGame) {
        runControlBitSet(&state, expr, game: game)
    }

    /// Run an NCB control-bit *set* expression against the live pilot via the
    /// story engine's set-op executor. Shared by outfit `OnPurchase`/`OnSell` and
    /// ship `OnPurchase`/`OnRetire` hooks. No-op for the (common) empty expression.
    private static func runControlBitSet(_ state: inout PlayerState, _ expr: String, game: NovaGame) {
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
    public static func tradeInValue(_ state: PlayerState, game: NovaGame) -> Int {
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
    public static func netPrice(_ state: PlayerState, of ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Int {
        let hullCost = priceMultiplier == 1 ? ship.cost : Int((Double(ship.cost) * priceMultiplier).rounded())
        return max(0, hullCost - tradeInValue(state, game: game))
    }

    @discardableResult
    public static func buyShip(_ state: inout PlayerState, _ ship: ShipRes, game: NovaGame, priceMultiplier: Double = 1) -> Bool {
        let price = netPrice(state, of: ship, game: game, priceMultiplier: priceMultiplier)
        guard state.credits >= price, ship.id != state.shipType else { return false }
        // Bible `shïp.OnRetire`: the old hull is sold/replaced — run its retire NCB
        // set expression before it's gone. `OnPurchase`: run the new hull's on-buy
        // set expression after the swap. Both are usually empty (base-game hulls
        // rarely script story bits on trade-in), so this no-ops for most ships.
        if let oldShip = game.ship(state.shipType) {
            runControlBitSet(&state, oldShip.onRetire, game: game)
        }
        state.credits -= price
        state.shipType = ship.id
        state.shipName = ship.displayName
        runControlBitSet(&state, ship.onPurchase, game: game)
        // The old hull and everything installed on it are traded in together
        // (credited via `tradeInValue` above) — real EV Nova does NOT carry
        // outfits over to a new ship by default. The one exception is
        // `oütf.Flags 0x0004`, "this item stays with you when you trade
        // ships" (licenses/permits, star charts, and whatever else scenario
        // data flags this way) — everything else is gone with the old ship.
        state.outfits = state.outfits.filter { id, _ in
            (game.outfit(id)?.flags ?? 0) & 0x0004 != 0
        }
        // The new hull's own preinstalled outfits (shïp.outfits — turrets,
        // launchers, jammers, etc. it ships with stock) become owned so the
        // Outfitter/Ship-Info screens show them and they can be sold off like
        // any other installed item. `Galaxy.loadout` already folds these (and
        // the hull's built-in weapons) into the flown ship's stats/armament
        // unconditionally, so this doesn't change combat behavior — it's
        // purely so the player's inventory record matches what they're flying.
        for (oid, count) in ship.outfits {
            state.grantOutfit(oid, count: count)
        }
        // `armor`/`shield`/`fuel` are stored as raw absolute values with `nil`
        // meaning "uninitialized (full)". Left alone, the *old* ship's raw
        // numbers (e.g. 100/100) would carry over as a ceiling on the *new*
        // ship's stats (`min(100, newMax)`) — a much bigger hull departs at a
        // sliver of its real max instead of full. Reset to nil so the new
        // hull starts genuinely full, matching "buying a ship restores it to
        // full" like a real dealership handover.
        state.armor = nil
        state.shield = nil
        state.fuel = nil
        return true
    }

    // MARK: Escort economics (ESCORTS.md §2.2, §5 — model-layer only)
    //
    // The Bible's real player-facing escort system (bar "hire" flow, upgrade,
    // resale of a captured/hired escort) runs entirely on `shïp` fields, not
    // `përs`. These functions implement the *economics* (availability roll,
    // hire/upgrade charge, sell refund) as pure credit transactions against
    // `state.credits`; they don't own or validate an escort's fleet membership.

    /// Whether `ship` is offered for hire in the bar today. Bible `HireRandom`:
    /// "The percent chance that a ship of this type will be available for hire
    /// in the bar on a given day. A HireRandom of 0 means this ship will never
    /// be made available for hire" — note the zero-behavior matches
    /// `shïp.BuyRandom`'s "never" default, not `oütf.BuyRandom`'s "always"
    /// default. Mirrors the deterministic FNV-1a-hash-of-(day, spöb, item) roll
    /// `NovaEconomy`'s private `onOfferToday` uses for the sibling `BuyRandom`
    /// stocking mechanic — same stable-within-a-day, no-save-state contract.
    public static func escortAvailableToday(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
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
    public static func escortHireStock(_ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
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
    public static func escortHireRemaining(_ state: PlayerState, _ ship: ShipRes, at spob: SpobRes, day: Int) -> Int {
        max(0, escortHireStock(ship, at: spob, day: day)
            - state.escortsHired(shipType: ship.id, spob: spob.id, day: day))
    }

    /// The cap on simultaneous hired/captured/mission escorts — `EscortRecord`s
    /// in the roster, not bay-launched fighters. Not a Bible-documented field —
    /// no `shïp`/`flët` field or the EVN wiki describes a wing-size limit — this
    /// is a deliberate house rule.
    public static let maxEscorts = 9

    /// Hire `ship` as an escort at `spob` today: charge the up-front hire fee
    /// (`ShipRes.escortHireFee` = 10% of Cost) and register it in the persistent
    /// escort roster as a `.hired` ship, snapshotting its recurring daily fee.
    /// The live ship spawns from the roster the next time a system world is
    /// built (i.e. on takeoff), which is when a hired escort joins you in EV
    /// Nova. Returns false if not on offer today or the hire fee is unaffordable.
    @discardableResult
    public static func hireEscort(_ state: inout PlayerState, _ ship: ShipRes, at spob: SpobRes, day: Int) -> Bool {
        guard escortAvailableToday(ship, at: spob, day: day) else { return false }
        // The station's daily stock of this hull is finite; don't over-hire.
        guard escortHireRemaining(state, ship, at: spob, day: day) > 0 else { return false }
        guard state.escortWing.count < maxEscorts else { return false }
        let fee = ship.escortHireFee
        guard state.credits >= fee else { return false }
        state.credits -= fee
        state.registerEscort(shipType: ship.id, name: ship.name, origin: .hired,
                             hireFee: fee, dailyFee: ship.escortDailyFee)
        state.recordEscortHire(shipType: ship.id, spob: spob.id, day: day)
        return true
    }

    /// Queue escort record `recordID` for an upgrade to its hull's `UpgradeTo`.
    /// Bible `UpgradeTo`/`EscUpgrdCost`. No charge yet — the upgrade is only
    /// actually applied (hull swapped, `EscUpgrdCost` charged) the next time the
    /// player lands somewhere with a shipyard (see `applyPendingEscortUpgrades`),
    /// and can be canceled free any time before then (`cancelEscortUpgrade`).
    /// Returns the target hull's id, or nil if the escort can't upgrade.
    @discardableResult
    public static func requestEscortUpgrade(_ state: inout PlayerState, recordID: Int, game: NovaGame) -> Int? {
        guard let rec = state.escort(id: recordID), let ship = game.ship(rec.shipType),
              ship.escortUpgradesTo > 0, let target = game.ship(ship.escortUpgradesTo) else { return nil }
        state.setPendingEscortUpgrade(id: recordID, to: target.id)
        return target.id
    }

    /// Cancel a queued upgrade for escort `recordID` — free, since nothing was
    /// charged when it was requested.
    public static func cancelEscortUpgrade(_ state: inout PlayerState, recordID: Int) {
        state.clearPendingEscortUpgrade(id: recordID)
    }

    /// One escort's queued-upgrade outcome on landing, for the caller to post
    /// to the HUD.
    public struct EscortUpgradeResult {
        public let recordID: Int
        public let escortName: String
        public let newShipName: String
        /// False when the upgrade is still queued (unaffordable this landing).
        public let applied: Bool
    }

    /// Apply every queued escort upgrade that's now affordable — called on
    /// landing at a spöb with a shipyard (upgrades, like the real ones, are
    /// fitted at a shipyard, not just anywhere). Charges `EscUpgrdCost` and
    /// swaps the hull (`PlayerState.upgradeEscort`) for each affordable
    /// pending record; a record the player still can't afford stays queued for
    /// a later landing. No-op (returns empty) when `spob` has no shipyard.
    @discardableResult
    public static func applyPendingEscortUpgrades(_ state: inout PlayerState, at spob: SpobRes, game: NovaGame) -> [EscortUpgradeResult] {
        guard spob.hasShipyard else { return [] }
        var results: [EscortUpgradeResult] = []
        for rec in state.escortWing {
            guard let pendingID = rec.pendingUpgradeTo, let ship = game.ship(rec.shipType),
                  let target = game.ship(pendingID) else { continue }
            guard state.credits >= ship.escortUpgradeCost else {
                results.append(EscortUpgradeResult(recordID: rec.id, escortName: rec.name,
                                                    newShipName: target.name, applied: false))
                continue
            }
            state.credits -= ship.escortUpgradeCost
            state.upgradeEscort(id: rec.id, to: target.id, dailyFee: target.escortDailyFee)
            results.append(EscortUpgradeResult(recordID: rec.id, escortName: rec.name,
                                                newShipName: target.name, applied: true))
        }
        return results
    }

    /// Credits refunded for selling off a captured/hired escort of hull
    /// `ship`. Bible `EscSellValue`: "The amount of cash the player gets for
    /// selling off a captured escort of this type." ≤0 defaults to 10% of the
    /// ship's original `Cost` — confirmed the common case: all 284 swept retail
    /// `shïp` records have `EscSellValue == 0`, so this fallback is what real
    /// data actually exercises, not a rare edge case.
    public static func escortSellValue(for ship: ShipRes) -> Int {
        ship.escortSellValue > 0 ? ship.escortSellValue : Int(Double(ship.cost) * 0.1)
    }

    /// Sell captured escort `recordID` for its `escortSellValue`, removing it from
    /// the roster. Returns the credits received, or nil if the record is unknown.
    /// (Hired escorts are released, not sold — this is for captured ships.)
    @discardableResult
    public static func sellEscort(_ state: inout PlayerState, recordID: Int, game: NovaGame) -> Int? {
        guard let rec = state.escort(id: recordID), let ship = game.ship(rec.shipType) else { return nil }
        let value = escortSellValue(for: ship)
        state.credits += value
        state.removeEscort(id: recordID)
        return value
    }
}
