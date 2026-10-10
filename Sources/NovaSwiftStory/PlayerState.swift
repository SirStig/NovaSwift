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

    // The original's per-slot runtime (0x0043f100 / 0x00443c60). All optional
    // so older saves decode; nil reads as false / 0.

    /// The mission has failed. It stays listed until the player lands at its
    /// return stellar, where the failure is resolved (MS-07).
    public var failed: Bool?
    /// The objective-complete latch; OnShipDone and ShipDoneText fire on its
    /// first rise, and an auto-abort mission resolves there (MS-06).
    public var objectiveComplete: Bool?
    /// Mission ships destroyed, boarded, disabled and chased off — the
    /// original's goal counters A, B, C and E (MS-11).
    public var shipsDestroyed: Int?
    public var shipsBoarded: Int?
    public var shipsDisabled: Int?
    public var shipsChasedOff: Int?
    /// An escort-goal ship has been present, or an observe-goal ship seen.
    public var shipsSighted: Bool?
    /// The mission cargo has been unloaded at its drop-off point.
    public var cargoDelivered: Bool?
    /// The `mïsn.ShipName` STR# entry (1-based) rolled at accept for `<SN>`.
    public var shipNameEntry: Int?
    /// Identifies this slot while scripts run; a mission started twice by `S`
    /// has two slots (OQ D9).
    public var serial: Int?
    /// AI-14: auxiliary ships the mission can still bring in (nil = its
    /// full `AuxShipCount`). Spent as they jump in unless the mission has
    /// Flags 0x0010; survivors are credited back when the player leaves.
    public var auxShipsRemaining: Int?
    /// The special ships' system, resolved once at accept (0x0043e6f0):
    /// a system id, or −6 to follow the player. nil = no system (no ships),
    /// or a save from before this was resolved at accept.
    public var shipSystemID: Int?
    /// `shipSystemID` has been resolved for this slot (so a nil is final).
    public var shipSystemResolved: Bool?
    /// The one hull every special ship of this slot flies (mïsn Flags
    /// 0x0800, rolled at accept); nil = each ship rolls its own.
    public var lockedShipType: Int?
    /// The `mïsn.ShipSubtitle` STR# entry (1-based) rolled at accept.
    public var shipSubtitleEntry: Int?
    /// The mission slot (0…15) this mission occupies: activation takes the
    /// first free one, and the mission lists run in slot order.
    public var slot: Int?

    public var isFailed: Bool { failed ?? false }
    /// The mission cargo is aboard: loaded and not yet delivered.
    public var isCarryingCargo: Bool { cargoPickedUp && !(cargoDelivered ?? false) }

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

    /// The original's slot counters (0x00439500). `active` is set from the day
    /// the event triggers until it deactivates, holdoffs included; `holdoff`
    /// counts down a pre- or post-holdoff wait and `duration` the event itself
    /// (-1 once it has ended). nil in a save written before these existed:
    /// `StoryEngine` converts the old dates on first use.
    public var active: Bool?
    public var holdoff: Int?
    public var duration: Int?

    public init(cronID: Int, startedDate: GameDate? = nil, endDate: GameDate? = nil,
                earliestStart: GameDate? = nil, pendingStart: GameDate? = nil) {
        self.cronID = cronID
        self.startedDate = startedDate
        self.endDate = endDate
        self.earliestStart = earliestStart
        self.pendingStart = pendingStart
    }

    /// The event counts as running — for Contribute bits and news — from the
    /// day it triggers until it deactivates, holdoffs included.
    public var isActive: Bool { active ?? (startedDate != nil) }
}

/// Where a mission offered at the current landing would send the player, and
/// what it would load — the original's per-definition target table
/// (0x0043d240), resolved once per landing so the offer text, the BBS list and
/// the accepted mission all agree.
public struct MissionTargets: Codable, Hashable, Sendable {
    public var travelSpob: Int?
    public var returnSpob: Int?
    public var cargoType: Int
    public var cargoQty: Int
    public var deadline: GameDate?

    public init(travelSpob: Int?, returnSpob: Int?, cargoType: Int, cargoQty: Int, deadline: GameDate?) {
        self.travelSpob = travelSpob
        self.returnSpob = returnSpob
        self.cargoType = cargoType
        self.cargoQty = cargoQty
        self.deadline = deadline
    }
}

