import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The story/mission runtime. Owns the pilot's `PlayerState`, evaluates NCB
/// expressions, offers and tracks missions, applies rewards, and processes
/// `crön` background events against the galaxy clock.
///
/// It is the **plug-in target** the rest of the game feeds events into:
///   • the spaceport calls `missionsOffered(at:spob:)` and `accept`/`decline`
///   • combat/AI calls `missionShipDestroyed` / `…Disabled` / `…Boarded`
///   • navigation calls `playerJumped` / `playerLanded`
///   • the main loop calls `advanceOneDay()` once per game day
/// Everything the engine can't do itself (spawn ships, play sound, swap hull,
/// show text) goes out through `GameServices`, which starts as a logging stub
/// and gets real implementations as those systems come online.
public final class StoryEngine {
    public let game: NovaGame
    public internal(set) var player: PlayerState
    public weak var services: GameServices?
    /// The story's random generator. Seeded from the pilot's saved state when
    /// it has one, so the short-lived engines the app builds per event share
    /// one sequence; every draw goes through `random(_:)`, which saves it back.
    var rng: StoryRNG
    /// The mission whose script is running, for `Q` wildcard expansion.
    var scriptMission: MissionRes?
    /// Per-engine memo of "does this travel/return locator have any candidate
    /// stellar" (the RNG-free sanity gate in 0x00441b40).
    var locatorCandidateMemo: [Int: Bool] = [:]

    public init(game: NovaGame, player: PlayerState,
                services: GameServices? = nil, seed: UInt64 = 0xE7CA11) {
        self.game = game
        self.player = player
        self.services = services
        self.rng = StoryRNG(seed: player.storyRandomState ?? seed)
    }

    /// A uniform draw in `0..<n` (the original's `NovaRandom_Range`), with the
    /// generator's state written back to the pilot.
    func random(_ n: Int) -> Int {
        let v = rng.int(n)
        player.storyRandomState = rng.state
        return v
    }

    /// A seed that varies per landing (galaxy date × spob) but is **stable
    /// within one landing**, so mission random-appearance rolls actually change
    /// day to day and port to port — instead of the fixed default seed, which
    /// made every roll come out identically every visit (a mission's random %
    /// either always passed or always failed, so the bar always had the same
    /// patron). Stable within a landing keeps the bar and the mission BBS
    /// showing a consistent set while the player is docked.
    public static func landingSeed(player: PlayerState, spobID: Int) -> UInt64 {
        var h = UInt64(bitPattern: Int64(player.date.julianDay)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(spobID)) &* 0xD1B54A32D192ED03
        h ^= UInt64(player.pilotName.count) &* 0x2545F4914F6CDD1D
        return h == 0 ? 0xE7CA11 : h
    }

    // MARK: - NCB evaluation

    /// Evaluate a control-bit TEST expression against the current pilot.
    public func evaluate(test expr: String) -> Bool {
        NCBTest(expr).evaluate(player)
    }

    /// The `source` label `apply(set:source:)` records against every bit a SET
    /// expression writes: resource type, id, name and which field ran — e.g.
    /// `spöb 128 "Earth" OnDestroy`. Kept terse because it lands in a log line.
    func ncbSource(_ type: String, _ id: Int, _ name: String, _ field: String) -> String {
        name.isEmpty ? "\(type) \(id) \(field)" : "\(type) \(id) \"\(name)\" \(field)"
    }

