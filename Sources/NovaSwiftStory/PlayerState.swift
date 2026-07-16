import Foundation

/// Runtime progress of one accepted mission. The static definition lives in the
/// `MissionRes` (looked up by `missionID`); this holds only what changes as the
/// player plays: which sub-objectives are done and when it must be finished by.
public struct ActiveMission: Codable, Hashable, Sendable {
    public let missionID: Int
    public var acceptedDate: GameDate
    public var deadline: GameDate?      // nil = no time limit

    /// Cargo has been loaded aboard (relevant when pickup isn't "at start").
    public var cargoPickedUp: Bool
    /// Special-ship objectives still outstanding (destroy/disable/board count).
    /// 0 means the ship objective is satisfied (or there was none).
    public var shipObjectivesRemaining: Int
    /// The player has visited the travel stellar at least once.
    public var visitedTravelStellar: Bool

    /// The concrete travel/return stellar chosen when the mission was accepted.
    /// A mïsn's travel/return selector may be a random govt/inhabited code; we
    /// resolve it to one real spob id at accept time so the destination shown in
    /// briefings, the mission list, and the map arrow stays the same afterward.
    /// nil = the selector matched nothing, or a legacy save from before capture.
    public var travelSpobID: Int?
    public var returnSpobID: Int?

    /// The concrete cargo type/quantity resolved **once** at accept time. A
    /// mïsn's `CargoType == 1000` means "random standard commodity 0–5" and a
    /// `CargoQty <= -2` means "abs(qty) ± 50%"; both are rolled at accept and
    /// frozen here so pickup, drop-off and release all move the *same* concrete
    /// tonnage of the *same* commodity. `nil` = a non-random cargo mission or a
    /// legacy save from before this field existed (callers fall back to the
    /// static `mïsn` fields). Optional for save-compat (like `travelSpobID`).
    public var resolvedCargoType: Int?
    public var resolvedCargoQty: Int?

    /// The system the player was in when the mission was accepted — the concrete
    /// meaning of `mïsn.ShipSyst == -1` ("initial") and the anchor for `-5`
    /// ("adjacent to initial"). Frozen at accept so those special ships spawn in
    /// the right place. `nil` = a legacy save from before this field. Optional
    /// for save-compat (like `travelSpobID`).
    public var acceptSystemID: Int?

    public init(missionID: Int, acceptedDate: GameDate, deadline: GameDate?,
                cargoPickedUp: Bool, shipObjectivesRemaining: Int,
                visitedTravelStellar: Bool = false,
                travelSpobID: Int? = nil, returnSpobID: Int? = nil,
                resolvedCargoType: Int? = nil, resolvedCargoQty: Int? = nil,
                acceptSystemID: Int? = nil) {
        self.missionID = missionID
        self.acceptedDate = acceptedDate
        self.deadline = deadline
        self.cargoPickedUp = cargoPickedUp
        self.shipObjectivesRemaining = shipObjectivesRemaining
        self.visitedTravelStellar = visitedTravelStellar
        self.travelSpobID = travelSpobID
        self.returnSpobID = returnSpobID
        self.resolvedCargoType = resolvedCargoType
        self.resolvedCargoQty = resolvedCargoQty
        self.acceptSystemID = acceptSystemID
    }
}

/// Persisted runtime state of one `crön` background event.
public struct CronRuntime: Codable, Hashable, Sendable {
    public let cronID: Int
    /// Date the event became active (its OnStart has run); nil if not running.
    public var startedDate: GameDate?
    /// Date the event is scheduled to end (start + duration).
    public var endDate: GameDate?
    /// Earliest date the event may (re)start, enforcing post-holdoff after it ends.
    public var earliestStart: GameDate?
    /// Date OnStart fires once the event has been *activated* (all gates passed)
    /// but is holding for `PreHoldoff` days before starting. nil = not pending.
    public var pendingStart: GameDate?

