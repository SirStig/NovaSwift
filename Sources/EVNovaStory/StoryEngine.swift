import Foundation
import EVNovaKit

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
    private var rng: StoryRNG

    /// The spob the player started at, used to resolve the "-4 initial" selector.
    public var initialSpob: Int?

    public init(game: NovaGame, player: PlayerState,
                services: GameServices? = nil, seed: UInt64 = 0xE7CA11) {
        self.game = game
        self.player = player
        self.services = services
        self.rng = StoryRNG(seed: seed)
    }

    // MARK: - NCB evaluation

    /// Evaluate a control-bit TEST expression against the current pilot.
    public func evaluate(test expr: String) -> Bool {
        NCBTest(expr).evaluate(player)
    }

    /// Parse and apply a control-bit SET expression (mission OnAccept/OnSuccess,
    /// cron OnStart/OnEnd, …).
    public func apply(set expr: String) {
        let ops = NCBSet.parse(expr)
        if ops.isEmpty, !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Every token in a non-empty SET expression was unrecognized/skipped —
            // this silently no-ops rather than throwing, so flag it: it usually
            // means a data-parsing gap or a malformed resource.
            Log.ncb.error("NCB apply: expression yielded no operations: \"\(expr, privacy: .public)\"")
        }
        for op in ops { execute(op) }
    }

    private func execute(_ op: NCBSetOp) {
        Log.ncb.debug("NCB execute: \(String(describing: op), privacy: .public)")
        switch op {
        case .setBit(let n):    player.setBit(n)
        case .clearBit(let n):  player.clearBit(n)
        case .toggleBit(let n): player.toggleBit(n)

        case .startMission(let id):  startMission(id)
        case .abortMission(let id):  abortMission(id, silent: true)
        case .failMission(let id):   failMission(id)

        case .grantOutfit(let id):
            player.grantOutfit(id)
            services?.notify(.outfitGranted(outfitID: id))
        case .removeOutfit(let id):
            player.removeOutfit(id)
            services?.notify(.outfitRemoved(outfitID: id))

        case .moveToSystem(let id, let keep):
            player.currentSystem = id
            player.exploredSystems.insert(id)
            services?.movePlayer(toSystem: id, keepPosition: keep)

        case .changeShip(let id, let mode):
            player.shipType = id
            services?.changePlayerShip(to: id, mode: mode)

        case .activateRank(let id):
            activateRank(id)
        case .deactivateRank(let id):
            player.activeRanks.remove(id)
            services?.notify(.rankDeactivated(rankID: id))

        case .playSound(let id):
            services?.playSound(id: id)

        case .destroyStellar(let id):
            services?.setStellarDestroyed(spobID: id, destroyed: true)
        case .regenerateStellar(let id):
            services?.setStellarDestroyed(spobID: id, destroyed: false)

        case .exploreSystem(let id):
            player.exploredSystems.insert(id)

        case .changeShipTitle(let strID):
            if let name = stringListEntry(strID, index: 1) { player.shipName = name }

        case .leaveStellar(let msgStr):
            let msg = msgStr.flatMap { stringListEntry($0, index: 1) }
            services?.leaveStellar(message: msg)

        case .random(let choices):
            // EV Nova's R(a b) picks one of the (up to two) ops at 50/50.
            if choices.isEmpty { return }
            let pick = choices.count == 1 ? choices[0] : choices[rng.int(choices.count)]
            execute(pick)
        }
    }

    private func activateRank(_ id: Int) {
        guard !player.activeRanks.contains(id) else { return }
        // Ranks flagged "drop others of same govt" replace the govt's other ranks.
        if let r = game.rank(id), r.flags & 0x0001 != 0 {
            for existing in player.activeRanks where game.rank(existing)?.govt == r.govt {
                player.activeRanks.remove(existing)
            }
        }
        player.activeRanks.insert(id)
        services?.notify(.rankActivated(rankID: id))
    }

    // MARK: - Mission availability

    /// True if `mission` could be offered right now, ignoring the random roll:
    /// its AvailBits test passes, the player meets the record/rating/ship gates,
    /// and it isn't already active or completed.
    public func isEligible(_ mission: MissionRes, at location: MissionOfferLocation,
                           spobID: Int?) -> Bool {
        if player.isMissionActive(mission.id) { return false }
        if player.completedMissions.contains(mission.id) { return false }
        if mission.availLocation != location { return false }
        if let spobID, !availStellarMatches(mission, spobID: spobID) { return false }
        if player.combatRating < mission.availRating { return false }
        // Legal record: availRecord is a *minimum* standing with the offering govt.
        if let spobID, let govt = game.spob(spobID)?.government {
            if (player.legalRecord[govt] ?? 0) < mission.availRecord { return false }
        }
        if !shipTypeMatches(mission.availShipType) { return false }
        if !evaluate(test: mission.availBits) { return false }
        // Require (Bible §crön "Contribute/Require"): mïsn.Require is AND'ed
        // against the pooled Contribute bits from the player's ship, owned
        // outfits, active ranks and active crön events — a capability gate
        // distinct from (and additional to) availBits' control-bit test. A
        // zero Require mask means "no gate" (the common case).
        if mission.require != 0, (activeContributeBits() & mission.require) != mission.require {
            return false
        }
        if mission.requiresCargoSpace, freeCargoSpace() <= 0 { return false }
        return true
    }

    /// The missions on offer at a spot, after applying each mission's random
    /// appearance chance. Deterministic given the engine's RNG state.
    public func missionsOffered(at location: MissionOfferLocation, spob spobID: Int?) -> [MissionRes] {
        let offered = game.missions()
            .filter { isEligible($0, at: location, spobID: spobID) }
            .filter { $0.availRandom <= 0 ? true : rng.chance(percent: $0.availRandom) }
            .sorted { $0.displayWeight > $1.displayWeight }
        Log.mission.debug("missionsOffered: location=\(String(describing: location), privacy: .public) spob=\(spobID ?? -1) -> \(offered.count) mission(s)")
        return offered
    }

    /// Build a presentable offer (resolving briefing text + buttons) and hand it
    /// to the UI via `GameServices`.
    public func present(_ mission: MissionRes) {
        let brief = briefingText(for: mission)
        let offer = MissionOffer(
            mission: mission,
            briefingText: brief,
            acceptButton: mission.acceptButton.isEmpty ? "Accept" : mission.acceptButton,
            refuseButton: mission.refuseButton.isEmpty ? "Decline" : mission.refuseButton,
            canRefuse: !mission.cannotBeRefused)
        services?.presentMissionOffer(offer)
    }

    private func availStellarMatches(_ mission: MissionRes, spobID: Int) -> Bool {
        // -1 == "any inhabited stellar" for the availability field.
        if mission.availStellar == -1 { return true }
        return StellarMatch.spob(code: mission.availStellar, spobID: spobID,
                                 game: game, initialSpob: initialSpob)
    }

    private func shipTypeMatches(_ code: Int) -> Bool {
        switch code {
        case ..<128: return true              // any (incl. -1 / legacy 127)
        case 128...895: return code == player.shipType
        case 1128...1895: return (code - 1000) != player.shipType   // "not ship"
        default: return true                  // govt-scoped ship gates: accept
        }
    }

    // MARK: - Mission lifecycle

    /// Accept a mission the player was offered. Applies OnAccept, seeds objective
    /// tracking, spawns special ships if the objective needs them.
    @discardableResult
    public func accept(_ missionID: Int) -> Bool {
        guard let m = game.mission(missionID) else {
            Log.mission.error("accept: unknown mission id \(missionID)")
            return false
        }
        guard !player.isMissionActive(missionID) else {
            Log.mission.debug("accept: mission \(missionID) (\"\(m.name, privacy: .public)\") already active; ignoring")
            return false
        }
        Log.mission.notice("accept: mission \(missionID) (\"\(m.name, privacy: .public)\") accepted")

        let deadline = m.timeLimit > 0 ? player.date.adding(days: m.timeLimit) : nil
        let cargoAtStart = m.cargoPickup == .atStart
        let shipObjectives = m.hasShipObjective ? max(0, m.shipCount) : 0

        player.activeMissions.append(ActiveMission(
            missionID: missionID,
            acceptedDate: player.date,
            deadline: deadline,
            cargoPickedUp: cargoAtStart,
            shipObjectivesRemaining: shipObjectives))

        if cargoAtStart, m.cargoQty != 0 {
            player.cargo[m.cargoType, default: 0] += abs(m.cargoQty)
        }

        apply(set: m.onAccept)
        services?.notify(.missionAccepted(missionID: missionID, name: m.name))

        // Missions whose special ships appear in the current system spawn now.
        if m.hasShipObjective { services?.spawnMissionShips(missionID: missionID, mission: m) }

        // A mission flagged "auto-abort when started" immediately completes/clears
        // — it exists only to run its OnAccept bits.
        if m.autoAbortWhenStarted { abortMission(missionID, silent: true) }
        return true
    }

    /// The player declined an offered mission (applies OnRefuse).
    public func decline(_ missionID: Int) {
        guard let m = game.mission(missionID) else {
            Log.mission.error("decline: unknown mission id \(missionID)")
            return
        }
        Log.mission.debug("decline: mission \(missionID) (\"\(m.name, privacy: .public)\") declined")
        apply(set: m.onRefuse)
    }

    /// The player (or a SET op) aborted an active mission.
    public func abortMission(_ missionID: Int, silent: Bool = false) {
        guard let idx = player.activeMissions.firstIndex(where: { $0.missionID == missionID })
        else {
            Log.mission.debug("abortMission: mission \(missionID) not active; ignoring")
            return
        }
        let m = game.mission(missionID)
        releaseCargo(for: m)
        player.activeMissions.remove(at: idx)
        if let m { apply(set: m.onAbort) }
        Log.mission.notice("abortMission: mission \(missionID) (\"\(m?.name ?? "?", privacy: .public)\") aborted (silent=\(silent))")
        if !silent, let m {
            services?.notify(.missionAborted(missionID: missionID, name: m.name))
        }
    }

    /// Start a mission programmatically (SET `S`), bypassing the offer flow.
    public func startMission(_ missionID: Int) {
        accept(missionID)
    }

    /// Complete an active mission: pay out, apply comp rewards + OnSuccess, show
    /// completion text, advance the galaxy clock by its DatePostIncrement.
    public func completeMission(_ missionID: Int) {
        guard let idx = player.activeMissions.firstIndex(where: { $0.missionID == missionID }),
              let m = game.mission(missionID) else {
            Log.mission.error("completeMission: mission \(missionID) not active or unknown; ignoring")
            return
        }
        Log.mission.notice("completeMission: mission \(missionID) (\"\(m.name, privacy: .public)\") completed, pay=\(m.pay)")

        releaseCargo(for: m)
        player.activeMissions.remove(at: idx)
        player.completedMissions.insert(missionID)

        // Reward: pay (negative pay = a cost), govt standing, legal record.
        if m.pay != 0 {
            player.credits += m.pay
            services?.notify(.creditsChanged(delta: m.pay, total: player.credits))
        }
        if m.compRewardGovt >= 128, m.compLegalReward != 0 {
            player.legalRecord[m.compRewardGovt, default: 0] += m.compLegalReward
        }

        apply(set: m.onSuccess)

        let text = game.descText(m.completionText)
        if !text.isEmpty { services?.showStoryText(text, title: m.name) }
        services?.notify(.missionCompleted(missionID: missionID, name: m.name))

        if m.datePostIncrement > 0 { advanceDays(m.datePostIncrement) }
    }

    /// Fail an active mission (deadline missed, cargo lost, escort destroyed …).
    public func failMission(_ missionID: Int) {
        guard let idx = player.activeMissions.firstIndex(where: { $0.missionID == missionID }),
              let m = game.mission(missionID) else {
            Log.mission.error("failMission: mission \(missionID) not active or unknown; ignoring")
            return
        }
        Log.mission.notice("failMission: mission \(missionID) (\"\(m.name, privacy: .public)\") failed")
        releaseCargo(for: m)
        player.activeMissions.remove(at: idx)
        player.failedMissions.insert(missionID)
        apply(set: m.onFailure)
        if !m.canAbort {
            let text = game.descText(m.failureText)
            if !text.isEmpty { services?.showStoryText(text, title: m.name) }
        }
        services?.notify(.missionFailed(missionID: missionID, name: m.name))
    }

    // MARK: - World events (fed in by nav / combat / AI)

    /// The player landed on a stellar object. Advances cargo pickup / delivery
    /// and completes any mission whose return objective is satisfied here.
    public func playerLanded(onSpob spobID: Int) {
        // Iterate over a snapshot of ids since completion mutates the array.
        for am in player.activeMissions {
            guard let m = game.mission(am.missionID) else { continue }
            var updated = am

            // Cargo pickup at the travel stellar.
            if m.cargoPickup == .atTravelStellar,
               StellarMatch.spob(code: m.travelStellar, spobID: spobID, game: game, initialSpob: initialSpob) {
                if !updated.cargoPickedUp, m.cargoQty != 0 {
                    player.cargo[m.cargoType, default: 0] += abs(m.cargoQty)
                }
                updated.cargoPickedUp = true
                updated.visitedTravelStellar = true
            }
            if StellarMatch.spob(code: m.travelStellar, spobID: spobID, game: game, initialSpob: initialSpob) {
                updated.visitedTravelStellar = true
            }
            replace(updated)

            if landingCompletes(m, active: updated, spobID: spobID) {
                completeMission(m.id)
            }
        }
    }

    /// The player jumped into a system (marks it explored).
    public func playerJumped(toSystem systemID: Int) {
        player.currentSystem = systemID
        player.exploredSystems.insert(systemID)
    }

    /// A mission special ship was destroyed (combat reports this by mission id).
    public func missionShipDestroyed(missionID: Int) { decrementShipObjective(missionID) }
    /// A mission special ship was disabled (for disable/board goals).
    public func missionShipDisabled(missionID: Int) { decrementShipObjective(missionID) }
    /// A mission special ship was boarded.
    public func missionShipBoarded(missionID: Int) { decrementShipObjective(missionID) }

    /// The player's escort/target for a mission was destroyed when it shouldn't
    /// have been (e.g. an escort you were protecting) — fails the mission.
    public func missionShipLost(missionID: Int) {
        guard let m = game.mission(missionID) else {
            Log.mission.error("missionShipLost: unknown mission id \(missionID)")
            return
        }
        if m.shipGoal == .escort || m.shipGoal == .rescue {
            Log.mission.debug("missionShipLost: mission \(missionID) escort/rescue target lost; failing")
            failMission(missionID)
        }
    }

    private func decrementShipObjective(_ missionID: Int) {
        guard var am = player.activeMission(missionID) else { return }
        am.shipObjectivesRemaining = max(0, am.shipObjectivesRemaining - 1)
        replace(am)
        guard let m = game.mission(missionID) else { return }
        // If there's no return leg required, finishing the ships completes it.
        if am.shipObjectivesRemaining == 0, m.returnStellar == -1 {
            completeMission(missionID)
        }
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

    /// Advance the clock by `n` days, running cron evaluation and deadline checks
    /// for each day so nothing is skipped over.
    public func advanceDays(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n {
            player.date = player.date.adding(days: 1)
            payDailySalaries()
            evaluateCrons()
            checkDeadlines()
        }
    }

    private func payDailySalaries() {
        for rankID in player.activeRanks {
            guard let r = game.rank(rankID), r.salary != 0 else { continue }
            // Salary cap: don't pay past the cap (0 = uncapped).
            if r.salaryCap > 0, player.credits >= r.salaryCap { continue }
            player.credits += r.salary
        }
    }

    private func checkDeadlines() {
        for am in player.activeMissions {
            if let d = am.deadline, player.date > d {
                failMission(am.missionID)
            }
        }
    }

    /// Evaluate every `crön`: start those now eligible, end those whose duration
    /// has elapsed. Runtime state persists in `player.cronRuntime`.
    public func evaluateCrons() {
        for c in game.crons() {
            var rt = player.cronRuntime[c.id] ?? CronRuntime(cronID: c.id)

            // End an active event whose duration has elapsed.
            if rt.isActive, let end = rt.endDate, player.date >= end {
                apply(set: c.onEnd)
                Log.mission.debug("cron \(c.id) ended on \(String(describing: self.player.date), privacy: .public)")
                services?.notify(.cronEnded(cronID: c.id))
                rt.startedDate = nil
                rt.endDate = nil
                rt.earliestStart = player.date.adding(days: max(0, c.postHoldoff))
                player.cronRuntime[c.id] = rt
                continue
            }
            guard !rt.isActive else { player.cronRuntime[c.id] = rt; continue }

            // Consider starting: hold-off passed, inside the date window, enable
            // test passes, and the daily random roll succeeds.
            if let earliest = rt.earliestStart, player.date < earliest {
                player.cronRuntime[c.id] = rt; continue
            }
            if !dateInWindow(c) { player.cronRuntime[c.id] = rt; continue }
            if !NCBTest(c.enableOn).evaluate(player) { player.cronRuntime[c.id] = rt; continue }
            // Require (Bible §crön "Contribute/Require"): "these two Require
            // fields... are logically and'ed with the Contribute fields from
            // the player's current ship and outfit items. Unless for each 1
            // bit in the Require fields there is a matching 1 bit in one or
            // more of the Contribute fields, the cron will not be activated."
            // A capability gate distinct from EnableOn's control-bit test.
            if c.require != 0, (activeContributeBits() & c.require) != c.require {
                player.cronRuntime[c.id] = rt; continue
            }
            if c.random > 0, !rng.chance(percent: c.random) { player.cronRuntime[c.id] = rt; continue }

            apply(set: c.onStart)
            Log.mission.debug("cron \(c.id) started on \(String(describing: self.player.date), privacy: .public)")
            services?.notify(.cronStarted(cronID: c.id))
            announceNews(for: c)
            rt.startedDate = player.date
            rt.endDate = player.date.adding(days: max(0, c.duration))
            player.cronRuntime[c.id] = rt
        }
    }

    /// Background news (Bible §crön, `NewsGovt1-4`/`GovtNewsStr1-4`/
    /// `IndNewsStr`): while `c` is active, up to four governments (and their
    /// allies) get their own "local news" text; every other government's
    /// territory falls back to one shared "independent news" pool.
    /// "Local news always takes precedence over independent news, even if
    /// there is no corresponding news string to display (the STR# ID must
    /// still be greater than zero to not be ignored)." The engine can't
    /// resolve *which* precedence applies here — that depends on which
    /// station the player is looking at news from, which isn't known at
    /// cron-start time — so it hands `GameServices` one `showNews` call per
    /// configured local slot (tagged with that slot's govt id) plus one for
    /// the independent fallback (untagged, `govt: nil`) when configured; the
    /// conformer that actually renders the news dialog applies the
    /// local-beats-independent rule per station.
    private func announceNews(for c: CronRes) {
        for i in 0..<4 {
            let g = c.newsGovts[i]
            let strID = c.govtNewsStrs[i]
            guard g >= 0, strID > 0 else { continue }
            services?.showNews(text: randomStringListEntry(strID) ?? "", govt: g)
        }
        if c.independentNewsStrID > 0 {
            services?.showNews(text: randomStringListEntry(c.independentNewsStrID) ?? "", govt: nil)
        }
    }

    /// Randomly select one entry from a `STR#` list (Bible: "a string will be
    /// randomly selected from the STR# resource whose ID is given by...").
    private func randomStringListEntry(_ strListID: Int) -> String? {
        guard let strings = game.stringList(strListID)?.strings, !strings.isEmpty else { return nil }
        return strings[rng.int(strings.count)]
    }

    private func dateInWindow(_ c: CronRes) -> Bool {
        let d = player.date
        if c.firstYear != 0 {
            let first = GameDate(day: c.firstDay == 0 ? 1 : c.firstDay,
                                 month: c.firstMonth == 0 ? 1 : c.firstMonth,
                                 year: c.firstYear)
            if d < first { return false }
        }
        if c.lastYear != 0 {
            let last = GameDate(day: c.lastDay == 0 ? 31 : c.lastDay,
                                month: c.lastMonth == 0 ? 12 : c.lastMonth,
                                year: c.lastYear)
            if d > last { return false }
        }
        return true
    }

    // MARK: - Helpers

    private func landingCompletes(_ m: MissionRes, active: ActiveMission, spobID: Int) -> Bool {
        // All special-ship objectives must be done first.
        if active.shipObjectivesRemaining > 0 { return false }

        // Where does the mission want the player to end up?
        switch m.returnStellar {
        case -1:
            // No return leg: completion is driven by ship objectives, not landing.
            // Only complete here if this was a pure cargo-to-travel-stellar run.
            if m.cargoDropoff == .atTravelStellar {
                return StellarMatch.spob(code: m.travelStellar, spobID: spobID,
                                         game: game, initialSpob: initialSpob)
            }
            return false
        default:
            let atReturn = StellarMatch.spob(code: m.returnStellar, spobID: spobID,
                                             game: game, initialSpob: initialSpob)
            // Cargo dropoff at the travel stellar must have happened already.
            if m.cargoDropoff == .atTravelStellar {
                return atReturn && active.visitedTravelStellar
            }
            return atReturn
        }
    }

    private func releaseCargo(for m: MissionRes?) {
        guard let m, m.cargoQty != 0 else { return }
        let held = player.cargo[m.cargoType] ?? 0
        let remaining = held - abs(m.cargoQty)
        player.cargo[m.cargoType] = remaining > 0 ? remaining : nil
    }

    private func replace(_ am: ActiveMission) {
        if let i = player.activeMissions.firstIndex(where: { $0.missionID == am.missionID }) {
            player.activeMissions[i] = am
        }
    }

    private func freeCargoSpace() -> Int {
        let hold = game.ship(player.shipType)?.cargoSpace ?? 0
        return hold - player.usedCargoSpace
    }

    private func stringListEntry(_ strID: Int, index: Int) -> String? {
        game.stringList(strID)?.string(at: index)
    }

    /// The text shown when offering a mission: the explicit BriefText `dësc` if
    /// set, otherwise EV Nova's conventional offer text at dësc(3872 + id).
    private func briefingText(for m: MissionRes) -> String {
        if m.briefText >= 128 {
            let t = game.descText(m.briefText)
            if !t.isEmpty { return t }
        }
        return game.descText(m.offerTextID)
    }
}
