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

    /// The player's live `Loadout`: their hull fitted with exactly what
    /// `state.outfits` says they own, and nothing else.
    ///
    /// Both `include…: false` flags are the whole point. `state.outfits` is the
    /// single record of what the player has — *everything the hull came with*
    /// included: its `shïp.DefaultItems`, and its `shïp.WeapType` stock weapons
    /// materialised into the `oütf` ids that install them. Those are granted when
    /// the pilot is created (`PilotFactory.make`), when a hull is bought
    /// (`buyShip`), captured, or swapped by a mission op, and for older saves once
    /// by `migrateHullFittings`.
    ///
    /// Letting the aggregator fold either in *again* on top of that inventory
    /// double-counts: a hull bought with two turrets flew with four, and a stock
    /// Shuttle would fly two Light Blasters. NPC spawns pass `includeDefaultItems:
    /// false` for the unrelated Bible reason that AI ships ignore `DefaultItems`,
    /// but keep `includeHullWeapons: true` — that's the only thing arming them.
    public static func loadout(_ state: PlayerState, galaxy: Galaxy) -> Loadout? {
        galaxy.loadout(shipID: state.shipType, extraOutfits: state.outfits,
                       includeDefaultItems: false, includeHullWeapons: false)
    }

    /// Everything a hull hands its new owner, as owned `oütf` ids: the
    /// `DefaultItems` it ships with, plus the `WeapType`/`AmmoLoad` stock
    /// armament resolved through `NovaGame.outfitInstalling(weapon:)`.
    ///
    /// The Bible introduces both as the buyer's, not the hull's: `DefaultItems`
    /// are "up to eight default items with which to equip this ship when the
    /// player buys or captures one", and the weapon block is "which stock weapons
    /// to put on your ship when you first buy it". Materialising them is what
    /// makes them visible in the outfitter, counted against `MaxGun`/`MaxTur` and
    /// against free mass, and — the thing testers actually asked for — sellable.
    ///
    /// A weapon no outfit installs is omitted: it stays inherent to the hull, and
    /// `Galaxy.loadout(…includeHullWeapons: false)` keeps applying exactly those.
    /// - Parameter includeDefaultItems: pass `false` for the mission `C` op,
    ///   which keeps the player's own items and adds none of the hull's — but
    ///   still has to arm it.
    public static func hullFittings(_ ship: ShipRes, game: NovaGame,
                                    includeDefaultItems: Bool = true) -> [Int: Int] {
        var fittings: [Int: Int] = [:]
        if includeDefaultItems {
            for (oid, count) in ship.outfits where count > 0 {
                fittings[oid, default: 0] += count
            }
        }
        for w in ship.weapons {
            if let oid = game.outfitInstalling(weapon: w.id) {
                fittings[oid, default: 0] += max(1, w.count)
            }
            // `AmmoLoad` rounds arrive as the matching ammunition outfit, one
            // per round — the same unit `Loadout` counts them in.
            if w.ammo > 0, let ammoID = game.outfitLoadingAmmo(for: w.id) {
                fittings[ammoID, default: 0] += w.ammo
            }
        }
        return fittings
    }

    /// Grant `ship`'s fittings to a pilot taking delivery of it (new pilot,
    /// purchase, capture, mission hull swap) and mark them recorded.
    public static func grantHullFittings(_ state: inout PlayerState, ship: ShipRes, game: NovaGame) {
        state.hullFittingsGranted = true
        for (oid, count) in hullFittings(ship, game: game) {
            state.grantOutfit(oid, count: count)
        }
    }

    /// One-time save migration for pilots written before `state.outfits` recorded
    /// what their hull came with (see `PlayerState.hullFittingsGranted`). Tops the
    /// inventory up so every fitting of the *current* hull is owned at least as
    /// many times as the hull ships with, then marks the pilot migrated.
    ///
    /// It tops up rather than adds, because a pilot who bought or captured their
    /// current hull already received those fittings — adding again would duplicate
    /// them. Two consequences worth knowing: a fitting the player deliberately
    /// bought *extras* of keeps only what they bought, and one they had sold since
    /// is restored. Both are bounded by a single hull's fittings, and the
    /// alternative — skipping the top-up — would strip the guns off every existing
    /// pilot the moment the loadout stops applying hull weapons.
    ///
    /// Returns whether the pilot was migrated (so the caller can save).
    @discardableResult
    public static func migrateHullFittings(_ state: inout PlayerState, game: NovaGame) -> Bool {
        guard state.hullFittingsGranted != true else { return false }
        state.hullFittingsGranted = true
        let hull = state.shipType
        guard let ship = game.ship(hull) else {
            Log.pilot.error("migrateHullFittings: pilot's hull \(hull, privacy: .public) is not in the loaded data — nothing to top up")
            return true
        }
        var added = 0
        for (oid, count) in hullFittings(ship, game: game) {
            let owned = state.outfits[oid] ?? 0
            guard owned < count else { continue }
            state.grantOutfit(oid, count: count - owned)
            added += count - owned
        }
        Log.pilot.notice("migrateHullFittings: hull \(hull, privacy: .public) topped up, \(added, privacy: .public) item(s) added")
        return true
    }

    /// The fleet's cargo capacity in tons (`Player_ComputeFleetCargoCapacity`
    /// 0x00469760, EC-21): the player's hull and outfits plus the holds of every
    /// non-mission escort whose hull's InherentAI is below 3 (a freighter),
    /// capped at 32000. The trade center and the junk cargo effects use it.
    public static func cargoCapacity(_ state: PlayerState, galaxy: Galaxy) -> Int {
        let own = loadout(state, galaxy: galaxy)?.cargoCapacity
            ?? galaxy.game.ship(state.shipType)?.cargoSpace ?? 0
        var fleet = own
        for e in state.escortWing where e.missionID == nil {
            guard let hull = galaxy.game.ship(e.shipType), hull.inherentAI < 3 else { continue }
            fleet += max(0, hull.cargoSpace)
        }
        return min(32000, fleet)
    }
    public static func cargoUsed(_ state: PlayerState) -> Int { state.usedCargoSpace }
    public static func cargoFree(_ state: PlayerState, galaxy: Galaxy) -> Int {
        max(0, cargoCapacity(state, galaxy: galaxy) - cargoUsed(state))
    }

    /// The player ship's own cargo capacity (`Ship_ComputeShipTotalCargoCapacity`
    /// 0x0046a730): hull Holds plus every owned ModType-2 outfit's ModVal.
    /// Mission acceptance and pickups measure against this, not the fleet.
    public static func shipCargoCapacity(_ state: PlayerState, galaxy: Galaxy) -> Int {
        loadout(state, galaxy: galaxy)?.cargoCapacity ?? galaxy.game.ship(state.shipType)?.cargoSpace ?? 0
    }

    /// `Player_ComputeRemainingCargoSpace` 0x0046a7c0: the room left in the
    /// player ship itself. With freighter escorts the fleet's ordinary cargo
    /// fills the escorts first; mission cargo always rides in the player ship.
    public static func remainingCargoSpace(_ state: PlayerState, galaxy: Galaxy) -> Int {
        let own = shipCargoCapacity(state, galaxy: galaxy)
        let fleet = cargoCapacity(state, galaxy: galaxy)
        let total = state.usedCargoSpace
        let mission = missionCargo(state, game: galaxy.game).values.reduce(0, +)
        if own < fleet {
            let share = max(0, total - mission - (fleet - own))
            return own - (share + mission)
        }
        return own - total
    }

    /// Tons of each cargo type the active missions have aboard. The original
    /// keeps mission cargo in the mission slots, apart from the commodity bins
    /// and junk counts; NovaSwift merges it into `state.cargo`, so trading and
    /// fleet-wide hold operations subtract this first. Slots from older saves
    /// fall back to the static mïsn fields.
    public static func missionCargo(_ state: PlayerState, game: NovaGame) -> [Int: Int] {
        var tons: [Int: Int] = [:]
        for am in state.activeMissions where am.isCarryingCargo {
            let m = game.mission(am.missionID)
            let type = am.resolvedCargoType ?? m?.cargoType ?? -1
            let qty = am.resolvedCargoQty ?? m.map { abs($0.cargoQty) } ?? 0
            guard type >= 0, qty > 0 else { continue }
            tons[type, default: 0] += qty
        }
        return tons
    }

    /// Free outfit mass remaining (hull free mass minus installed outfit mass).
    public static func freeMass(_ state: PlayerState, galaxy: Galaxy) -> Int {
        loadout(state, galaxy: galaxy)?.freeMass
            ?? galaxy.game.ship(state.shipType)?.freeMass ?? 0
    }

    public static func owned(_ state: PlayerState, outfit id: Int) -> Int { state.outfits[id] ?? 0 }
    /// Tons of cargo `id` in the trade bins (`player+0x7a`) or junk counts —
    /// what the trade center shows and can sell (0x00465ea0). Mission cargo
    /// lives in its mission slot and is never part of it.
    public static func held(_ state: PlayerState, cargo id: Int, game: NovaGame) -> Int {
        max(0, (state.cargo[id] ?? 0) - (missionCargo(state, game: game)[id] ?? 0))
    }

    /// Route systems a single hyperspace jump crosses, from multi-jump outfits
    /// (ModType 32): `Σ ModVal`, at least 1 (FL-06).
    public static func maxJumpHops(_ state: PlayerState, galaxy: Galaxy) -> Int {
        loadout(state, galaxy: galaxy)?.maxJumpHops ?? 1
    }

    /// Fast jump (class Flags2 0x0020 or `oütf` ModType 37): the jump skips its
    /// brake; the cue-timed spin-up still runs (FL-06).
    public static func hasInstantJump(_ state: PlayerState, galaxy: Galaxy) -> Bool {
        loadout(state, galaxy: galaxy)?.instantJump ?? false
    }

    /// The `quickHyperjump` enhancement's reading of ModType 22: a jump-animation
    /// speed-up, 1.0 = stock, +1% a point, clamped. The original counts these
    /// outfits as travel days instead (`travelDays`).
    public static func jumpSpeedFactor(_ state: PlayerState, galaxy: Galaxy) -> Double {
        let bonus = loadout(state, galaxy: galaxy)?.hyperspaceSpeedBonus ?? 0
        return min(4.0, max(1.0, 1.0 + Double(bonus) / 100.0))
    }

    /// Days one hyperspace jump costs this pilot's own ship (FL-05): by hull
    /// mass, plus owned ModType-22 `count × ModVal`, at least 1. The jump runs
    /// the max of this and each attached escort's hull-only figure.
    public static func travelDays(_ state: PlayerState, galaxy: Galaxy) -> Int {
        galaxy.hyperspaceTravelDays(hull: state.shipType, ownedOutfits: state.outfits)
    }

    /// The no-jump zone's radius around a system's origin: 1000 plus the
    /// summed `oütf` ModType 23 (`count × ModVal`). The original squares it
    /// (0x00465610), so a reduction past zero grows the zone again — callers
    /// compare squares.
    public static func hyperspaceNoJumpRadius(_ state: PlayerState, galaxy: Galaxy) -> Double {
        let bonus = loadout(state, galaxy: galaxy)?.hyperspaceDistBonus ?? 0
        return 1000 + Double(bonus)
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

    /// Sell up to `tons` of cargo `id` from the trade bins. Mission cargo of
    /// the same commodity can't be sold (EC-27).
    @discardableResult
    public static func sellCargo(_ state: inout PlayerState, id: Int, tons: Int, unitPrice: Int,
                                 game: NovaGame) -> Int {
        let n = max(0, min(tons, held(state, cargo: id, game: game)))
        guard n > 0 else { return 0 }
        state.credits += n * unitPrice
        let left = (state.cargo[id] ?? 0) - n
        if left > 0 { state.cargo[id] = left } else { state.cargo[id] = nil }
        return n
    }

    /// The frame counter period of the junk cargo effects: the player tick
    /// runs them when the 0…1024 wrapping frame counter is a multiple of 250
    /// (EC-24) — five events every 1025 frames, the last gap 25 frames.
    public static let junkCargoFramePeriod = 1025

    /// Whether the junk cargo effects run on in-flight frame `frame` (the
    /// original's 0…1024 counter).
    public static func junkCargoEventDue(frame: Int) -> Bool {
        let f = ((frame % junkCargoFramePeriod) + junkCargoFramePeriod) % junkCargoFramePeriod
        return f % 250 == 0
    }

    /// One junk cargo event, in flight only (0x0044aa70, EC-24). Free space is
    /// measured once: while it is above zero, every tribble type (`jünk` Flags
    /// 0x1, including junk with both bits) grows one ton — so several types can
    /// overfill by a ton each — and every perishable type (Flags 0x2 alone)
    /// loses one ton.
    ///
    /// With no tribbles aboard the original tests a stack slot it never wrote
    /// (an original bug); the user ruled that perishables then never rot, so
    /// they rot only while a tribble type rides along with free space.
    /// Returns whether anything changed.
    @discardableResult
    public static func runJunkCargoEvent(_ state: inout PlayerState, galaxy: Galaxy) -> Bool {
        guard !state.cargo.isEmpty else { return false }
        let junk = state.cargo.keys.sorted().compactMap { id -> JunkRes? in
            guard (state.cargo[id] ?? 0) > 0 else { return nil }
            return galaxy.game.junk(id)
        }
        let tribbles = junk.filter(\.multipliesInCargoHold)
        guard !tribbles.isEmpty, cargoFree(state, galaxy: galaxy) > 0 else { return false }
        for j in tribbles { state.cargo[j.id, default: 0] += 1 }
        for j in junk where j.decaysInCargoHold && !j.multipliesInCargoHold {
            let left = (state.cargo[j.id] ?? 0) - 1
            state.cargo[j.id] = left > 0 ? left : nil
        }
        return true
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
    public static func sellCommodity(_ state: inout PlayerState, _ c: Commodity, tons: Int, unitPrice: Int,
                                     game: NovaGame) -> Int {
        sellCargo(&state, id: c.cargoID, tons: tons, unitPrice: unitPrice, game: game)
    }

    /// The price actually charged for `o` on the player's current hull
    /// (`Outfit_ComputeOutfitPurchasePrice` 0x0046e910): Bible `Flags 0x0200`
    /// scales it by hull mass, never below the base cost. Rank `PriceMod`
    /// never reaches outfits — the original computes the scaled price and
    /// throws it away (EC-10).
    public static func effectiveCost(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Int {
        galaxy.effectiveCost(of: o, forShip: state.shipType)
    }

    /// The effective per-player cap on `o`, folding in any owned `ModType 27`
    /// ("increase maximum") expanders that point at it. 0 = unlimited.
    public static func maxInstallable(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Int {
        galaxy.game.effectiveMaxInstallable(of: o.id, ownedOutfits: state.outfits)
    }

    /// Can the player buy `outfit` here — affordable at its effective price, fits
    /// in free mass, under its (expander-adjusted) max, and with a free gun/turret
    /// mount if it's a fixed-gun/turret item (Bible `Flags 0x0001/0x0002`)?
    public static func canBuyOutfit(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Bool {
        guard state.credits >= effectiveCost(state, o, galaxy: galaxy) else { return false }
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
        if cargoDelta < 0, let lo = loadout(state, galaxy: galaxy) {
            if lo.blocksMassExpansion { return false }
            if cargoUsed(state) > lo.cargoCapacity + cargoDelta { return false }
        }
        let cap = maxInstallable(state, o, galaxy: galaxy)
        if cap > 0, owned(state, outfit: o.id) >= cap { return false }
        if let ammoCap = ammoLimit(state, o, galaxy: galaxy), owned(state, outfit: o.id) >= ammoCap { return false }
        // Bible `Flags 0x0001/0x0002`: a fixed gun / turret consumes one of the
        // hull's `MaxGuns`/`MaxTurrets` mounts. Block the purchase when none are free.
        if o.isFixedGunOutfit || o.isTurretOutfit,
           let lo = loadout(state, galaxy: galaxy) {
            if o.isFixedGunOutfit, lo.freeGunSlots < 1 { return false }
            if o.isTurretOutfit, lo.freeTurretSlots < 1 { return false }
        }
        return true
    }

    /// The ammunition cap on `o` (`Outfit_ClampOutfitOwnedCountToCurrentLimits`
    /// 0x004656a0, EC-13): when its first modifier is ModType 3 and the weapon
    /// has a positive MaxAmmo, at most `MaxAmmo × mounted launchers` — so with
    /// no launcher none can be bought. nil when no ammo cap applies.
    public static func ammoLimit(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Int? {
        guard let first = o.modifiers.first, first.type == .ammunition,
              let w = galaxy.game.weapon(first.value), w.maxAmmo > 0 else { return nil }
        let launchers = loadout(state, galaxy: galaxy)?.weapons
            .filter { $0.id == w.id }.reduce(0) { $0 + $1.count } ?? 0
        return w.maxAmmo * launchers
    }

    /// Clamp every owned outfit to its current ownership limit — what the
    /// E/H hull swaps do after adding the new class's fittings (0x00449370 →
    /// `Outfit_ClampOutfitOwnedCountToCurrentLimits` 0x004656a0, MS-18): the
    /// ammunition cap of the launchers now mounted and the (expander-scaled)
    /// Max. A limit of 0 never clamps. Not reproduced: the original reuses the
    /// limit out-parameter across outfits without resetting it, so an outfit
    /// that hits no limit can be clamped by the previous one's.
    public static func clampOwnedOutfitsToLimits(_ state: inout PlayerState, galaxy: Galaxy) {
        for id in state.outfits.keys.sorted() {
            guard let owned = state.outfits[id], owned > 0, let o = galaxy.game.outfit(id) else { continue }
            var limit = maxInstallable(state, o, galaxy: galaxy)
            if let ammo = ammoLimit(state, o, galaxy: galaxy), ammo > 0 { limit = limit > 0 ? min(limit, ammo) : ammo }
            if limit > 0, limit < owned { state.outfits[id] = limit }
        }
    }

    /// One unit of `buyOutfit`'s effect. `buyOutfit` and its bulk sibling below
    /// both build on this so a "buy 1000" from the quantity prompt is one
    /// caller-side save, not a thousand.
    private static func buyOutfitUnit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Bool {
        guard canBuyOutfit(state, o, galaxy: galaxy) else { return false }
        state.credits -= effectiveCost(state, o, galaxy: galaxy)
        state.grantOutfit(o.id)
        // Acquisition-time modifier effects that mutate campaign state: a map
        // (ModType 16) charts its scoped systems from *here*; an amnesty
        // (ModType 21) clears the legal record. Shared with the mission-grant
        // path (`StoryEngine.grantOutfit`).
        let charted = state.applyOutfitAcquisition(o, game: galaxy.game, fromSystem: state.currentSystem)
        StoryEngine.exploreNebulae(charted, state: &state, game: galaxy.game)
        // Bible `OnPurchase`: an NCB *set* expression run as a side effect of
        // buying (e.g. a permit that flips a story bit). Distinct from a mission
        // grant, which does not "buy" and so does not fire this.
        runOutfitScript(&state, o.onPurchase, outfit: o, field: "OnPurchase", game: galaxy.game)
        // Bible `Flags 0x0010`: "Remove any items of this type after purchase —
        // useful for permits and other intangible purchases." The effects above
        // (charted systems, cleared record, set bits) have already landed; this
        // just keeps the intangible item from sitting in inventory.
        //
        // A pure star chart is consumed the same way even though the stock
        // records don't set that bit — see `OutfRes.isConsumableChart`. It's what
        // makes a chart re-buyable in the next region instead of a once-per-game
        // purchase that's greyed out at every port thereafter.
        if o.flags & 0x0010 != 0 || o.isConsumableChart {
            state.removeOutfit(o.id)
        }
        return true
    }

    @discardableResult
    public static func buyOutfit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy) -> Bool {
        buyOutfitUnit(&state, o, galaxy: galaxy)
    }

    /// Buy up to `count` of `o` in one transaction — the real game's Alt-click
    /// "how many?" quantity dialog — stopping as soon as a further unit would
    /// fail (insufficient credits, free mass, or an installed-count/mount cap;
    /// the same constraints a single purchase enforces, just repeated). Returns
    /// how many were actually bought.
    @discardableResult
    public static func buyOutfit(_ state: inout PlayerState, _ o: OutfRes, count: Int, galaxy: Galaxy) -> Int {
        // A consumed item leaves inventory the instant it's bought, so its `Max`
        // never stops the loop — "buy 1000" of a chart would charge for a
        // thousand copies of the same one-shot reveal. One per transaction.
        let limit = (o.flags & 0x0010 != 0 || o.isConsumableChart) ? min(count, 1) : count
        var bought = 0
        while bought < limit, buyOutfitUnit(&state, o, galaxy: galaxy) {
            bought += 1
        }
        return bought
    }

    /// Whether `o` can be sold back at all: the player owns one and it is not
    /// `oütf` Flags 0x0008 ("can't be sold") — the outfitter's sell rule
    /// (0x0048ea70).
    public static func canSellOutfit(_ state: PlayerState, _ o: OutfRes) -> Bool {
        owned(state, outfit: o.id) > 0 && o.flags & 0x0008 == 0
    }

    /// What one unit of `o` sells for (0x0048ea70): its purchase price on this
    /// hull, halved (truncated) unless the player holds more than they did when
    /// the outfitter opened — units bought this visit refund in full, newest
    /// first. `ownedAtOpen` nil means "all owned units predate this visit".
    public static func outfitSalePrice(_ state: PlayerState, _ o: OutfRes, galaxy: Galaxy, ownedAtOpen: Int?) -> Int {
        let price = effectiveCost(state, o, galaxy: galaxy)
        let held = owned(state, outfit: o.id)
        guard held <= (ownedAtOpen ?? held) else { return price }
        return Int(Double(price) * 0.5)
    }

    /// One unit of `sellOutfit`'s effect — see `buyOutfitUnit`. A sale that
    /// would take free mass from zero or more to below zero is refused.
    private static func sellOutfitUnit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, ownedAtOpen: Int?) -> Bool {
        guard canSellOutfit(state, o) else { return false }
        let price = outfitSalePrice(state, o, galaxy: galaxy, ownedAtOpen: ownedAtOpen)
        let before = rawFreeMass(state, galaxy: galaxy)
        var after = state
        after.removeOutfit(o.id)
        if let before, let left = rawFreeMass(after, galaxy: galaxy), left < 0, before >= 0 { return false }
        state.credits += price
        state.removeOutfit(o.id)
        // Bible `OnSell`: the sibling NCB set expression, run when the item is sold.
        runOutfitScript(&state, o.onSell, outfit: o, field: "OnSell", game: galaxy.game)
        return true
    }

    /// Free mass without the display clamp at zero.
    private static func rawFreeMass(_ state: PlayerState, galaxy: Galaxy) -> Int? {
        loadout(state, galaxy: galaxy).map { $0.massCapacity - $0.usedMass }
    }

    /// Sell one `o`. Units owned before this outfitter visit (`ownedAtOpen`)
    /// fetch half their price (EC-07).
    @discardableResult
    public static func sellOutfit(_ state: inout PlayerState, _ o: OutfRes, galaxy: Galaxy, ownedAtOpen: Int? = nil) -> Bool {
        sellOutfitUnit(&state, o, galaxy: galaxy, ownedAtOpen: ownedAtOpen)
    }

    /// The sell-side counterpart of the bulk `buyOutfit(_:count:...)` above.
    @discardableResult
    public static func sellOutfit(_ state: inout PlayerState, _ o: OutfRes, count: Int, galaxy: Galaxy, ownedAtOpen: Int? = nil) -> Int {
        var sold = 0
        while sold < count, sellOutfitUnit(&state, o, galaxy: galaxy, ownedAtOpen: ownedAtOpen) {
            sold += 1
        }
        return sold
    }

    /// Run an outfit's `OnPurchase`/`OnSell` NCB set expression against the live
    /// pilot, reusing the story engine's full set-op executor (bit set/clear,
    /// and any richer op a plugin encodes) so the effect matches how mission
    /// scripts run. No-op for the (overwhelmingly common) empty expression.
    private static func runOutfitScript(_ state: inout PlayerState, _ expr: String,
                                        outfit o: OutfRes, field: String, game: NovaGame) {
        runControlBitSet(&state, expr, game: game,
                         source: "oütf \(o.id) \"\(o.name)\" \(field)")
    }

    /// Run an NCB control-bit *set* expression against the live pilot via the
    /// story engine's set-op executor. Shared by outfit `OnPurchase`/`OnSell` and
    /// ship `OnPurchase`/`OnRetire` hooks. No-op for the (common) empty expression.
    /// `source` names the resource field running the expression, so every bit it
    /// writes is attributable in the log — see `StoryEngine.apply(set:source:)`.
    private static func runControlBitSet(_ state: inout PlayerState, _ expr: String,
                                         game: NovaGame, source: String) {
        guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let engine = StoryEngine(game: game, player: state)
        engine.apply(set: expr, source: source)
        state = engine.player
    }

    /// The shipyard's credit for the current ship (EC-09): see
    /// `LandedServices.tradeInValue`. `scale` is the port's rank price scale
    /// and `stellarTech` its tech level.
    public static func tradeInValue(_ state: PlayerState, game: NovaGame, scale: Float = 1, stellarTech: Int = 0) -> Int {
        LandedServices.tradeInValue(state, game: game, scale: scale, stellarTech: stellarTech)
    }

    /// Net price to switch to `ship`: its scaled price less the scaled trade-in.
    public static func netPrice(_ state: PlayerState, of ship: ShipRes, game: NovaGame, scale: Float = 1, stellarTech: Int = 0) -> Int {
        max(0, LandedServices.shipPrice(ship, scale: scale, stellarTech: stellarTech)
               - tradeInValue(state, game: game, scale: scale, stellarTech: stellarTech))
    }

    /// Buy `ship` (0x00492f30): credit the trade-in, run the old hull's
    /// OnRetire, charge the full scaled price, keep only the outfits that stay
    /// with the player (`oütf` Flags 0x0004), hand over the new hull's fittings,
    /// run its OnPurchase and redraw the class's shipyard roll for the day.
    @discardableResult
    public static func buyShip(_ state: inout PlayerState, _ ship: ShipRes, game: NovaGame, scale: Float = 1, stellarTech: Int = 0) -> Bool {
        let price = LandedServices.shipPrice(ship, scale: scale, stellarTech: stellarTech)
        let tradeIn = tradeInValue(state, game: game, scale: scale, stellarTech: stellarTech)
        guard state.credits + tradeIn >= price, ship.id != state.shipType else { return false }
        state.credits += tradeIn
        if let oldShip = game.ship(state.shipType) {
            runControlBitSet(&state, oldShip.onRetire, game: game,
                             source: "shïp \(oldShip.id) \"\(oldShip.name)\" OnRetire")
        }
        state.credits = max(0, state.credits - price)
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
        // Everything the new hull comes with — its preinstalled `DefaultItems`
        // (turrets, launchers, jammers) *and* its stock `WeapType` armament —
        // becomes owned, so the Outfitter and Ship Info show it and it can be
        // sold off like any other installed item. This is the *only* place those
        // enter the flown ship: `PilotEconomy.loadout` builds the player's hull
        // with both `include…` flags off, precisely so what's granted here isn't
        // folded in a second time on top of itself.
        grantHullFittings(&state, ship: ship, game: game)
        runControlBitSet(&state, ship.onPurchase, game: game,
                         source: "shïp \(ship.id) \"\(ship.name)\" OnPurchase")
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
        state.rerollStock(shipType: ship.id, hire: false, day: state.date.julianDay)
        return true
    }

    /// "Use As My Ship" (`Player_ReplaceShipWithCapturedHull` 0x00423fa0,
    /// EC-17): every outfit that does not stay with the player (`oütf` Flags
    /// 0x0004) goes with the old hull; the prize's stock armament and
    /// DefaultItems arrive; the old hull's OnRetire runs, then the prize's
    /// OnCapture; the old hull joins the wing as a captured escort when there
    /// is room. Returns whether the old hull was kept.
    @discardableResult
    public static func takeCommandOfCapturedHull(_ state: inout PlayerState, hull: Int, game: NovaGame) -> Bool {
        let oldType = state.shipType
        let kept = canAddEscort(state)
        state.outfits = state.outfits.filter { id, _ in (game.outfit(id)?.flags ?? 0) & 0x0004 != 0 }
        if let old = game.ship(oldType) {
            runControlBitSet(&state, old.onRetire, game: game, source: "shïp \(old.id) \"\(old.name)\" OnRetire")
        }
        state.shipType = hull
        if let prize = game.ship(hull) {
            state.shipName = prize.displayName
            grantHullFittings(&state, ship: prize, game: game)
            runControlBitSet(&state, prize.onCapture, game: game, source: "shïp \(prize.id) \"\(prize.name)\" OnCapture")
        }
        if kept {
            state.registerEscort(shipType: oldType, name: game.ship(oldType)?.name ?? "Escort", origin: .captured)
        }
        return kept
    }

    // MARK: Escort economics (ESCORTS.md §2.2, §5 — model-layer only)
    //
    // The Bible's real player-facing escort system (bar "hire" flow, upgrade,
    // resale of a captured/hired escort) runs entirely on `shïp` fields, not
    // `përs`. These functions implement the *economics* (availability roll,
    // hire/upgrade charge, sell refund) as pure credit transactions against
    // `state.credits`; they don't own or validate an escort's fleet membership.

    /// Whether `ship` is on the bar's hire list today (EC-19): one roll per
    /// class per day, shared by every bar, `HireRandom` 0 meaning never, and
    /// redrawn whenever that class is hired.
    public static func escortAvailableToday(_ state: PlayerState, _ ship: ShipRes, day: Int) -> Bool {
        NovaGame.hireable(ship, day: day, redraw: state.stockRerollCount(shipType: ship.id, hire: true, day: day))
    }

    /// The escort cap (`Ship_CanPlayerHaveMoreEscorts` 0x00468920): six
    /// non-mission escorts.
    public static let maxEscorts = 6

    /// Escorts counted against `maxEscorts`: mission escorts are extra.
    public static func escortsCounted(_ state: PlayerState) -> Int {
        state.escortWing.filter { $0.missionID == nil }.count
    }

    /// Whether the player may take on another escort.
    public static func canAddEscort(_ state: PlayerState) -> Bool {
        escortsCounted(state) < maxEscorts
    }

    /// The hire price at a port: a tenth of the scaled shipyard price (EC-09).
    public static func escortHirePrice(_ ship: ShipRes, scale: Float = 1, stellarTech: Int = 0) -> Int {
        LandedServices.hirePrice(ship, scale: scale, stellarTech: stellarTech)
    }

    /// Hire `ship` as an escort: charge the hire price and register it in the
    /// persistent escort roster as a `.hired` ship, snapshotting its recurring
    /// daily fee. The live ship spawns from the roster the next time a system
    /// world is built (i.e. on takeoff). Redraws the class's hire roll for the
    /// day. Returns false if not on offer, at the escort cap, or unaffordable.
    @discardableResult
    public static func hireEscort(_ state: inout PlayerState, _ ship: ShipRes, day: Int,
                                  scale: Float = 1, stellarTech: Int = 0) -> Bool {
        guard escortAvailableToday(state, ship, day: day) else { return false }
        guard canAddEscort(state) else { return false }
        let fee = escortHirePrice(ship, scale: scale, stellarTech: stellarTech)
        guard state.credits >= fee else { return false }
        state.credits -= fee
        state.registerEscort(shipType: ship.id, name: ship.name, origin: .hired,
                             hireFee: fee, dailyFee: ship.escortDailyFee)
        state.rerollStock(shipType: ship.id, hire: true, day: day)
        return true
    }

    /// The hull escort `recordID` would be upgraded to, when the escort window
    /// offers Upgrade (`NovaUi_RunEscortShipManagementWindow` 0x004853a0): the
    /// class has an `UpgradeTo` and that hull's availability expression passes.
    public static func escortUpgradeTarget(_ state: PlayerState, recordID: Int, game: NovaGame) -> ShipRes? {
        guard let rec = state.escort(id: recordID), let ship = game.ship(rec.shipType),
              ship.escortUpgradesTo >= 128, let target = game.ship(ship.escortUpgradesTo),
              NCBTest(target.availBits).evaluate(state) else { return nil }
        return target
    }

    /// Mark escort `recordID` for an upgrade at the next shipyard (EC-22). The
    /// original's Upgrade button is a toggle mark, processed by the fleet pass
    /// when the player leaves a shipyard stellar (`processEscortFleetAtStellar`);
    /// setting it clears a sale mark. Nothing is charged now. Returns the target
    /// hull's id, or nil when the escort can't upgrade.
    @discardableResult
    public static func requestEscortUpgrade(_ state: inout PlayerState, recordID: Int, game: NovaGame) -> Int? {
        guard let target = escortUpgradeTarget(state, recordID: recordID, game: game) else { return nil }
        state.setPendingEscortUpgrade(id: recordID, to: target.id)
        return target.id
    }

    /// Clear escort `recordID`'s upgrade mark.
    public static func cancelEscortUpgrade(_ state: inout PlayerState, recordID: Int) {
        state.clearPendingEscortUpgrade(id: recordID)
    }

    /// Whether the escort window offers Sell for escort `recordID`: never for a
    /// hired escort (the hired-origin mark, +0xbb) and never for a mission's.
    public static func canSellEscort(_ state: PlayerState, recordID: Int) -> Bool {
        guard let rec = state.escort(id: recordID) else { return false }
        return rec.origin != .hired && rec.missionID == nil
    }

    /// Mark escort `recordID` to be sold at the next shipyard (EC-22); setting
    /// it clears an upgrade mark. Returns false when the escort can't be sold.
    @discardableResult
    public static func requestEscortSale(_ state: inout PlayerState, recordID: Int) -> Bool {
        guard canSellEscort(state, recordID: recordID) else { return false }
        state.setPendingEscortSale(id: recordID)
        return true
    }

    /// Clear escort `recordID`'s sale mark.
    public static func cancelEscortSale(_ state: inout PlayerState, recordID: Int) {
        state.clearPendingEscortSale(id: recordID)
    }

    /// What one escort fleet pass did, for the caller's dialog and day cost.
    public struct EscortFleetPass: Sendable, Equatable {
        public var soldIDs: [Int] = []
        public var saleCredits = 0
        public var upgradedIDs: [Int] = []
        public var upgradeCost = 0

        public init() {}

        /// Escorts sold plus escorts upgraded; the visit costs half that many
        /// days (`SpaceportVisitDays.escortsSoldOrUpgraded`).
        public var transactions: Int { soldIDs.count + upgradedIDs.count }
    }

    /// The escort fleet pass run when the player leaves a spaceport
    /// (`Player_ProcessEscortFleetAtStellar` 0x004229d0, EC-22). Only at a
    /// stellar with a shipyard (flag 0x8):
    /// - every escort marked for sale that isn't disabled (`disabled`) or a
    ///   mission's is sold for its `escortSellValue` and leaves the wing;
    /// - then every escort marked for upgrade, not a mission's, whose class has
    ///   an `UpgradeTo` and whose `EscUpgrdCost` the player can now afford is
    ///   charged and changes hull (its loadout and ammo are the new class's).
    ///   An unaffordable one keeps its mark for a later shipyard.
    /// The payroll (`StoryEngine.processEscortPayroll`, one period) follows at
    /// every stellar; the caller runs it.
    @discardableResult
    public static func processEscortFleetAtStellar(_ state: inout PlayerState, spob: SpobRes, game: NovaGame,
                                                   disabled: Set<Int> = []) -> EscortFleetPass {
        var pass = EscortFleetPass()
        guard spob.hasShipyard else { return pass }
        for rec in state.escortWing where rec.pendingSale == true && rec.missionID == nil && !disabled.contains(rec.id) {
            guard let ship = game.ship(rec.shipType) else { continue }
            let value = escortSellValue(for: ship)
            state.credits += value
            pass.saleCredits += value
            pass.soldIDs.append(rec.id)
            state.removeEscort(id: rec.id)
        }
        for rec in state.escortWing where rec.pendingUpgradeTo != nil && rec.missionID == nil {
            guard let ship = game.ship(rec.shipType), ship.escortUpgradesTo >= 128,
                  let target = game.ship(ship.escortUpgradesTo),
                  ship.escortUpgradeCost <= state.credits else { continue }
            let cost = max(0, ship.escortUpgradeCost)
            state.credits -= cost
            pass.upgradeCost += cost
            pass.upgradedIDs.append(rec.id)
            state.upgradeEscort(id: rec.id, to: target.id, dailyFee: target.escortDailyFee)
        }
        return pass
    }

    /// The fleet pass's dialog text: "<Count> escort was / escorts were sold
    /// for a profit of <N> credits." then the same for upgrades (STR# 2002
    /// #298–#301, #32/#33; STR# 137 count words). Empty when nothing happened.
    public static func escortFleetPassText(_ pass: EscortFleetPass, game: NovaGame) -> String {
        let text = OriginalText(game: game)
        func line(_ count: Int, _ verb: Int, _ credits: Int) -> String {
            "\(text.capitalizedCountWord(count)) \(text.misc(count == 1 ? 298 : 299)) \(text.misc(verb)) "
                + "\(OriginalText.grouped(credits)) \(text.misc(credits < 2 ? 32 : 33))."
        }
        var parts: [String] = []
        if !pass.soldIDs.isEmpty { parts.append(line(pass.soldIDs.count, 300, pass.saleCredits)) }
        if !pass.upgradedIDs.isEmpty { parts.append(line(pass.upgradedIDs.count, 301, pass.upgradeCost)) }
        return parts.joined(separator: "\n\n")         // the original's two carriage returns
    }

    /// An escort leaving the wing takes its share of the fleet's cargo
    /// (`Player_TransferCargoAndJunkToEscortByRatio` 0x00469810, EC-21): with
    /// `ratio = min(1, recipientHolds / fleet)`, where the fleet is the
    /// player's holds plus every non-mission freighter escort's (InherentAI < 3),
    /// each commodity and junk stack loses `trunc(tons × ratio)`. Mission cargo
    /// (`missionCargo`, which NovaSwift keeps in the same dictionary) is never
    /// touched. Called when a freighter escort is destroyed, disabled or
    /// defects, and for any released escort. Returns the commodity tons moved
    /// (junk is lost, not handed over): what a disabled escort carries, and
    /// gives back if the player boards it to repair it (0x0045a3d0).
    @discardableResult
    public static func transferCargoToEscort(_ state: inout PlayerState, recipientHolds: Int,
                                             missionCargo: [Int: Int], galaxy: Galaxy) -> [Int: Int] {
        var movedCommodities: [Int: Int] = [:]
        var fleet = loadout(state, galaxy: galaxy)?.cargoCapacity ?? galaxy.game.ship(state.shipType)?.cargoSpace ?? 0
        for e in state.escortWing where e.missionID == nil {
            guard let hull = galaxy.game.ship(e.shipType), hull.inherentAI < 3 else { continue }
            fleet += max(0, hull.cargoSpace)
        }
        guard fleet > 0 else { return [:] }
        let ratio = min(1, Float(recipientHolds) / Float(fleet))
        for (type, held) in state.cargo {
            let mission = min(held, missionCargo[type] ?? 0)
            let own = held - mission
            guard own > 0 else { continue }
            let moved = Int(Float(own) * ratio)
            let left = max(0, own - moved) + mission
            state.cargo[type] = left > 0 ? left : nil
            if type >= 0, type < 128, moved > 0 { movedCommodities[type] = min(moved, own) }
        }
        return movedCommodities
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
}

/// The days a spaceport visit costs, run when the player leaves (FL-05). In the
/// original, landing itself costs nothing; the dock-and-launch sequence
/// (0x00455e10) runs one daily tick, the spaceport exit (0x00491f30) runs one
/// more if the outfitter bought or sold anything and four more if a ship was
/// bought — both flags clear on entering the spaceport, so one visit can cost
/// five extra days — and selling or upgrading escorts costs
/// `trunc((sold + upgraded) / 2)` (0x004229d0). Trade, the bar, the mission
/// computer and refuelling cost nothing.
public struct SpaceportVisitDays: Sendable, Equatable {
    public var outfitTransaction = false
    public var shipPurchase = false
    public var escortsSoldOrUpgraded = 0

    public init() {}

    /// Daily ticks to run on departure.
    public var departureDays: Int {
        1 + (outfitTransaction ? 1 : 0) + (shipPurchase ? 4 : 0) + escortsSoldOrUpgraded / 2
    }
}