    public init(cronID: Int, startedDate: GameDate? = nil, endDate: GameDate? = nil,
                earliestStart: GameDate? = nil, pendingStart: GameDate? = nil) {
        self.cronID = cronID
        self.startedDate = startedDate
        self.endDate = endDate
        self.earliestStart = earliestStart
        self.pendingStart = pendingStart
    }

    public var isActive: Bool { startedDate != nil }
}

/// How a ship under the player's command was acquired — this is what decides
/// whether it costs money. EV Nova charges a recurring daily fee for **hired**
/// escorts only; captured and mission-granted escorts are free.
public enum EscortOrigin: String, Codable, Sendable {
    /// Rented at a spaceport bar. Paid a flat hire fee up front and a recurring
    /// daily fee; released (not sold) and departs on its own if you can't pay.
    case hired
    /// Boarded and captured in combat. Free — no daily fee. Can be sold or
    /// upgraded at a shipyard, and stays until sold/released/destroyed.
    case captured
    /// Granted by a mission. Free, and only lasts the mission's duration.
    case mission
}

/// One ship in the player's persistent escort wing. This is the durable record
/// that survives save/reload and system jumps; the live `World.playerEscorts`
/// scene entities are (re)spawned from these when the player enters a system and
/// carry the matching `id` back so per-escort commands (release/upgrade/sell)
/// map to the right record. Kept in `NovaSwiftStory` next to `PlayerState`
/// because the roster is pilot-save state, not engine state.
public struct EscortRecord: Codable, Hashable, Sendable, Identifiable {
    /// Stable per-escort id assigned from `PlayerState.nextEscortID` at hire /
    /// capture time. Not a `shïp` id and not a live `entityID` — it's the link
    /// between this record and whatever scene ship currently represents it.
    public var id: Int
    /// The `shïp` resource id (the hull). Mutated in place when the escort is
    /// upgraded (`UpgradeTo`).
    public var shipType: Int
    /// Display name shown in the escort control window.
    public var name: String
    public var origin: EscortOrigin
    /// Flat price paid to hire (0 for captured/mission). Snapshotted at hire so
    /// the deal doesn't retroactively change.
    public var hireFee: Int
    /// Recurring daily upkeep in credits (0 for captured/mission). Charged per
    /// in-game day for `.hired` escorts; refreshed to the new hull's rate on
    /// upgrade.
    public var dailyFee: Int
    /// The mission this escort is tied to, when `origin == .mission`.
    public var missionID: Int?
    /// A requested-but-not-yet-charged `UpgradeTo` hull. Set by the "Upgrade"
    /// hail action; only actually applied (hull swap + `EscUpgrdCost` charge)
    /// the next time the player lands somewhere with a shipyard — see
    /// `PilotStore.applyPendingEscortUpgrades`. Free to cancel any time before
    /// then. `nil` for old saves (no key present) via `Codable` synthesis.
    public var pendingUpgradeTo: Int?

    public init(id: Int, shipType: Int, name: String, origin: EscortOrigin,
                hireFee: Int = 0, dailyFee: Int = 0, missionID: Int? = nil,
                pendingUpgradeTo: Int? = nil) {
        self.id = id
        self.shipType = shipType
        self.name = name
        self.origin = origin
        self.hireFee = hireFee
        self.dailyFee = dailyFee
        self.missionID = missionID
        self.pendingUpgradeTo = pendingUpgradeTo
    }
}

/// A planet's one-day escort-hire tally — how many of each hull the player has
/// hired at a specific shipyard on a specific day. Scoped to that single
/// (day, spöb) so it self-expires: the first hire on a new day or at a new
/// station replaces it wholesale.
public struct EscortHireTally: Codable, Sendable {
    public var day: Int
    public var spob: Int
    public var counts: [Int: Int]   // shïp id → hired today
    public init(day: Int, spob: Int, counts: [Int: Int] = [:]) {
        self.day = day
        self.spob = spob
        self.counts = counts
    }
}

