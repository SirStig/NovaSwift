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

    public init(missionID: Int, acceptedDate: GameDate, deadline: GameDate?,
                cargoPickedUp: Bool, shipObjectivesRemaining: Int,
                visitedTravelStellar: Bool = false,
                travelSpobID: Int? = nil, returnSpobID: Int? = nil,
                resolvedCargoType: Int? = nil, resolvedCargoQty: Int? = nil) {
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
    }
}

/// Persisted runtime state of one `crön` background event.
public struct CronRuntime: Codable, Hashable, Sendable {
    public let cronID: Int
    /// Date the event became active (its OnStart has run); nil if not running.
    public var startedDate: GameDate?
    /// Date the event is scheduled to end (start + duration).
    public var endDate: GameDate?
    /// Earliest date the event may (re)start, enforcing pre/post hold-off.
    public var earliestStart: GameDate?

    public init(cronID: Int, startedDate: GameDate? = nil, endDate: GameDate? = nil,
                earliestStart: GameDate? = nil) {
        self.cronID = cronID
        self.startedDate = startedDate
        self.endDate = endDate
        self.earliestStart = earliestStart
    }

    public var isActive: Bool { startedDate != nil }
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
    public var legalRecord: [Int: Int]    // govt id → standing (+ good, − wanted)
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

    // Story
    public var setBits: Set<Int>          // the NCB control-bit vector
    public var date: GameDate
    public var activeMissions: [ActiveMission]
    public var completedMissions: Set<Int>
    public var failedMissions: Set<Int>
    public var cronRuntime: [Int: CronRuntime]  // cron id → its runtime state

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

    /// Whether system `id` has been revealed by a map/chart outfit (but not
    /// necessarily visited). See `chartedSystems`.
    public func isSystemCharted(_ id: Int) -> Bool { chartedSystems?.contains(id) ?? false }

    /// Record `ids` as revealed by a map/chart outfit. Idempotent (union).
    public mutating func chartSystems<S: Sequence>(_ ids: S) where S.Element == Int {
        chartedSystems = (chartedSystems ?? []).union(ids)
    }

    /// Clear the player's legal record with government `govt` (set standing back
    /// to neutral), or with *every* government when `govt == -1` — the effect of
    /// an acquired `oütf` ModType 21 ("clean legal record") item.
    public mutating func clearLegalRecord(govt: Int) {
        if govt == -1 { legalRecord.removeAll() } else { legalRecord[govt] = nil }
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