/// The original's mission-offer bookkeeping between system arrivals and
/// landings: the AvailRandom rolls, the resolved targets, and the bar /
/// spaceport offer lane (0x00448670).
public struct MissionOfferState: Codable, Sendable {
    /// Seed of this arrival's AvailRandom rolls (1…100 per mission).
    public var rollSeed: UInt64 = 0
    /// Missions whose roll was zeroed by an accept (a 0 roll always passes).
    public var zeroedRolls: Set<Int> = []
    /// Targets resolved since the last arrival or rebuild.
    public var targets: [Int: MissionTargets] = [:]
    /// The stellar the offer lists were last built for; nil forces a rebuild
    /// on the next landing (set after any mission success or failure).
    public var listStellar: Int?
    /// Lane offers accepted or refused: gone until the lane is rebuilt.
    public var removed: Set<Int> = []
    /// Lane offers whose activation failed: shown again only after the
    /// context changes away from the main spaceport.
    public var shown: Set<Int> = []
    /// The offer context last run (the `AvailLoc` value).
    public var context: Int?
    /// The landing's offer lists (`Mission_EvaluateMissionLists` 0x0043cf00):
    /// list 0 holds the mission computer's missions, list 1 every other
    /// spaceport location's (bar, main spaceport, shops), each by DispWeight.
    /// Built when the player lands somewhere new or a mission succeeds there;
    /// an accept only removes entries, it never adds any. nil = not built.
    public var computerList: [Int]?
    public var laneList: [Int]?

    public init() {}
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
    /// The upgrade mark (ShipState +0xBF): the `UpgradeTo` hull requested in
    /// the escort window. Applied (hull swap + `EscUpgrdCost` charge) by the
    /// fleet pass when the player leaves a shipyard stellar —
    /// `PilotEconomy.processEscortFleetAtStellar`. Free to clear before then.
    /// `nil` for old saves (no key present) via `Codable` synthesis.
    public var pendingUpgradeTo: Int?
    /// The sale mark (ShipState +0xBE): sold by the same fleet pass. Exclusive
    /// with `pendingUpgradeTo`. `nil` (no mark) for older saves.
    public var pendingSale: Bool?

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

/// Classes whose daily stock roll was redrawn today. The original keeps one
/// roll per ship class for the shipyard and one for the bar, redrawn at every
/// daily tick and again when that class is bought or hired (0x00492f30); the
/// port derives each day's roll from the date, so a redraw is a counter.
public struct StockRerolls: Codable, Sendable, Equatable {
    public var day: Int
    public var ships: [Int: Int] = [:]   // shïp id → shipyard redraws today
    public var hires: [Int: Int] = [:]   // shïp id → bar redraws today
    public init(day: Int) { self.day = day }
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
    /// The original's per-pilot Strict Play option, chosen at creation (default
    /// off) and saved with the pilot. Off, the player and their direct escorts
    /// fly at 1.5 × top speed. `nil` (an older save) reads as off.
    public var strictPlay: Bool?
    public var isStrictPlay: Bool { strictPlay ?? false }
    /// The chär DatePrefix / DateSuffix ("" / " NC"), copied at creation and
    /// kept with the pilot as the original does (pilot +0x5ede / +0x5eee); every
    /// displayed date wears them. `nil` in an older save (`OriginalText` then
    /// falls back to the first chär's).
    public var datePrefix: String?
    public var dateSuffix: String?

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
    /// the (usually intangible) map item being consumed. In the original a map
    /// writes discovery level 2 — the same as landing — so a charted system
    /// counts as explored for NCB `Exxx` and shows its services on the map
    /// (UI-04, `isSystemExplored`). Kept apart from `exploredSystems` only so
    /// the map can still tell visited from charted. Optional so older saves
    /// without the field still decode (like `fuel`/`armor`).
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
    /// The player's legal record, as the original keeps it: one reputation per
    /// **system** (system id → value, ±32000; a missing system is 0), with no
    /// per-government record at all (EC-02). Crimes flood outward from where
    /// they happen, mission rewards walk the galaxy (`SystemReputation`).
    /// Read it with `reputation(atSystem:)`. Nil only in a pilot saved before
    /// this existed, until `migrateLegalRecordIfNeeded` seeds it.
    public var systemReputation: [Int: Int]?
    /// **Legacy, read-only.** The per-government record pilots saved before
    /// EC-02 carry (govt id → standing). Kept decodable so the migration can
    /// seed `systemReputation` from it; nothing writes it any more.
    public var legalRecord: [Int: Int]
    /// **Legacy, read-only.** The old per-government, per-system combat
    /// component (govt id → system id → standing), read only by the migration.
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
    /// For stellars destroyed by **weapon fire** (`spöb.Strength` reached zero),
    /// the game-day count on which each went down. `spöb.DeadTime` ("Regenerate
    /// Time", days) is measured from here, so the day clock can bring a bombed
    /// planet back on schedule and fire its `OnRegen` bits — see
    /// `StoryEngine.regenerateDestroyedStellars`.
    ///
    /// Story-destroyed stellars (the mission `Y` op) deliberately do **not** get
    /// an entry: the `U` op is their only way back, exactly as EV Nova scripts
    /// them. Optional so older pilots still decode (treated as empty).
    public var stellarDestroyedOnDay: [Int: Int]?
    /// The strength each damaged-but-standing destroyable stellar has left
    /// (`spöb` id → points). The original keeps a stellar's live Strength
    /// across visits (OS-13), so a half-shot planet is still half-shot when
    /// the player returns. Optional so older pilots still decode.
    public var stellarStrengthLeft: [Int: Double]?

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