/// The complete, serialisable player / campaign state — the "pilot file". Owns
/// the control-bit vector, mission log, ranks, standings and galaxy clock. This
/// is the single source of truth the story engine reads and mutates; combat,
/// trading and the UI layer share it too.
public struct PlayerState: Codable, Sendable {
    // Identity
    public var pilotName: String
    public var isMale: Bool
    public var unregisteredDays: Int

    // Assets
    public var credits: Int
    public var shipType: Int              // shïp id
    public var shipName: String
    public var outfits: [Int: Int]        // outfit id → quantity owned
    public var cargo: [Int: Int]          // cargo/commodity type → tons held

    // Persistence
    /// The durable `PilotRoster`/`PilotArchive` save this pilot belongs to, once
    /// bound. `nil` for a session that hasn't been adopted into the roster yet
    /// (e.g. the no-data demo path) — round-tripping it through `pilot.json`
    /// lets such a session still sync to the archive on its next autosave rather
    /// than being silently stuck un-persisted for the whole session.
    /// Optional so older saves without this field still decode (like `fuel`).
    public var rosterID: UUID?

    // Position & exploration
    public var currentSystem: Int
    /// The stellar object (`spöb`) id the player was docked at when the game was
    /// last saved, or `nil` if saved while in flight. EV Nova only ever saves
    /// while landed, so on load this is where the ship lifts off from — the
    /// fresh-build placement restores the ship just clear of that pad instead of
    /// dumping it at the system centre. Consumed (cleared) the moment the loaded
    /// session takes off, so it never lingers to mis-place a later system entry.
    /// Optional for save-compat (like `fuel`/`armor`).
    public var landedSpob: Int?
    /// The player ship's last known in-system position/heading, saved on every
    /// autosave regardless of whether the player is docked. `landedSpob` takes
    /// priority on load (it places the ship just off that pad, matching real
    /// EV Nova's "you always save landed" assumption); these fields are what
    /// let a save taken *while flying* — the periodic in-flight autosave,
    /// backgrounding the app mid-flight, etc. — restore the exact spot instead
    /// of falling back to the system centre. `nil` for a legacy save from
    /// before these fields existed, or a save taken before the ship ever moved.
    public var shipPositionX: Double?
    public var shipPositionY: Double?
    public var shipHeading: Double?
    public var exploredSystems: Set<Int>
    /// Systems revealed by a purchased/granted map or chart outfit (`oütf`
    /// ModType 16) but not physically visited — shown named on the galaxy map
    /// yet distinct from `exploredSystems`. A map is a one-shot reveal recorded
    /// here at acquisition time (see `applyOutfitAcquisition`), so it survives
    /// the (usually intangible) map item being consumed. Kept SEPARATE from
    /// `exploredSystems` on purpose: `exploredSystems` drives the NCB `Exxx`
    /// "has the player *been* to system X" test, and buying a chart must not
    /// satisfy a story gate that requires actually travelling there. Optional so
    /// older saves without the field still decode (like `fuel`/`armor`).
    public var chartedSystems: Set<Int>?
    /// Current hyperspace fuel, in the engine's units (100 = one jump). `nil`
    /// means "uninitialized" — treated as a full tank until the first jump/save.
    /// Optional (rather than defaulted) so older saves without this field decode
    /// via `decodeIfPresent` instead of failing `Codable` decode entirely.
    public var fuel: Double?
    /// Current hull (armor) and shield, carried across landings so damage
    /// persists — only an **inhabited** port restores them (free), an
    /// uninhabited rock does not. `nil` = uninitialized (full). Optional for the
    /// same save-compatibility reason as `fuel`. Shields still regenerate in
    /// flight; persisting them just preserves a damaged state through a dock
    /// where no repair was available.
    public var armor: Double?
    public var shield: Double?