    /// Parse and apply a control-bit SET expression (mission OnAccept/OnSuccess,
    /// cron OnStart/OnEnd, …).
    ///
    /// - Parameter source: a short human label for *which resource field* is
    ///   running this expression — "mïsn 615 OnAccept", "spöb 128 OnDestroy".
    ///   It is logged with every control bit the expression writes, which is the
    ///   only practical way to answer "why is bit N set on this pilot?" from a
    ///   tester's log. Control bits are write-only history: once set, nothing
    ///   records where they came from, and a wrongly-set bit silently changes
    ///   which missions the game offers for the rest of the playthrough. Chasing
    ///   one (`b6200`, which turned out to be fired by a planet the player had
    ///   accidentally destroyed) meant grepping the raw `.rez` by hand.
    /// - Parameter logBits: whether each bit write is logged at `.notice`. Only
    ///   an *iterative* crön hook passes `false`, and only past its first few
    ///   passes: those re-run the same expression up to `cronLoopCap` times, and
    ///   a thousand identical lines would evict the surrounding context that
    ///   makes a report readable. The runaway itself is still reported — see
    ///   `runCronHook`'s cap error.
    public func apply(set expr: String, source: String = "unattributed", logBits: Bool = true) {
        let ops = NCBSet.resolve(expr, pick: { random(2) })
        if ops.isEmpty, !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Every token in a non-empty SET expression was unrecognized/skipped —
            // this silently no-ops rather than throwing, so flag it: it usually
            // means a data-parsing gap or a malformed resource.
            Log.ncb.error("NCB apply: expression yielded no operations: \"\(expr, privacy: .public)\" (from \(source, privacy: .public))")
        }
        for op in ops { execute(op, source: source, logBits: logBits) }
        if !ops.isEmpty, let moved = refreshSystemState() {
            services?.movePlayer(toSystem: moved, keepPosition: true)
        }
    }

    private func execute(_ op: NCBSetOp, source: String, logBits: Bool = true) {
        Log.ncb.debug("NCB execute: \(String(describing: op), privacy: .public) (from \(source, privacy: .public))")
        switch op {
        // Bit writes log at `.notice`, not `.debug`: this is the audit trail a
        // bug report is read with, so it has to survive the console's default
        // level filter. "already set"/"already clear" is called out because a
        // re-run expression is itself a common bug shape.
        case .setBit(let n):
            let had = player.setBits.contains(n)
            player.setBit(n)
            if logBits {
                Log.ncb.notice("NCB bit b\(n, privacy: .public) SET by \(source, privacy: .public)\(had ? " (was already set)" : "")")
            }
        case .clearBit(let n):
            let had = player.setBits.contains(n)
            player.clearBit(n)
            if logBits {
                Log.ncb.notice("NCB bit b\(n, privacy: .public) CLEARED by \(source, privacy: .public)\(had ? "" : " (was already clear)")")
            }
        case .toggleBit(let n):
            player.toggleBit(n)
            let nowSet = player.setBits.contains(n)
            if logBits {
                Log.ncb.notice("NCB bit b\(n, privacy: .public) TOGGLED to \(nowSet ? "set" : "clear", privacy: .public) by \(source, privacy: .public)")
            }

        case .startMission(let id):  startMission(id)
        case .abortMission(let id):  abortMission(id, silent: true, manual: false)
        // `F` only latches the failure; OnFailure and FailText wait for the
        // landing at the return stellar (0x00449370, MS-18).
        case .failMission(let id):
            for i in player.activeMissions.indices where player.activeMissions[i].missionID == id {
                player.activeMissions[i].failed = true
            }

        case .grantOutfit(let id):
            player.grantOutfit(id)
            // A granted map/chart or amnesty (ModType 16/21) reveals its systems
            // / clears its legal record the same as a bought one — the effect is
            // inherent to acquiring the item, not to paying for it.
            if let o = game.outfit(id) {
                exploreNebulae(player.applyOutfitAcquisition(o, game: game, fromSystem: player.currentSystem))
            }
            services?.notify(.outfitGranted(outfitID: id))
        case .removeOutfit(let id):
            player.removeOutfit(id)
            services?.notify(.outfitRemoved(outfitID: id))

        case .moveToSystem(let id, let keep):
            player.currentSystem = id
            player.exploredSystems.insert(id)
            services?.movePlayer(toSystem: id, keepPosition: keep)

        case .changeShip(let id, let mode):
            applyShipChange(to: id, mode: mode)
            services?.changePlayerShip(to: id, mode: mode)

        case .activateRank(let id):
            activateRank(id)
        case .deactivateRank(let id):
            deactivateRank(id)

        case .playSound(let id):
            services?.playSound(id: id)

        // `Y` blows the stellar up and starts its DeadTime countdown; `U`
        // restores it at once. Neither runs the stellar's own OnDestroy /
        // OnRegen (0x00449370): a `Y`'d stellar regenerates on schedule, and
        // its OnRegen fires then, from the daily tick (MS-18).
        case .destroyStellar(let id):
            player.markStellarShotDown(id, onDay: player.date.julianDay)
            services?.setStellarDestroyed(spobID: id, destroyed: true)
        case .regenerateStellar(let id):
            player.markStellarRegenerated(id)
            services?.setStellarDestroyed(spobID: id, destroyed: false)

        // `X` writes discovery level 1: explored for `E`, services still
        // unknown on the map (UI-04).
        case .exploreSystem(let id):
            player.exploredSystems.insert(id)

        // `T` renames the ship to a random entry of the STR#, with `*` standing
        // for the old name; an empty entry keeps the name.
        case .changeShipTitle(let strID):
            if let title = randomStringListEntry(strID), !title.isEmpty {
                player.shipName = title.replacingOccurrences(of: "*", with: player.shipName)
            }

        // `Q` stages a random STR# entry, with the running mission's wildcards
        // expanded. In flight it shows at once; landed, it closes the open
        // spaceport screen and shows at the next launch (OQ D2, MS-18).
        case .leaveStellar(let msgStr):
            guard let strID = msgStr else { return }
            var msg = randomStringListEntry(strID) ?? ""
            if let m = scriptMission { msg = resolveMissionText(msg, for: m) }
            if player.landedSpob != nil {
                player.pendingLaunchMessage = msg
                services?.closeSpaceportScreen()
            } else if !msg.isEmpty {
                services?.showOverlayMessage(msg)
            }

        case .random(let choices):
            // EV Nova's R(a b) picks one of the (up to two) ops at 50/50.
            if choices.isEmpty { return }
            let pick = choices.count == 1 ? choices[0] : choices[random(choices.count)]
            execute(pick, source: source, logBits: logBits)
        }
    }

    /// `K` (0x00427df0). Flags 0x0001 clears the government's other ranks and
    /// 0x0010 its lower-weight ones, sparing permanent (0x0008) siblings. The
    /// rank becomes `<RRK>` even when it was already held.
    private func activateRank(_ id: Int) {
        if !player.activeRanks.contains(id) {
            player.activeRanks.insert(id)
            if let r = game.rank(id) {
                if r.flags & 0x0001 != 0 { clearSiblingRanks(of: r, lowerWeightOnly: false) }
                if r.flags & 0x0010 != 0 { clearSiblingRanks(of: r, lowerWeightOnly: true) }
            }
            services?.notify(.rankActivated(rankID: id))
        }
        player.recentRank = id
    }

    /// `L` (0x00427f40) always clears an active rank, permanent or not: 0x0008
    /// only shields a rank from its siblings' cascades. Flags 0x0002 clears the
    /// government's other ranks and 0x0020 its lower-weight ones (MS-03).
    private func deactivateRank(_ id: Int) {
        let wasActive = player.activeRanks.contains(id)
        player.deactivateRank(id, game: game)
        if wasActive { services?.notify(.rankDeactivated(rankID: id)) }
    }

    private func clearSiblingRanks(of rank: RankRes, lowerWeightOnly: Bool) {
        player.clearSiblingRanks(of: rank, lowerWeightOnly: lowerWeightOnly, game: game)
    }

    // MARK: - Ship change (C / E / H)

    /// Apply the SET `C`/`E`/`H` ship-change ops to `player.shipType` **and**
    /// `player.outfits`, per the Bible's three distinct modes:
    ///   • `C` (`.keepOutfits`)       — keep every current outfit, add nothing.
    ///   • `E` (`.addDefaultOutfits`) — keep current outfits AND add the new
    ///                                  hull's built-in (default) outfits.
    ///   • `H` (`.defaultOutfits`)    — drop non-persistent outfits, then add the
    ///                                  new hull's built-in outfits.
    ///
    /// Only the hull's preinstalled `oütf` items (`ShipRes.outfits`) are added to
    /// `player.outfits`. The hull's built-in **weapons** (`ShipRes.weapons`) are
    /// wëap ids, not oütf ids, and are applied to the effective ship by the
    /// loadout layer (`Loadout.loadout` merges `ShipRes.weapons` from the hull
    /// itself) — folding them into the outfit-id-keyed `player.outfits` dict would
    /// misread a weapon id as an outfit id, so they are intentionally left to the
    /// hull. (See NovaSwiftEngine/ShipLoadout.swift.)
    ///
    /// The original (0x00449370 cases C/E/H, MS-18): `C` changes only the
    /// class — the player's weapon banks and items stay, and the new hull's
    /// stock armament is **not** added (only the E/H arm adds the class's
    /// stock banks and DefaultItems). After E/H every owned outfit is clamped
    /// to its current ownership limit (`clampOwnedOutfitsToLimits`). The
    /// disabled-hull repair that follows is the live ship's (app side).
    private func applyShipChange(to shipID: Int, mode: ChangeShipMode) {
        player.shipType = shipID
        switch mode {
        case .keepOutfits:                     // C: the class only.
            break
        case .addDefaultOutfits:
            addHullFittings(ofShip: shipID)    // E: keep + the hull's own fittings.
            PilotEconomy.clampOwnedOutfitsToLimits(&player, galaxy: Galaxy(game: game))
        case .defaultOutfits:                  // H: drop non-persistent + fittings.
            dropNonPersistentOutfits()
            addHullFittings(ofShip: shipID)
            PilotEconomy.clampOwnedOutfitsToLimits(&player, galaxy: Galaxy(game: game))
        }
    }

    /// Everything the hull comes with (`DefaultItems` + stock armament).
    private func addHullFittings(ofShip shipID: Int) {
        guard let s = game.ship(shipID) else {
            Log.mission.error("addHullFittings: unknown ship id \(shipID)")
            return
        }
        PilotEconomy.grantHullFittings(&player, ship: s, game: game)
    }

    /// Remove every non-persistent outfit the player currently owns (the `H`
    /// op's "lose any nonpersistent outfit items"). The original keeps an
    /// outfit carrying either persistence bit — `oütf.Flags` 0x0004 (kept when
    /// buying a ship) or 0x0020 (kept through a mission swap) — and drops the
    /// rest (0x00449370 tests `Flags & 0x24`).
    private func dropNonPersistentOutfits() {
        for oid in Array(player.outfits.keys) where !isOutfitPersistent(oid) {
            player.outfits[oid] = nil
        }
    }

    private func isOutfitPersistent(_ outfitID: Int) -> Bool {
        guard let o = game.outfit(outfitID) else { return false }
        return o.persistsOnMissionShipChange || o.persistsOnShipTrade
    }

    // MARK: - System visibility (bit-gated map objects)

    /// Whether system `systemID` is currently visible on the map / in nav. A
    /// `sÿst`'s `visibility` NCB **test** string gates its presence: blank (the
    /// common case) or true ⇒ visible; false ⇒ hidden. An unknown system id is
    /// treated as visible (don't hide things we can't resolve). This is how EV
    /// Nova makes systems appear/disappear mid-game via control bits.
    public func isSystemVisible(_ systemID: Int) -> Bool {
        guard let test = game.system(systemID)?.visibility, !test.isEmpty else { return true }
        if NCBTest(test).evaluate(player) { return true }
        return systemID == player.currentSystem && Self.isForcedVisible(systemID, state: player, game: game)
    }

    /// Every system currently hidden — those whose `visibility` NCB test is
    /// non-empty and evaluates false against the current pilot.
    public func hiddenSystemIDs() -> Set<Int> { game.hiddenSystemIDs(for: player) }

    /// The system that owns `spobID` with the pilot's current visibility
    /// (0x00448090; see `NovaGame.systemContaining(spob:hidden:)`).
    public func owningSystem(ofSpob spobID: Int) -> Int? {
        game.systemContaining(spob: spobID, hidden: hiddenSystemIDs())
    }

    /// The tail of 0x00448090: when the pilot's system has gone hidden, the
    /// pilot moves to the first visible member of its twin group; with none
    /// visible, to the group's root, which is then forced visible (logged in
    /// the original as "player is in inactive system … reactivating"). The
    /// force lasts while the pilot is there: the original re-forces it at
    /// every evaluation (`isForcedVisible`). Returns the new system, or nil
    /// when nothing moved.
    @discardableResult
    public func resolveCurrentSystemVisibility() -> Int? {
        let current = player.currentSystem
        guard !isSystemVisible(current) else { return nil }
        let hidden = game.hiddenSystemIDs(for: player)
        let target = game.visibleTwin(of: current, hidden: hidden) ?? game.reputationMap().root(of: current)
        guard target != current else { return nil }
        Log.mission.notice("player is in inactive system \(current, privacy: .public); moving to system \(target, privacy: .public)")
        player.currentSystem = target
        return target
    }

    /// Whether a hidden `systemID` is still visible because the pilot is in it
    /// and it is the root of a twin group with no visible member — the
    /// "reactivating system" fallback of 0x00448090.
    static func isForcedVisible(_ systemID: Int, state: PlayerState, game: NovaGame) -> Bool {
        let map = game.reputationMap()
        guard map.root(of: systemID) == systemID else { return false }
        let gated = Dictionary(game.visibilityGatedSystems().map { ($0.id, $0.test) }, uniquingKeysWith: { a, _ in a })
        return (map.groups[systemID] ?? [systemID]).allSatisfy { id in
            guard let test = gated[id] else { return false }
            return !NCBTest(test).evaluate(state)
        }
    }

    /// The bookkeeping `System_UpdateSystemAndStellarDisplayState` 0x00432470
    /// and 0x00448090 run after landing, launch, arrival and every control-bit
    /// change: twins share one discovery level, and a pilot left in a hidden
    /// system moves to its visible twin. Returns the system the pilot moved to.
    @discardableResult
    public func refreshSystemState() -> Int? {
        player.shareTwinDiscovery(game.reputationMap())
        return resolveCurrentSystemVisibility()
    }

    // MARK: - Contribute/Require pool

    /// The 64-bit `Contribute` pool EV Nova ANDs against `Require` fields on
    /// `mïsn`/`oütf`/`crön` (and `gövt`) resources (Bible §crön
    /// "Contribute/Require": "combined with the Contribute fields from the
    /// player's ship and the other outfit items in the player's possession").
    /// We additionally fold in active ränk `Contribute` (its own doc comment,
    /// `MissionModels.swift`, cites the same Require-gating use) and active
    /// crön `Contribute` (this doc's own cross-resource-gating section) — the
    /// only place this pool is aggregated, since none of `Contribute`'s
    /// producers (ship/outfit/rank/cron) know about each other individually.
    /// Recomputed on demand rather than cached: ship/outfit/rank/cron state
    /// all change independently and a handful of resource lookups is cheap
    /// next to a mission-offer or cron-activation check.
    public func activeContributeBits() -> UInt64 {
        var bits: UInt64 = game.ship(player.shipType)?.contribute ?? 0
        for (outfitID, qty) in player.outfits where qty > 0 {
            bits |= game.outfit(outfitID)?.contribute ?? 0
        }
        for rankID in player.activeRanks {
            bits |= game.rank(rankID)?.contribute ?? 0
        }
        for (cronID, rt) in player.cronRuntime where rt.isActive {
            bits |= game.cron(cronID)?.contribute ?? 0
        }
        return bits
    }

    // MARK: - The galaxy clock & crons

    /// Advance the clock one day and process background events + deadlines. Call
    /// once per in-game day.
    public func advanceOneDay() { advanceDays(1) }

    /// Advance the clock by `n` days, each one the original's daily tick in its
    /// order (0x00466cb0, MS-23): date, crön, deadline countdown, tribute,
    /// disasters, stellar regeneration, then rank salaries. A deadline that runs
    /// out here fails the mission on the next flight pass, not now. Deadlines
    /// are absolute dates here, so the countdown step needs no work of its own,
    /// and the stock rolls are derived from the date (EC-11). Escort upkeep is
    /// not part of the day: see `processEscortPayroll`.
    public func advanceDays(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n {
            player.date = player.date.adding(days: 1)
            evaluateCrons()
            payDailyTribute()
            evaluateDisasters()
            tickSystemDefenses()
            regenerateDestroyedStellars()
            payDailySalaries()
        }
    }

    /// The daily tick's system-defense bookkeeping (0x00466cb0): every
    /// system's reinforcement retrigger delay counts down a day (AI-13), and a
    /// dominated stellar's garrison below its `DefCount` grows back one ship
    /// on a `Rand(450) == 0` roll (AI-15).
    public func tickSystemDefenses() {
        if var delays = player.reinforcementRetriggerDays, !delays.isEmpty {
            for id in delays.keys.sorted() {
                let left = (delays[id] ?? 0) - 1
                delays[id] = left > 0 ? left : nil
            }
            player.reinforcementRetriggerDays = delays.isEmpty ? nil : delays
        }
        guard var garrisons = player.stellarGarrisons, !garrisons.isEmpty else { return }
        for spobID in garrisons.keys.sorted() where player.hasDominated(spobID) {
            guard let spob = game.spob(spobID), let count = garrisons[spobID],
                  count < spob.defenseTotal, rng.int(450) == 0 else { continue }
            garrisons[spobID] = count + 1
        }
        player.stellarGarrisons = garrisons
    }

    /// A stellar shot down in combat comes back once its `spöb.DeadTime`
    /// ("Regenerate Time", days) has elapsed, firing its `OnRegen` control bits
    /// on the way in — the natural counterpart to the `OnDestroy` bits that fire
    /// when it goes down.
    ///
    /// Every stellar carrying a `stellarDestroyedOnDay` stamp counts down —
    /// shot down in combat or blown up by a mission `Y` alike (MS-18). A
    /// `DeadTime` of -1 ("never regenerates", `regenerationDays == nil`) stays
    /// down until a `U`. Stellars from saves that predate the `Y` countdown
    /// have no stamp and also wait for a `U`.
    public func regenerateDestroyedStellars() {
        guard let stamps = player.stellarDestroyedOnDay, !stamps.isEmpty else { return }
        let now = player.date.julianDay
        for (spobID, destroyedOn) in stamps {
            guard let s = game.spob(spobID) else { continue }
            guard s.hasRegenerated(destroyedDayCount: destroyedOn, nowDayCount: now) else { continue }
            player.markStellarRegenerated(spobID)
            services?.setStellarDestroyed(spobID: spobID, destroyed: false)
            if !s.onRegen.isEmpty {
                apply(set: s.onRegen, source: ncbSource("spöb", spobID, s.name, "OnRegen"))
            }
            Log.mission.notice("Stellar \(spobID, privacy: .public) regenerated after \(now - destroyedOn, privacy: .public) days")
        }
    }

    /// A destroyable stellar (`spöb.Strength` > 0) was shot down in the live
    /// world. Persists it, pushes the galaxy mutation out to the host, fires its
    /// `OnDestroy` control bits, and starts the `DeadTime` regeneration clock.
    public func stellarShotDown(_ spobID: Int) {
        guard !player.isStellarDestroyed(spobID) else { return }
        player.markStellarShotDown(spobID, onDay: player.date.julianDay)
        services?.setStellarDestroyed(spobID: spobID, destroyed: true)
        if let s = game.spob(spobID), !s.onDestroy.isEmpty {
            apply(set: s.onDestroy, source: ncbSource("spöb", spobID, s.name, "OnDestroy"))
        }
        Log.mission.notice("Stellar \(spobID, privacy: .public) destroyed by weapon fire")
    }

    /// The daily `öops` pass (`System_UpdateDisasterStates` 0x00424f90): an
    /// active disaster counts down and expires; an inactive one rolls its
    /// `Freq` (`rand(100) + 1 ≤ Freq`), then checks `ActivateOn`, and lasts
    /// `Duration` days. A disaster that expires today does not roll again
    /// until tomorrow. `Stellar` names one stellar, or −1 picks one random
    /// inhabited stellar for this activation; −2 and other values below 128 are
    /// inert. While active it replaces that stellar's price for its commodity
    /// (`LandedServices.tradeRows`).
    public func evaluateDisasters() {
        var active = player.activeDisasters ?? [:]
        var picked = player.disasterStellars ?? [:]
        var expiredToday: Set<Int> = []
        for (oopsID, expiry) in active where player.date >= expiry {
            active[oopsID] = nil
            picked[oopsID] = nil
            expiredToday.insert(oopsID)
        }
        for o in game.oopses().sorted(by: { $0.id < $1.id }) {
            guard active[o.id] == nil, !expiredToday.contains(o.id) else { continue }
            guard o.stellar == -1 || o.stellar >= 128 else { continue }
            guard o.duration > 0, rng.chance(percent: o.freq) else { continue }
            if !o.activateOn.isEmpty, !NCBTest(o.activateOn).evaluate(player) { continue }
            if o.stellar == -1 {
                let inhabited = game.spobs().filter { !$0.isUninhabited }.map(\.id).sorted()
                guard !inhabited.isEmpty else { continue }
                picked[o.id] = inhabited[rng.int(inhabited.count)]
            }
            active[o.id] = player.date.adding(days: o.duration)
            Log.mission.debug("disaster \(o.id) '\(o.name, privacy: .public)' triggered until \(String(describing: active[o.id]), privacy: .public)")
            services?.notify(.disasterTriggered(oopsID: o.id))
        }
        player.activeDisasters = active
        player.disasterStellars = picked.isEmpty ? nil : picked
    }

    /// Record a stellar as dominated by the player and fire its `OnDominate`
    /// control bits. The seam the app calls when the engine reports a
    /// `WorldEvent.stellarDominated`. Idempotent — re-dominating a planet already
    /// owned doesn't re-run its `OnDominate`.
    public func dominateStellar(_ spobID: Int) {
        guard !player.hasDominated(spobID) else { return }
        player.dominate(spobID)
        if let spob = game.spob(spobID), !spob.onDominate.isEmpty {
            apply(set: spob.onDominate, source: ncbSource("spöb", spobID, spob.name, "OnDominate"))
        }
        services?.notify(.stellarDominated(spobID: spobID))
    }

    /// Release a stellar from the player's domination (it stops paying tribute)
    /// and fire its `OnRelease` control bits.
    public func releaseStellar(_ spobID: Int) {
        guard player.hasDominated(spobID) else { return }
        player.releaseDomination(spobID)
        if let spob = game.spob(spobID), !spob.onRelease.isEmpty {
            apply(set: spob.onRelease, source: ncbSource("spöb", spobID, spob.name, "OnRelease"))
        }
        services?.notify(.stellarReleased(spobID: spobID))
    }

    /// Add each dominated stellar's daily tribute to the player's credits — the
    /// authentic EV Nova behavior (tribute accrues automatically as the day clock
    /// advances; it is *not* collected by landing). A stellar's `Tribute` field of
    /// `-1`/`0` means the default payout, `1000 × TechLevel` (`dailyTributeAmount`).
    /// See docs/reverse-engineering/DOMINATION.md.
    func payDailyTribute() {
        guard let dominated = player.dominatedStellars, !dominated.isEmpty else { return }
        var payout = 0
        for spobID in dominated {
            guard let spob = game.spob(spobID) else { continue }
            payout += spob.dailyTributeAmount
        }
        if payout > 0 { player.credits += payout }
    }

    /// Escort payroll (`Player_ProcessEscortPayroll` 0x004232d0, EC-20). Not
    /// part of the daily tick: the original charges one period on leaving
    /// every spaceport (the tail of the escort fleet pass, 0x004229d0) and
    /// `travelDays` periods on each hyperspace arrival (0x0044f3d0).
    ///
    /// Each period walks the wing in slot order. Only **hired** escorts are
    /// paid (the hired-origin mark), at `trunc(cost × 0.01)`; a disabled
    /// escort (`skipping`) is neither paid nor lost. An escort the player
    /// can't pay defects: it leaves the wing — a non-mission freighter first
    /// takes its share of the fleet's cargo (EC-21) — and, once every period
    /// has run, one dialog says so (STR# 2002 #302 for one, #303 for several).
    /// The app removes the live ship on `.escortDeparted`. Returns how many
    /// defected.
    @discardableResult
    public func processEscortPayroll(periods: Int, skipping disabled: Set<Int> = []) -> Int {
        guard periods > 0 else { return 0 }
        var defected = 0
        var charged = 0
        for _ in 0..<periods {
            for escort in player.escortWing where escort.origin == .hired && !disabled.contains(escort.id) {
                guard player.credits >= escort.dailyFee else {
                    defected += 1
                    if escort.missionID == nil, let hull = game.ship(escort.shipType), hull.inherentAI < 3 {
                        PilotEconomy.transferCargoToEscort(&player, recipientHolds: hull.cargoSpace,
                                                          missionCargo: carriedMissionCargo(),
                                                          galaxy: Galaxy(game: game))
                    }
                    player.removeEscort(id: escort.id)
                    services?.notify(.escortDeparted(escortID: escort.id, name: escort.name))
                    continue
                }
                player.credits -= escort.dailyFee
                charged += escort.dailyFee
            }
        }
        if charged > 0 { services?.notify(.escortDailyFeeCharged(total: charged)) }
        if defected > 0, let s = stringListEntry(2002, index: defected == 1 ? 302 : 303), !s.isEmpty {
            services?.showStoryText(s, title: "")
        }
        return defected
    }

    // MARK: - Helpers

    func stringListEntry(_ strID: Int, index: Int) -> String? {
        game.stringList(strID)?.string(at: index)
    }

    /// A UI-ready snapshot of one accepted mission: its resolved name, where to
    /// go next (the concrete destination stellar + its system), the deadline, and
    /// whether the player is allowed to abort it. Drives the Mission list dialog
    /// and the galaxy-map destination arrow.
    public struct MissionSummary: Identifiable, Hashable, Sendable {
        public let id: Int                 // missionID
        public let name: String
        public let payload: String         // one-line "quick brief" (dësc pitch, trimmed)
        /// The current next step, with live progress folded in (e.g.
        /// "Destroy ships (1/3) · Report to Kane Station"). Reflects this pilot's
        /// `ActiveMission` state, not just the static `mïsn`, so it updates as
        /// ships fall and legs are completed.
        public let objective: String
        public let destinationSpobID: Int? // where to fly next
        public let destinationSpob: String // stellar name ("" if none)
        public let destinationSystemID: Int?
        public let destinationSystem: String
        public let deadline: GameDate?
        public let canAbort: Bool
        /// Failed, and waiting for the landing at its return stellar (MS-07).
        public let failed: Bool
    }

    /// Summaries of every currently-accepted mission, in acceptance order.
    public func activeMissionSummaries() -> [MissionSummary] {
        player.activeMissions.compactMap { am in
            guard let m = game.mission(am.missionID) else { return nil }
            // `mïsn.Flags` 0x0400: "Mission is invisible and won't appear in the
            // mission info dialog." Background bookkeeping missions the storyline
            // runs on the player's behalf — they still tick, spawn ships and pay
            // out, they're just not listed.
            guard !m.invisible else { return nil }
            // Before the travel stellar is reached, point at it; afterward point
            // at the return stellar (the drop-off), mirroring EV Nova's arrow.
            let targetSpob: Int?
            if !am.visitedTravelStellar, let t = am.travelSpobID {
                targetSpob = t
            } else {
                targetSpob = returnStellar(of: am, m) ?? am.travelSpobID
            }
            let sys = targetSpob.flatMap { owningSystem(ofSpob: $0) }.flatMap { game.system($0) }
            return MissionSummary(
                id: am.missionID,
                name: resolveMissionText(m.displayName, for: m, active: am),
                payload: missionQuickBrief(for: m, active: am),
                objective: missionObjective(m: m, am: am, targetSpob: targetSpob),
                destinationSpobID: targetSpob,
                destinationSpob: targetSpob.flatMap { game.spob($0)?.displayName } ?? "",
                destinationSystemID: sys?.id,
                destinationSystem: sys?.displayName ?? "",
                deadline: am.deadline,
                canAbort: m.canAbort,
                failed: am.isFailed)
        }
    }

    /// The current next step for an accepted mission, folding this pilot's live
    /// `ActiveMission` progress into the static `mïsn`: the ship objective shows
    /// how many of the target ships are done, and the travel/return leg names the
    /// concrete stellar the map arrow points at. Used by the in-game Mission list.
    private func missionObjective(m: MissionRes, am: ActiveMission, targetSpob: Int?) -> String {
        var parts: [String] = []
        if m.hasShipObjective {
            let verb = shipGoalVerb(m.shipGoal)
            if am.objectiveComplete ?? false {
                parts.append("\(verb) ships — done ✓")
            } else {
                switch m.shipGoal {
                case .escort, .observe:
                    parts.append("\(verb) \(m.shipCount) ship\(m.shipCount == 1 ? "" : "s")")
                default:
                    let total = max(1, m.shipCount)
                    parts.append("\(verb) ships (\(min(total, goalProgress(m, am)))/\(total))")
                }
            }
        }
        if let t = targetSpob, let name = game.spob(t)?.displayName {
            if am.isCarryingCargo, !am.visitedTravelStellar {
                parts.append("Deliver cargo to \(name)")
            } else if !am.visitedTravelStellar, am.travelSpobID == t {
                parts.append("Travel to \(name)")
            } else {
                parts.append("Report to \(name)")
            }
        }
        return parts.isEmpty ? "See mission briefing" : parts.joined(separator: " · ")
    }

    /// Ships counted towards the goal so far, for the mission list.
    private func goalProgress(_ m: MissionRes, _ am: ActiveMission) -> Int {
        switch m.shipGoal {
        case .destroy:        return am.shipsDestroyed ?? 0
        case .disable:        return am.shipsDisabled ?? 0
        case .board, .rescue: return am.shipsBoarded ?? 0
        case .chaseOff:       return (am.shipsChasedOff ?? 0) + (am.shipsDestroyed ?? 0)
        default:              return 0
        }
    }

    /// Present-tense verb for a mission's ship goal (`mïsn.ShipGoal`) — the
    /// imperative used in the objective line ("Destroy", "Disable", …).
    private func shipGoalVerb(_ goal: MissionShipGoal) -> String {
        switch goal {
        case .destroy: return "Destroy"
        case .disable: return "Disable"
        case .board:   return "Board"
        case .escort:  return "Escort"
        case .observe: return "Observe"
        case .rescue:  return "Rescue"
        case .chaseOff: return "Drive off"
        case .none:    return "Deal with"
        }
    }

    /// A trimmed one-liner describing an accepted mission, for compact list rows.
    ///
    /// Uses the mission's own `mïsn.QuickBrief` `dësc` when it has one — that is
    /// exactly what the field is for, and it's what the original shows in the
    /// mission list. Only when a mission leaves it unset do we fall back to
    /// collapsing the full offer pitch, which is what this always did before
    /// `QuickBrief` was wired up (and which reads as a truncated wall of text).
    private func missionQuickBrief(for m: MissionRes, active: ActiveMission) -> String {
        func collapsed(_ id: Int) -> String {
            let full = resolveMissionText(game.descText(id, context: textContext), for: m, active: active)
            return full.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let quick = collapsed(m.quickBriefText)
        return quick.isEmpty ? collapsed(m.offerTextID) : quick
    }

    /// The systems that currently hold an active-mission destination — used by the
    /// galaxy map to draw its orange "go here" arrows.
    public func missionDestinationSystemIDs() -> [Int] {
        Array(Set(activeMissionSummaries().compactMap(\.destinationSystemID))).sorted()
    }

    /// Mission destinations with names attached, for the galaxy map's "go here"
    /// arrow label. One entry per destination system; when several accepted
    /// missions share a destination, their names are joined so the label still
    /// reads as one line (mirrors EV Nova's map dialog, which lists mission
    /// names next to the pointer).
    public func missionDestinations() -> [(systemID: Int, names: [String])] {
        var bySystem: [Int: [String]] = [:]
        for s in activeMissionSummaries() {
            guard let sys = s.destinationSystemID else { continue }
            bySystem[sys, default: []].append(s.name)
        }
        return bySystem.map { (systemID: $0.key, names: $0.value) }.sorted { $0.systemID < $1.systemID }
    }

    /// The `{…}`-conditional context for this pilot (control bits + gender),
    /// so mission/desc text resolves its `{bXXX …}`/`{G …}` segments correctly.
    var textContext: NovaTextContext {
        NovaTextContext(isBitSet: { [player] in player.setBits.contains($0) },
                        isMale: player.isMale)
    }
}