    /// The old one-offer-per-bar-per-day marker. The bar now offers every
    /// eligible mission in turn (`MissionOfferState`, MS-05); the field stays
    /// only so older saves decode unchanged.
    public var barOfferDays: [Int: Int]? = nil

    /// Shipyard (`hire: false`) or bar (`hire: true`) redraws of `shipType`'s
    /// roll on `day`.
    public func stockRerollCount(shipType: Int, hire: Bool, day: Int) -> Int {
        guard let r = stockRerolls, r.day == day else { return 0 }
        return (hire ? r.hires : r.ships)[shipType] ?? 0
    }

    /// Redraw `shipType`'s shipyard or bar roll for the rest of `day`.
    public mutating func rerollStock(shipType: Int, hire: Bool, day: Int) {
        var r = stockRerolls?.day == day ? stockRerolls! : StockRerolls(day: day)
        if hire { r.hires[shipType, default: 0] += 1 } else { r.ships[shipType, default: 0] += 1 }
        stockRerolls = r
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
    /// AI-13: days before each system (`sÿst` id) can call its
    /// reinforcement fleet again — `max(ReinfIntrval, 1)` after a call, 1
    /// after a ModType-44 inhibitor spends it; counted down by the daily tick.
    /// Optional for older saves.
    public var reinforcementRetriggerDays: [Int: Int]?
    /// AI-15: each stellar's garrison (`spöb` id → ships left in its defense
    /// pool, survivors credited back), persisted across visits. Absent =
    /// full `DefCount`. Dominated stellars regrow +1 a day at 1 in 450.
    public var stellarGarrisons: [Int: Int]?

    /// Whether this pilot's `outfits` already includes everything their hull came
    /// with — its `shïp.DefaultItems` **and** its `shïp.WeapType` stock weapons,
    /// materialised as the `oütf` ids that install them (see
    /// `PilotEconomy.hullFittings`). `outfits` is the single record of what the
    /// player owns, so the loadout aggregator adds neither on top of it for the
    /// player; NPCs still get their hull weapons, which is all that arms them.
    ///
    /// `nil` marks a save written before that was true, whose `outfits` lists only
    /// *bought* items; `PilotEconomy.migrateHullFittings` tops such a pilot up once
    /// and sets this. Every path that hands the player a hull — `PilotFactory.make`,
    /// `PilotEconomy.buyShip`, capture, a mission `C`/`E`/`H` swap — grants the
    /// fittings directly, so those start out already true.
    ///
    /// This replaced an earlier `hullDefaultsGranted` flag that covered only
    /// `DefaultItems`. Deliberately a *new* key: pilots migrated under the old one
    /// still need the weapon half, and would otherwise be skipped — and, once the
    /// loadout stopped applying hull weapons, would have been left unarmed.
    public var hullFittingsGranted: Bool? = nil

    // MARK: Original mission runtime (missions batch). Optional for save-compat.

    /// The story engine's random state, so every engine built over this pilot
    /// continues one sequence (the original has one global generator).
    public var storyRandomState: UInt64? = nil
    /// The rank most recently activated by `K` — the `<RRK>` wildcard.
    public var recentRank: Int? = nil
    /// Mission-offer rolls, targets and the offer lane.
    public var missionOffers: MissionOfferState? = nil
    /// Systems the player has landed in — exploration level 2, which (with a
    /// map reveal) shows a system's services on the galaxy map (UI-04).
    public var landedSystems: Set<Int>? = nil
    /// A `Q` message staged while landed, shown on the next launch (MS-18).
    public var pendingLaunchMessage: String? = nil
    /// Counter behind `ActiveMission.serial`.
    public var nextMissionSerial: Int? = nil
    /// `nëbu` ids whose OnExplore has run (once per game, OS-14).
    public var exploredNebulae: Set<Int>? = nil

    /// The original's 16 mission slots (ui_rules B6): activation fails when
    /// every slot is taken.
    public static let missionSlotCount = 16

    /// The stellar each active `öops` with `Stellar = −1` picked when it
    /// activated (one random inhabited stellar, `System_UpdateDisasterStates`
    /// 0x00424f90): öops id → `spöb` id. Optional for save-compat.
    public var disasterStellars: [Int: Int]? = nil

    /// Today's shipyard and bar re-rolls (EC-11, EC-19): buying a ship or hiring
    /// one redraws that class's daily roll. Optional for save-compat.
    public var stockRerolls: StockRerolls? = nil

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
        self.systemReputation = [:]
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
    public mutating func markStellarRegenerated(_ id: Int) {
        destroyedStellars?.remove(id)
        stellarDestroyedOnDay?[id] = nil
        stellarStrengthLeft?[id] = nil
    }
    /// Record stellar `id` as destroyed by **weapon fire** on `day`, so its
    /// `spöb.DeadTime` regeneration timer can run. Distinct from the story `Y`
    /// op above, which is permanent until a matching `U`.
    public mutating func markStellarShotDown(_ id: Int, onDay day: Int) {
        markStellarDestroyed(id)
        stellarStrengthLeft?[id] = nil
        stellarDestroyedOnDay = (stellarDestroyedOnDay ?? [:]).merging([id: day]) { old, _ in old }
    }

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
        escorts?[idx].pendingSale = nil                  // the two marks are exclusive
    }
    /// Mark `id` to be sold at the next shipyard (EC-22); clears an upgrade mark.
    public mutating func setPendingEscortSale(id: Int) {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return }
        escorts?[idx].pendingSale = true
        escorts?[idx].pendingUpgradeTo = nil
    }
    public mutating func clearPendingEscortSale(id: Int) {
        guard let idx = escorts?.firstIndex(where: { $0.id == id }) else { return }
        escorts?[idx].pendingSale = nil
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

    /// The player's reputation in `system` (EC-02). Positive is good standing,
    /// negative criminal.
    public func reputation(atSystem system: Int) -> Int { systemReputation?[system] ?? 0 }

    /// The player's reputation in the system they are in.
    public var reputationHere: Int { reputation(atSystem: currentSystem) }

    /// The old per-government standing `govt` held at `system`: the universal
    /// component plus the per-system combat component. Read only by the
    /// legal-record migration.
    public func legacyStanding(govt: Int, atSystem system: Int) -> Int {
        legalRecord[govt, default: 0] + (localLegalRecord?[govt]?[system] ?? 0)
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
    /// NCB `E`: the system's discovery level is above 0 — visited, revealed by
    /// a mission `X`, or charted by a map outfit (UI-04).
    public func isSystemExplored(_ id: Int) -> Bool {
        exploredSystems.contains(id) || (chartedSystems?.contains(id) ?? false)
    }
    public var playerIsMale: Bool { isMale }
}