    // pêrs (named characters) the player has interacted with. Optional for
    // save-compat (like `fuel`).
    /// `pêrs` ids the player has wronged (attacked/disabled) — they now hold a
    /// grudge and are hostile wherever they appear (`pêrs.Flags 0x0001`).
    public var persGrudges: Set<Int>?
    /// `pêrs` ids the player has destroyed — they cease to appear again (Bible:
    /// "as AI-people are killed off, they cease to appear in the game").
    public var defeatedPers: Set<Int>?
    /// `pêrs` ids whose one-time quote has already been shown (`Flags 0x0080`).
    public var shownPersQuotes: Set<Int>?

    // Reputation
    public var combatRating: Int
    /// The *universal* (mission-driven) component of legal standing per govt
    /// — the EVN wiki's Legal Status page: "status changes due to missions
    /// will be reflected universally." Combine with `localLegalRecord` via
    /// `effectiveLegalRecord`/`effectiveLegalRecords` to get the actual
    /// "displayed legal status" at a given system; don't read this alone for
    /// anything player-facing.
    public var legalRecord: [Int: Int]    // govt id → standing (+ good, − wanted)
    /// The *local* (combat/boarding/smuggling-driven) component of legal
    /// standing: govt id -> system id -> standing. Per the wiki: "Hostile
    /// actions against ships will be reflected locally", felt in full at the
    /// system it happened in and at reduced weight in a radius around it (see
    /// `LegalRecordPropagation.applyLocal`). Optional so pilots saved before
    /// this existed still decode (treated as empty), like `dominatedStellars`.
    public var localLegalRecord: [Int: [Int: Int]]?
    public var activeRanks: Set<Int>      // ränk ids currently held
    /// `spöb` ids the player has dominated via Demand Tribute. Each pays its
    /// `spöb.Tribute` (credits/day) automatically as the galaxy clock advances
    /// (see `StoryEngine.payDailyTribute`). Optional so pilots saved before this
    /// feature still decode (treated as empty). See docs/reverse-engineering/DOMINATION.md.
    public var dominatedStellars: Set<Int>?
    /// `spöb` ids destroyed by the story (SET op `Y`, "destroy stellar") and not
    /// since regenerated (`U`). Persisting this here (rather than only pushing it
    /// out through `GameServices.setStellarDestroyed`) carries galaxy mutation
    /// across sessions, so a planet a mission blew up stays destroyed after a
    /// save/reload. Optional so pilots saved before this feature still decode
    /// (treated as empty), like `fuel`.
    public var destroyedStellars: Set<Int>?

    /// The player's persistent escort wing — hired (paying a daily fee),
    /// captured (free), or mission-granted (free, temporary). Source of truth
    /// that survives save/reload and system jumps; `World.playerEscorts` is a
    /// transient scene view respawned from this on entering a system. The daily
    /// fee for `.hired` entries is deducted as the galaxy clock advances (see
    /// `StoryEngine.payDailyEscortFees`). Optional so pilots saved before the
    /// escort roster existed still decode (treated as empty), like `fuel`.
    public var escorts: [EscortRecord]?
    /// Monotonic counter backing `EscortRecord.id`, so a released-then-rehired
    /// escort never collides with a live one. Optional for save-compat.
    public var nextEscortRecordID: Int?

    /// Per-bar daily patron-offer marker: spöb id → the julian day this bar last
    /// rolled its one-per-day mission offer. The original never re-pestered you
    /// with the same patron every time you re-entered the bar the same day; this
    /// gates the roll to once per bar per day. Optional + defaulted for
    /// save-compat (older pilots decode as "no bar has rolled yet").
    public var barOfferDays: [Int: Int]? = nil

    /// Whether `spob`'s bar has already made its daily patron offer on `day`.
    public func barOffered(spob: Int, day: Int) -> Bool { barOfferDays?[spob] == day }

    /// Record that `spob`'s bar made its daily offer on `day`, pruning entries
    /// from earlier days so the map stays bounded to the bars visited today.
    public mutating func markBarOffered(spob: Int, day: Int) {
        var m = (barOfferDays ?? [:]).filter { $0.value == day }
        m[spob] = day
        barOfferDays = m
    }

    /// How many escorts of each hull the player has already hired *today at the
    /// current shipyard*, so the planet's limited daily stock of a given ship
    /// type can't be over-hired by re-opening the browser. Scoped to one
    /// (day, spöb) — the moment either changes, the whole tally is replaced.
    /// Optional for save-compat.
    public var escortHireTally: EscortHireTally? = nil

    /// Escorts of `shipType` already hired at `spob` on `day` (0 once the day or
    /// station changes, since the tally only tracks the current one).
    public func escortsHired(shipType: Int, spob: Int, day: Int) -> Int {
        guard let t = escortHireTally, t.day == day, t.spob == spob else { return 0 }
        return t.counts[shipType] ?? 0
    }

    /// Record one hire of `shipType` at `spob` on `day`, starting a fresh tally
    /// whenever the day or station differs from the last one.
    public mutating func recordEscortHire(shipType: Int, spob: Int, day: Int) {
        if var t = escortHireTally, t.day == day, t.spob == spob {
            t.counts[shipType, default: 0] += 1
            escortHireTally = t
        } else {
            escortHireTally = EscortHireTally(day: day, spob: spob, counts: [shipType: 1])
        }
    }

    // Story
    public var setBits: Set<Int>          // the NCB control-bit vector
    public var date: GameDate
    public var activeMissions: [ActiveMission]
    public var completedMissions: Set<Int>
    public var failedMissions: Set<Int>
    public var cronRuntime: [Int: CronRuntime]  // cron id → its runtime state
    /// Active `öops` disasters: öops id → the date its price effect expires.
    /// Optional for save-compatibility with pilots written before disasters
    /// existed (decodes to nil → treated as no active disasters).
    public var activeDisasters: [Int: GameDate]?

    public init(pilotName: String = "Captain",
                isMale: Bool = true,
                shipType: Int = 128,
                shipName: String = "",
                credits: Int = 0,
                currentSystem: Int = 128,
                date: GameDate = .defaultStart) {
        self.pilotName = pilotName
        self.isMale = isMale
        self.unregisteredDays = 0
        self.credits = credits
        self.shipType = shipType
        self.shipName = shipName
        self.outfits = [:]
        self.cargo = [:]
        self.currentSystem = currentSystem
        self.exploredSystems = [currentSystem]
        self.chartedSystems = []
        self.combatRating = 0
        self.legalRecord = [:]
        self.activeRanks = []
        self.setBits = []
        self.date = date
        self.activeMissions = []
        self.completedMissions = []
        self.failedMissions = []
        self.cronRuntime = [:]
        self.activeDisasters = [:]
    }

    // MARK: Convenience queries

    public func activeMission(_ id: Int) -> ActiveMission? {
        activeMissions.first { $0.missionID == id }
    }
    public func isMissionActive(_ id: Int) -> Bool { activeMission(id) != nil }

    /// Total cargo tons currently held (for free-hold checks on cargo missions).
    public var usedCargoSpace: Int { cargo.values.reduce(0, +) }

    // MARK: Mutation helpers used by the SET-op executor

    public mutating func setBit(_ n: Int)    { setBits.insert(n) }
    public mutating func clearBit(_ n: Int)  { setBits.remove(n) }
    public mutating func toggleBit(_ n: Int) {
        if setBits.contains(n) { setBits.remove(n) } else { setBits.insert(n) }
    }

    public mutating func grantOutfit(_ id: Int, count: Int = 1) {
        outfits[id, default: 0] += count
    }
    public mutating func removeOutfit(_ id: Int, count: Int = 1) {
        let remaining = (outfits[id] ?? 0) - count
        if remaining > 0 { outfits[id] = remaining } else { outfits[id] = nil }
    }

    /// Whether stellar `id` is currently destroyed (blown up by a story `Y` op
    /// and not since regenerated).
    public func isStellarDestroyed(_ id: Int) -> Bool { destroyedStellars?.contains(id) ?? false }
    /// Record stellar `id` as destroyed (idempotent) — the `Y` SET op.
    public mutating func markStellarDestroyed(_ id: Int) {
        destroyedStellars = (destroyedStellars ?? []).union([id])
    }
    /// Regenerate stellar `id` (undo a destroy) — the `U` SET op.
    public mutating func markStellarRegenerated(_ id: Int) { destroyedStellars?.remove(id) }

    /// Whether the player has dominated stellar `id`.
    public func hasDominated(_ id: Int) -> Bool { dominatedStellars?.contains(id) ?? false }
    /// Record stellar `id` as dominated (idempotent).
    public mutating func dominate(_ id: Int) { dominatedStellars = (dominatedStellars ?? []).union([id]) }
    /// Release stellar `id` from domination (it stops paying tribute).
    public mutating func releaseDomination(_ id: Int) { dominatedStellars?.remove(id) }

    // MARK: Escort roster helpers

    /// The player's escort wing (empty for pilots saved before the roster).
    public var escortWing: [EscortRecord] { escorts ?? [] }
    /// Escorts that cost a daily fee (rented at a bar).
    public var hiredEscorts: [EscortRecord] { escortWing.filter { $0.origin == .hired } }
    /// Total credits/day owed for the whole hired wing — what
    /// `StoryEngine.payDailyEscortFees` deducts each day.
    public var totalDailyEscortFee: Int { hiredEscorts.reduce(0) { $0 + $1.dailyFee } }

    /// Add `record` to the wing, returning it (id already assigned).
    @discardableResult
    public mutating func addEscort(_ record: EscortRecord) -> EscortRecord {
        escorts = (escorts ?? []) + [record]
        return record
    }
    /// Register a new escort, assigning it a fresh stable `id`. The single entry
    /// point for both hiring and capturing so ids never collide.
    @discardableResult
    public mutating func registerEscort(shipType: Int, name: String, origin: EscortOrigin,
                                        hireFee: Int = 0, dailyFee: Int = 0,
                                        missionID: Int? = nil) -> EscortRecord {
        let newID = nextEscortRecordID ?? 1
        nextEscortRecordID = newID + 1
        return addEscort(EscortRecord(id: newID, shipType: shipType, name: name,
                                      origin: origin, hireFee: hireFee, dailyFee: dailyFee,
                                      missionID: missionID))
    }
    /// Remove escort `id` from the wing (release/sell/depart/destroy). Returns the
    /// removed record, or nil if it wasn't in the roster.
    @discardableResult
    public mutating func removeEscort(id: Int) -> EscortRecord? {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return nil }
        return escorts?.remove(at: idx)
    }
    /// Look up an escort record by its stable id.
    public func escort(id: Int) -> EscortRecord? { escortWing.first { $0.id == id } }
    /// Queue `id` for an upgrade to `newShipType` — no charge yet; see
    /// `EscortRecord.pendingUpgradeTo`.
    public mutating func setPendingEscortUpgrade(id: Int, to newShipType: Int) {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return }
        escorts?[idx].pendingUpgradeTo = newShipType
    }
    /// Cancel a requested-but-not-yet-charged upgrade — free, since nothing was
    /// ever charged for it.
    public mutating func clearPendingEscortUpgrade(id: Int) {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return }
        escorts?[idx].pendingUpgradeTo = nil
    }
    /// Swap escort `id` to hull `newShipType` (an `UpgradeTo`), refreshing its
    /// daily fee to the new hull's rate (`dailyFee` supplied by the caller, which
    /// has the `shïp` record). Hired escorts keep paying — at the new rate.
    public mutating func upgradeEscort(id: Int, to newShipType: Int, dailyFee newDaily: Int) {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return }
        escorts?[idx].shipType = newShipType
        escorts?[idx].pendingUpgradeTo = nil
        if escorts?[idx].origin == .hired { escorts?[idx].dailyFee = newDaily }
    }

    /// Whether system `id` has been revealed by a map/chart outfit (but not
    /// necessarily visited). See `chartedSystems`.
    public func isSystemCharted(_ id: Int) -> Bool { chartedSystems?.contains(id) ?? false }

    /// Record `ids` as revealed by a map/chart outfit. Idempotent (union).
    public mutating func chartSystems<S: Sequence>(_ ids: S) where S.Element == Int {
        chartedSystems = (chartedSystems ?? []).union(ids)
    }

    /// Clear the player's legal record with government `govt` (set standing back
    /// to neutral), or with *every* government when `govt == -1` — the effect of
    /// an acquired `oütf` ModType 21 ("clean legal record") item. Clears both
    /// the universal and local (every system) components — a clean record
    /// wipes your history everywhere, not just where you're currently docked.
    public mutating func clearLegalRecord(govt: Int) {
        if govt == -1 {
            legalRecord.removeAll()
            localLegalRecord = nil
        } else {
            legalRecord[govt] = nil
            localLegalRecord?[govt] = nil
        }
    }

    /// The player's standing with `govt`, combining the universal (mission-
    /// driven) component with the local (combat/boarding/smuggling-driven)
    /// component at `system` — the EVN wiki's "displayed legal status." This
    /// is what player-facing reads (landing gates, hailing, status displays)
    /// should use, not `legalRecord` alone. `fallback` is returned only when
    /// *neither* component has ever been touched for this government
    /// (matches the common `?? govt.initialRecord` caller pattern).
    public func effectiveLegalRecord(govt: Int, atSystem system: Int, fallback: Int = 0) -> Int {
        guard legalRecord[govt] != nil || localLegalRecord?[govt]?[system] != nil else { return fallback }
        return legalRecord[govt, default: 0] + (localLegalRecord?[govt]?[system] ?? 0)
    }

    /// Every government's `effectiveLegalRecord` at `system` — the union of
    /// every government either component has ever touched. Used to seed a
    /// live `Diplomacy` when entering a system.
    public func effectiveLegalRecords(atSystem system: Int) -> [Int: Int] {
        var result = legalRecord
        for (govt, bySystem) in localLegalRecord ?? [:] {
            guard let local = bySystem[system], local != 0 else { continue }
            result[govt, default: 0] += local
        }
        return result
    }

    // MARK: pêrs interaction helpers
    public func persHoldsGrudge(_ id: Int) -> Bool { persGrudges?.contains(id) ?? false }
    public func isPersDefeated(_ id: Int) -> Bool { defeatedPers?.contains(id) ?? false }
    public mutating func recordPersGrudge(_ id: Int) { persGrudges = (persGrudges ?? []).union([id]) }
    public mutating func recordPersDefeated(_ id: Int) { defeatedPers = (defeatedPers ?? []).union([id]) }
    public mutating func markPersQuoteShown(_ id: Int) { shownPersQuotes = (shownPersQuotes ?? []).union([id]) }
    public func wasPersQuoteShown(_ id: Int) -> Bool { shownPersQuotes?.contains(id) ?? false }
}

// MARK: NCBTestContext conformance — lets any NCB test evaluate against a pilot.

extension PlayerState: NCBTestContext {
    public func isBitSet(_ n: Int) -> Bool { setBits.contains(n) }
    public func hasOutfit(_ id: Int) -> Bool { (outfits[id] ?? 0) > 0 }
    public func isSystemExplored(_ id: Int) -> Bool { exploredSystems.contains(id) }
    public var playerIsMale: Bool { isMale }
}
