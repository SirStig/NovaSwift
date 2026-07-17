import Foundation
import NovaSwiftKit

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
            // A granted map/chart or amnesty (ModType 16/21) reveals its systems
            // / clears its legal record the same as a bought one — the effect is
            // inherent to acquiring the item, not to paying for it.
            if let o = game.outfit(id) {
                player.applyOutfitAcquisition(o, game: game, fromSystem: player.currentSystem)
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
            player.activeRanks.remove(id)
            services?.notify(.rankDeactivated(rankID: id))

        case .playSound(let id):
            services?.playSound(id: id)

        case .destroyStellar(let id):
            player.markStellarDestroyed(id)
            services?.setStellarDestroyed(spobID: id, destroyed: true)
            // The stellar's own OnDestroy control bits fire when it is destroyed
            // (a mission `Y` op is exactly that trigger). `apply` is a flat op
            // list, so this doesn't recurse unless the data itself re-destroys the
            // same id (which stock data never does).
            if let s = game.spob(id), !s.onDestroy.isEmpty { apply(set: s.onDestroy) }
        case .regenerateStellar(let id):
            player.markStellarRegenerated(id)
            services?.setStellarDestroyed(spobID: id, destroyed: false)
            if let s = game.spob(id), !s.onRegen.isEmpty { apply(set: s.onRegen) }

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
    private func applyShipChange(to shipID: Int, mode: ChangeShipMode) {
        player.shipType = shipID
        switch mode {
        case .keepOutfits:
            break                              // C: keep outfits, add nothing.
        case .addDefaultOutfits:
            addDefaultOutfits(ofShip: shipID)  // E: keep + defaults.
        case .defaultOutfits:                  // H: drop non-persistent + defaults.
            dropNonPersistentOutfits()
            addDefaultOutfits(ofShip: shipID)
        }
    }

    /// Add the hull's built-in `oütf` items to the player's owned outfits.
    private func addDefaultOutfits(ofShip shipID: Int) {
        guard let s = game.ship(shipID) else {
            Log.mission.error("addDefaultOutfits: unknown ship id \(shipID)")
            return
        }
        for (oid, count) in s.outfits { player.grantOutfit(oid, count: max(1, count)) }
    }

    /// Remove every non-persistent outfit the player currently owns (the `H`
    /// op's "lose any nonpersistent outfit items").
    ///
    /// TODO(accessor): `OutfRes` exposes no dedicated `persistent`/`fixed`
    /// accessor, so persistence is approximated from the outfit flag bits the
    /// codebase already recognises: can't-sell (`0x0008`) and fixed gun/turret
    /// mounts (`0x0001`/`0x0002`, per ShipLoadout.swift) — these are the
    /// permanently-attached items that survive a hull swap. This deliberately
    /// errs toward *keeping* an outfit when its persistence is ambiguous (safer
    /// than wrongly deleting the player's gear). If a real `oütf` persistent flag
    /// is decoded on `OutfRes`, switch `isOutfitPersistent` to read it.
    private func dropNonPersistentOutfits() {
        for oid in Array(player.outfits.keys) where !isOutfitPersistent(oid) {
            player.outfits[oid] = nil
        }
    }

    /// Best-effort "is this outfit persistent across a hull swap?" See the TODO
    /// on `dropNonPersistentOutfits`.
    private func isOutfitPersistent(_ outfitID: Int) -> Bool {
        guard let o = game.outfit(outfitID) else { return false }
        return o.flags & (0x0008 | 0x0001 | 0x0002) != 0
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
        // Legal record: availRecord is a *minimum* standing with the offering
        // govt — the "displayed legal status" here, i.e. universal + local at
        // this spöb's system (see `PlayerState.effectiveLegalRecord`).
        if let spobID, let govt = game.spob(spobID)?.government {
            if player.effectiveLegalRecord(govt: govt, atSystem: player.currentSystem) < mission.availRecord { return false }
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
        // Cargo space: the Mission BBS (.missionComputer) deliberately keeps a
        // mission the player can't currently fit visible/browsable — it's just
        // not acceptable yet (see `canAccept` below), so the board doesn't
        // feel like it's randomly missing entries depending on hold space.
        // Every other offer location (bar, main spaceport, trade center,
        // shipyard, outfitter, pers-ship) is a single ad-hoc offer, not a
        // browsable list — those simply never come up at all if the cargo
        // wouldn't fit.
        if location != .missionComputer, !canAccept(mission) { return false }
        return true
    }

    /// True if the player currently has enough free cargo space to accept
    /// `mission` — used to disable (not hide) the Accept button, and as a
    /// last-line guard in `accept(_:)` itself. Distinct from `isEligible`,
    /// which governs whether the mission is offered/shown at all: a mission
    /// requiring more cargo than is currently free still shows up on the
    /// board, it just can't be accepted until room is made.
    public func canAccept(_ mission: MissionRes) -> Bool {
        guard mission.requiresCargoSpace else { return true }
        return freeCargoSpace() >= abs(mission.cargoQty)
    }

    /// The missions on offer at a spot, after applying each mission's random
    /// appearance chance. Deterministic given the engine's RNG state.
    ///
    /// **AvailRandom is a hard gate, not a "usually":** the Bible defines it as
    /// "100 = always available, 1–99 = available this % of the time" — and by
    /// omission **0 = never offered this way**. The hundreds of "Silent Mission"
    /// resources (started programmatically by another mission's `S<id>` SET or
    /// by a crön, never browsed) all carry AvailRandom 0; they must not surface
    /// at a bar/BBS. `rng.chance(percent:)` already returns false for 0, so we
    /// simply roll every candidate (the old `availRandom <= 0 ? true` short-
    /// circuit did the exact opposite — it forced every 0% silent mission to
    /// always appear, which is why the board was full of them).
    public func missionsOffered(at location: MissionOfferLocation, spob spobID: Int?) -> [MissionRes] {
        let offered = game.missions()
            .filter { isEligible($0, at: location, spobID: spobID) }
            .filter { rng.chance(percent: $0.availRandom) }
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
            title: resolvedName(for: mission),
            briefingText: brief,
            acceptButton: mission.acceptButton.isEmpty ? "Accept" : mission.acceptButton,
            refuseButton: mission.refuseButton.isEmpty ? "Decline" : mission.refuseButton,
            canRefuse: !mission.cannotBeRefused, canAccept: canAccept(mission))
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
        guard canAccept(m) else {
            Log.mission.debug("accept: mission \(missionID) (\"\(m.name, privacy: .public)\") refused — not enough free cargo space")
            return false
        }
        Log.mission.notice("accept: mission \(missionID) (\"\(m.name, privacy: .public)\") accepted")

        let deadline = m.timeLimit > 0 ? player.date.adding(days: m.timeLimit) : nil
        let cargoAtStart = m.cargoPickup == .atStart
        // Escort/observe goals are *passive* — the player completes them by
        // landing at the return stellar with the ships intact, not by
        // destroying/disabling/boarding them, so they carry no outstanding
        // objective count (a nonzero count would block landing-completion
        // forever, since nothing ever decrements it for these goals). Their
        // failure path is the ship being lost (`missionShipLost`), not a count.
        let passiveGoal = m.shipGoal == .escort || m.shipGoal == .observe
        let shipObjectives = (m.hasShipObjective && !passiveGoal) ? max(0, m.shipCount) : 0

        // Resolve any randomised cargo (CargoType 1000 = random standard 0–5,
        // CargoQty <= -2 = abs(qty) ± 50%) exactly **once**, here at accept, and
        // freeze it on the ActiveMission so pickup / drop-off / release all move
        // the same concrete commodity and tonnage every time.
        let (resolvedCargoType, resolvedCargoQty) = resolveCargo(for: m)

        player.activeMissions.append(ActiveMission(
            missionID: missionID,
            acceptedDate: player.date,
            deadline: deadline,
            cargoPickedUp: cargoAtStart,
            shipObjectivesRemaining: shipObjectives,
            travelSpobID: concreteStellar(m.travelStellar, salt: 0x7 &* UInt64(bitPattern: Int64(m.id))),
            returnSpobID: concreteStellar(m.returnStellar, salt: 0x51 &* UInt64(bitPattern: Int64(m.id))),
            resolvedCargoType: resolvedCargoType,
            resolvedCargoQty: resolvedCargoQty,
            acceptSystemID: player.currentSystem))

        if cargoAtStart, resolvedCargoQty != 0 {
            player.cargo[resolvedCargoType, default: 0] += resolvedCargoQty
            // LoadCargoText fires the moment the cargo is picked up — for an
            // "at start" pickup that is here, at accept.
            showMissionText(m.loadCargoText, for: m)
        }

        // PayVal's up-front-fee range (-50000 and below) is charged now, at
        // mission start — not on completion. Every other PayVal range applies
        // only on success (see `completeMission`).
        applyPayVal(m.pay, atAccept: true)

        apply(set: m.onAccept)
        services?.notify(.missionAccepted(missionID: missionID, name: m.name))

        // The post-accept briefing (BriefText) — "the dialog that comes up when
        // you accept a mission" — shown now, after the offer is accepted.
        let brief = acceptBriefing(for: m)
        if !brief.isEmpty { services?.showStoryText(brief, title: m.displayName) }

        // Missions whose special ships appear in the current system spawn now.
        if m.hasShipObjective { services?.spawnMissionShips(missionID: missionID, mission: m) }

        // A mission flagged "auto-abort when started" immediately completes/clears
        // — it exists only to run its OnAccept bits. That's only coherent for a
        // mission with no real objective: one the player must actually go fly a
        // ship-combat/cargo objective for was just told to spawn ships (above)
        // and given an `ActiveMission` entry, so self-aborting it right back out
        // would silently undo the accept — which read as "the same bar mission
        // keeps getting re-offered no matter how many times I take it," since
        // nothing ever marks it truly accepted. Respect the flag only when
        // there's nothing to actually go do.
        if m.autoAbortWhenStarted, shipObjectives == 0 {
            abortMission(missionID, silent: true)
        }
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
        let am = player.activeMissions[idx]
        releaseCargo(for: m, active: am)
        player.activeMissions.remove(at: idx)
        // CompReward reversal on abort: a mission flagged Flags 0x0040 ("big rep
        // hit for bailing") makes its CompGovt take the abort personally,
        // decreasing the player's record with that govt by 5× the CompReward.
        if let m, m.flags1 & 0x0040 != 0, m.compRewardGovt >= 128, m.compLegalReward != 0 {
            player.legalRecord[m.compRewardGovt, default: 0] += -5 * m.compLegalReward
        }
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

        let am = player.activeMissions[idx]
        // DropCargoText fires as the cargo leaves the hold at its drop-off point.
        // Shown only here, on the legitimate completion/delivery path — NOT on the
        // abort/fail `releaseCargo`, which are jettisons, not deliveries.
        showMissionText(m.dropCargoText, for: m)
        releaseCargo(for: m, active: am)
        player.activeMissions.remove(at: idx)
        player.completedMissions.insert(missionID)

        // Reward: PayVal (credits / clean-record ±allies/classmates / %-of-cash;
        // the up-front-fee range was already charged at accept), plus CompGovt
        // standing.
        applyPayVal(m.pay, atAccept: false)
        if m.compRewardGovt >= 128, m.compLegalReward != 0 {
            player.legalRecord[m.compRewardGovt, default: 0] += m.compLegalReward
        }

        apply(set: m.onSuccess)

        let text = resolveMissionText(game.descText(m.completionText, context: textContext), for: m)
        if !text.isEmpty { services?.showStoryText(text, title: m.displayName) }
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
        let am = player.activeMissions[idx]
        releaseCargo(for: m, active: am)
        player.activeMissions.remove(at: idx)
        player.failedMissions.insert(missionID)
        // CompReward reversal on failure: the Bible's "if you have a CompGovt and
        // reward defined and you fail the mission, that govt will take it
        // personally and decrease your record by 1/2 the amount."
        if m.compRewardGovt >= 128, m.compLegalReward != 0 {
            player.legalRecord[m.compRewardGovt, default: 0] += -(m.compLegalReward / 2)
        }
        apply(set: m.onFailure)
        if !m.canAbort {
            let text = resolveMissionText(game.descText(m.failureText, context: textContext), for: m)
            if !text.isEmpty { services?.showStoryText(text, title: m.displayName) }
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
                let type = am.resolvedCargoType ?? m.cargoType
                let qty = am.resolvedCargoQty ?? abs(m.cargoQty)
                if !updated.cargoPickedUp, qty != 0 {
                    player.cargo[type, default: 0] += qty
                    // LoadCargoText fires once, at the pickup — only on the
                    // first visit (before `cargoPickedUp` flips true).
                    showMissionText(m.loadCargoText, for: m)
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

    // MARK: - System visibility (bit-gated map objects)

    /// Whether system `systemID` is currently visible on the map / in nav. A
    /// `sÿst`'s `visibility` NCB **test** string gates its presence: blank (the
    /// common case) or true ⇒ visible; false ⇒ hidden. An unknown system id is
    /// treated as visible (don't hide things we can't resolve). This is how EV
    /// Nova makes systems appear/disappear mid-game via control bits.
    public func isSystemVisible(_ systemID: Int) -> Bool {
        guard let test = game.system(systemID)?.visibility, !test.isEmpty else { return true }
        return NCBTest(test).evaluate(player)
    }

    /// Every system currently hidden — those whose `visibility` NCB test is
    /// non-empty and evaluates false against the current pilot.
    public func hiddenSystemIDs() -> Set<Int> {
        var hidden = Set<Int>()
        for s in game.systems() where !s.visibility.isEmpty {
            if !NCBTest(s.visibility).evaluate(player) { hidden.insert(s.id) }
        }
        return hidden
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
        let wasRemaining = am.shipObjectivesRemaining
        am.shipObjectivesRemaining = max(0, am.shipObjectivesRemaining - 1)
        replace(am)
        guard let m = game.mission(missionID) else { return }

        // OnShipDone (Bible: "control bits set when the mission's special-ship
        // goal is completed") fires exactly ONCE, on the transition to 0 — the
        // `wasRemaining > 0` guard means a stray decrement after the goal is
        // already met can't re-fire the bits or re-show the text. This runs
        // BEFORE the "no return leg → complete" logic so the bits/text land
        // whether or not the mission also auto-completes here.
        if wasRemaining > 0, am.shipObjectivesRemaining == 0 {
            apply(set: m.onShipDone)
            showMissionText(m.shipDoneText, for: m)
        }

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
            payDailyTribute()
            payDailyEscortFees()
            evaluateCrons()
            evaluateDisasters()
            checkDeadlines()
        }
    }

    /// Roll each `öops` disaster: expire any whose duration has elapsed, then for
    /// each inactive one whose `ActivateOn` passes, run its daily `Freq`% chance
    /// to trigger — activating a timed price effect on one commodity at a stellar
    /// (Bible: "these occurrences simply affect the price of a single commodity").
    /// `Stellar == -2` records are news-flavor only (no price effect) and are
    /// skipped here.
    public func evaluateDisasters() {
        var active = player.activeDisasters ?? [:]
        // Expire finished disasters.
        for (oopsID, expiry) in active where player.date >= expiry {
            active[oopsID] = nil
        }
        // Roll inactive ones.
        for o in game.oopses() where o.stellar != -2 {
            guard active[o.id] == nil else { continue }
            guard o.freq > 0, o.duration > 0 else { continue }
            if !o.activateOn.isEmpty, !NCBTest(o.activateOn).evaluate(player) { continue }
            if rng.chance(percent: o.freq) {
                active[o.id] = player.date.adding(days: max(1, o.duration))
                Log.mission.debug("disaster \(o.id) '\(o.name, privacy: .public)' triggered until \(String(describing: active[o.id]), privacy: .public)")
                services?.notify(.disasterTriggered(oopsID: o.id))
            }
        }
        player.activeDisasters = active
    }

    /// Record a stellar as dominated by the player and fire its `OnDominate`
    /// control bits. The seam the app calls when the engine reports a
    /// `WorldEvent.stellarDominated`. Idempotent — re-dominating a planet already
    /// owned doesn't re-run its `OnDominate`.
    public func dominateStellar(_ spobID: Int) {
        guard !player.hasDominated(spobID) else { return }
        player.dominate(spobID)
        if let spob = game.spob(spobID), !spob.onDominate.isEmpty { apply(set: spob.onDominate) }
        services?.notify(.stellarDominated(spobID: spobID))
    }

    /// Release a stellar from the player's domination (it stops paying tribute)
    /// and fire its `OnRelease` control bits.
    public func releaseStellar(_ spobID: Int) {
        guard player.hasDominated(spobID) else { return }
        player.releaseDomination(spobID)
        if let spob = game.spob(spobID), !spob.onRelease.isEmpty { apply(set: spob.onRelease) }
        services?.notify(.stellarReleased(spobID: spobID))
    }

    /// Add each dominated stellar's daily tribute to the player's credits — the
    /// authentic EV Nova behavior (tribute accrues automatically as the day clock
    /// advances; it is *not* collected by landing). A stellar's `Tribute` field of
    /// `-1`/`0` means the default payout, `1000 × TechLevel` (`dailyTributeAmount`).
    /// See docs/reverse-engineering/DOMINATION.md.
    private func payDailyTribute() {
        guard let dominated = player.dominatedStellars, !dominated.isEmpty else { return }
        var payout = 0
        for spobID in dominated {
            guard let spob = game.spob(spobID) else { continue }
            payout += spob.dailyTributeAmount
        }
        if payout > 0 { player.credits += payout }
    }

    /// Deduct the daily upkeep for the player's **hired** escorts — EV Nova's
    /// recurring escort fee (captured/mission escorts are free). Charged once per
    /// in-game day, so a multi-day hyperspace leg bills each day automatically via
    /// the `advanceDays` loop. An escort the player can no longer afford "departs
    /// without ceremony" (Bible/community behavior): it's dropped from the roster
    /// and the app despawns its live ship on the `.escortDeparted` notification.
    /// Fees are processed cheapest-first so a partial balance keeps as many
    /// escorts as it can rather than losing the whole wing to one unaffordable one.
    private func payDailyEscortFees() {
        let hired = player.hiredEscorts
        guard !hired.isEmpty else { return }
        var charged = 0
        for escort in hired.sorted(by: { $0.dailyFee < $1.dailyFee }) {
            if player.credits >= escort.dailyFee {
                player.credits -= escort.dailyFee
                charged += escort.dailyFee
            } else {
                player.removeEscort(id: escort.id)
                services?.notify(.escortDeparted(escortID: escort.id, name: escort.name))
            }
        }
        if charged > 0 { services?.notify(.escortDailyFeeCharged(total: charged)) }
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
                runCronHook(c.onEnd, loop: c.loopEndUntilFalse, cron: c)
                Log.mission.debug("cron \(c.id) ended on \(String(describing: self.player.date), privacy: .public)")
                services?.notify(.cronEnded(cronID: c.id))
                rt.startedDate = nil
                rt.endDate = nil
                rt.earliestStart = player.date.adding(days: max(0, c.postHoldoff))
                player.cronRuntime[c.id] = rt
                continue
            }
            guard !rt.isActive else { player.cronRuntime[c.id] = rt; continue }

            // Already activated and holding for PreHoldoff days: start once the
            // pending date arrives (the gates are re-checked before activation,
            // not during the hold-off — once committed it will start).
            if let pending = rt.pendingStart {
                if player.date >= pending {
                    rt.pendingStart = nil
                    startCron(c, rt: &rt)
                }
                player.cronRuntime[c.id] = rt; continue
            }

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

            // Activated. PreHoldoff (Bible): hold in a waiting state for N days
            // before OnStart runs; without it, delayed-consequence crons fire
            // N days early. PreHoldoff 0 (the common case) starts immediately.
            if c.preHoldoff > 0 {
                rt.pendingStart = player.date.adding(days: c.preHoldoff)
                Log.mission.debug("cron \(c.id) activated, holding \(c.preHoldoff, privacy: .public)d before start")
            } else {
                startCron(c, rt: &rt)
            }
            player.cronRuntime[c.id] = rt
        }
    }

    /// Run a cron's OnStart, announce it, and schedule its end from `Duration`.
    /// Shared by the immediate-start and post-PreHoldoff paths.
    private func startCron(_ c: CronRes, rt: inout CronRuntime) {
        runCronHook(c.onStart, loop: c.loopStartUntilFalse, cron: c)
        Log.mission.debug("cron \(c.id) started on \(String(describing: self.player.date), privacy: .public)")
        services?.notify(.cronStarted(cronID: c.id))
        announceNews(for: c)
        rt.startedDate = player.date
        rt.endDate = player.date.adding(days: max(0, c.duration))
    }

    /// Hard cap on iterative-cron re-evaluation, so a `Flags 0x0001`/`0x0002`
    /// cron whose OnStart/OnEnd never falsifies its own `EnableOn` can't spin
    /// forever (the Bible warns these "can infinite-loop!").
    private static let cronLoopCap = 1000

    /// Run a cron's OnStart/OnEnd SET expression. Normally (loop == false) this
    /// applies it exactly once — the unchanged legacy path. When the cron sets
    /// its iterative flag (`0x0001` entry / `0x0002` exit), keep re-running the
    /// expression while `EnableOn` still evaluates true **and** the `Require`
    /// capability gate is still satisfied, up to `cronLoopCap` iterations.
    private func runCronHook(_ expr: String, loop: Bool, cron c: CronRes) {
        apply(set: expr)
        guard loop else { return }
        var iterations = 1
        while iterations < Self.cronLoopCap {
            guard NCBTest(c.enableOn).evaluate(player) else { break }
            if c.require != 0, (activeContributeBits() & c.require) != c.require { break }
            apply(set: expr)
            iterations += 1
        }
        if iterations >= Self.cronLoopCap {
            Log.mission.error("cron \(c.id) iterative hook hit cap \(Self.cronLoopCap); aborting loop (possible infinite EnableOn)")
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

    /// The news the player reads at a station owned by `govt` (`nil` = an
    /// independent/no-government station), applying the Bible's precedence:
    /// *"local news always takes precedence over independent news"*. If any
    /// active crön carries **local** news tagged for this govt — or a government
    /// allied with it — those strings are returned; only when there is no
    /// applicable local news does the shared **independent** pool show instead.
    /// Empty ⇒ nothing in the news today. Resolved fresh at the station (the one
    /// place that knows which govt applies), not popped when the crön fires.
    public func stationNews(forGovt govt: Int?) -> [String] {
        var local: [String] = []
        var independent: [String] = []
        for (cronID, rt) in player.cronRuntime where rt.isActive {
            guard let c = game.cron(cronID) else { continue }
            if let govt {
                for i in 0..<4 {
                    let newsGovt = c.newsGovts[i]
                    guard c.govtNewsStrs[i] > 0, newsGovt >= 0,
                          newsGovt == govt || govtsAllied(govt, newsGovt) else { continue }
                    if let s = randomStringListEntry(c.govtNewsStrs[i]) { local.append(s) }
                }
            }
            if c.independentNewsStrID > 0, let s = randomStringListEntry(c.independentNewsStrID) {
                independent.append(s)
            }
        }
        return local.isEmpty ? independent : local
    }

    /// Whether governments `a` and `b` are allied (class-based, per `gövt`:
    /// A is allied with B if A's `Allies` classes intersect B's `Classes`).
    /// Checked both directions so the relation is symmetric for news purposes.
    private func govtsAllied(_ a: Int, _ b: Int) -> Bool {
        guard a != b, let ga = game.govt(a), let gb = game.govt(b) else { return false }
        let aAllies = Set(ga.allies.filter { $0 != -1 })
        let bAllies = Set(gb.allies.filter { $0 != -1 })
        let aClasses = Set(ga.classes.filter { $0 != -1 })
        let bClasses = Set(gb.classes.filter { $0 != -1 })
        return !aAllies.isDisjoint(with: bClasses) || !bAllies.isDisjoint(with: aClasses)
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

    private func releaseCargo(for m: MissionRes?, active: ActiveMission?) {
        guard let m else { return }
        // Use the concrete commodity/tonnage frozen at accept when present, so a
        // randomised cargo is *removed* in exactly the amount it was *added*.
        // Legacy saves (nil) fall back to the static mïsn fields.
        let type = active?.resolvedCargoType ?? m.cargoType
        let qty = active?.resolvedCargoQty ?? abs(m.cargoQty)
        guard qty != 0 else { return }
        let held = player.cargo[type] ?? 0
        let remaining = held - qty
        player.cargo[type] = remaining > 0 ? remaining : nil
    }

    /// Resolve a mission's cargo commodity + tonnage to concrete values, rolling
    /// the two randomised codes with the engine RNG:
    ///   • `CargoType == 1000` → a random standard commodity 0–5.
    ///   • `CargoQty  <= -2`   → `abs(qty)` ± 50% (uniform over `[½·n … 1½·n]`).
    /// Every other value passes through unchanged (`CargoType` literal, `CargoQty`
    /// its absolute tonnage). Called exactly once per accept.
    private func resolveCargo(for m: MissionRes) -> (type: Int, qty: Int) {
        let type = m.cargoType == 1000 ? rng.int(6) : m.cargoType
        let qty: Int
        if m.cargoQty <= -2 {
            let base = abs(m.cargoQty)
            let low = base - base / 2          // ½·n (floored)
            let high = base + base / 2         // 1½·n (floored)
            qty = low + rng.int(high - low + 1)
        } else {
            qty = abs(m.cargoQty)
        }
        return (type, qty)
    }

    // MARK: - PayVal (the overloaded mïsn `pay` field)

    /// Apply a mïsn `PayVal` (`pay`) code with its full overloaded semantics.
    /// `atAccept == true` runs only the up-front-fee branch (the `-50000`-and-
    /// below range, charged when the mission starts); `atAccept == false` (on
    /// success) runs every other range. Ranges are guarded precisely so an
    /// ordinary positive pay or a plain uncoded negative fee (e.g. `-500`) stays a
    /// literal credit delta — only the exact documented ranges are special.
    private func applyPayVal(_ code: Int, atAccept: Bool) {
        // Up-front fee: -50000 and below → charge (abs(code) - 50000) credits at
        // mission start, and NOT again on completion.
        if code <= -50000 {
            guard atAccept else { return }
            let fee = abs(code) - 50000
            if fee != 0 { changeCredits(by: -fee) }
            return
        }
        // Everything else applies on completion only.
        guard !atAccept else { return }

        switch code {
        case 0, -1:
            return                                      // no pay

        case -10383 ... -10128:                         // clean record with a govt
            player.clearLegalRecord(govt: -10000 - code)

        case -20383 ... -20128:                         // …and all its allies
            cleanLegalRecord(govt: -20000 - code, includeAllies: true, includeClassmates: false)

        case -30383 ... -30128:                         // …and all its classmates
            cleanLegalRecord(govt: -30000 - code, includeAllies: false, includeClassmates: true)

        case -40099 ... -40001:                         // take this % of the cash
            let pct = -40000 - code                     // -40001 → 1 … -40099 → 99
            let take = player.credits * pct / 100
            if take != 0 { changeCredits(by: -take) }

        default:
            // Positive pay, or any uncoded negative value, is a literal delta.
            changeCredits(by: code)
        }
    }

    /// Adjust the player's credit balance and surface the change.
    private func changeCredits(by delta: Int) {
        guard delta != 0 else { return }
        player.credits += delta
        services?.notify(.creditsChanged(delta: delta, total: player.credits))
    }

    /// Clean the player's legal record with `govt`, and optionally with every
    /// government allied with it (govts whose `classes` intersect `govt`'s ally
    /// classes) and/or its classmates (govts sharing one of `govt`'s classes) —
    /// the `PayVal` -20128/-30128 ranges. Allies/classmates are class-based in
    /// `gövt`, so we resolve them by class intersection.
    private func cleanLegalRecord(govt: Int, includeAllies: Bool, includeClassmates: Bool) {
        player.clearLegalRecord(govt: govt)
        guard let g = game.govt(govt) else {
            Log.mission.error("cleanLegalRecord: unknown govt \(govt); cleared only that record")
            return
        }
        var classes = Set<Int>()
        if includeAllies { classes.formUnion(g.allies) }
        if includeClassmates { classes.formUnion(g.classes) }
        guard !classes.isEmpty else { return }
        for other in game.govts() where other.id != govt {
            if !Set(other.classes).isDisjoint(with: classes) {
                player.clearLegalRecord(govt: other.id)
            }
        }
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

    /// The fully-resolved offer briefing for a mission (conditionals + `<…>`
    /// wildcards expanded). Public so callers can skip presenting an offer that
    /// has no text to show (e.g. a background "silent" mission).
    public func briefing(for m: MissionRes) -> String { briefingText(for: m) }

    /// The mission's player-visible **name** with its `<…>` wildcards expanded —
    /// e.g. "Ferry Passengers to <DST>" → "Ferry Passengers to New Babylon".
    /// The generic BBS/bar missions put the destination in their name, so the
    /// list and offer title must resolve it too, not just the briefing body.
    public func resolvedName(for m: MissionRes) -> String {
        resolveMissionText(m.displayName, for: m)
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
    }

    /// Summaries of every currently-accepted mission, in acceptance order.
    public func activeMissionSummaries() -> [MissionSummary] {
        player.activeMissions.compactMap { am in
            guard let m = game.mission(am.missionID) else { return nil }
            // Before the travel stellar is reached, point at it; afterward point
            // at the return stellar (the drop-off), mirroring EV Nova's arrow.
            let targetSpob: Int?
            if !am.visitedTravelStellar, let t = am.travelSpobID {
                targetSpob = t
            } else {
                targetSpob = am.returnSpobID ?? am.travelSpobID
            }
            let sys = targetSpob.flatMap { s in game.systems().first { $0.spobs.contains(s) } }
            return MissionSummary(
                id: am.missionID,
                name: resolvedName(for: m),
                payload: missionQuickBrief(for: m),
                objective: missionObjective(m: m, am: am, targetSpob: targetSpob),
                destinationSpobID: targetSpob,
                destinationSpob: targetSpob.flatMap { game.spob($0)?.displayName } ?? "",
                destinationSystemID: sys?.id,
                destinationSystem: sys?.name ?? "",
                deadline: am.deadline,
                canAbort: m.canAbort)
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
            switch m.shipGoal {
            case .escort, .observe:
                // Passive goals — no countable progress; they complete on landing.
                parts.append("\(verb) \(m.shipCount) ship\(m.shipCount == 1 ? "" : "s")")
            default:
                let total = max(1, m.shipCount)
                if am.shipObjectivesRemaining > 0 {
                    parts.append("\(verb) ships (\(total - am.shipObjectivesRemaining)/\(total))")
                } else {
                    parts.append("\(verb) ships — done ✓")
                }
            }
        }
        if let t = targetSpob, let name = game.spob(t)?.displayName {
            if m.cargoQty != 0, !am.visitedTravelStellar {
                parts.append("Deliver cargo to \(name)")
            } else if !am.visitedTravelStellar, am.travelSpobID == t {
                parts.append("Travel to \(name)")
            } else {
                parts.append("Report to \(name)")
            }
        }
        return parts.isEmpty ? "See mission briefing" : parts.joined(separator: " · ")
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

    /// A trimmed one-liner describing an accepted mission (its pitch text with
    /// wildcards resolved, whitespace collapsed) for compact list rows.
    private func missionQuickBrief(for m: MissionRes) -> String {
        let full = resolveMissionText(game.descText(m.offerTextID, context: textContext), for: m)
        let collapsed = full.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// The systems that currently hold an active-mission destination — used by the
    /// galaxy map to draw its orange "go here" arrows.
    public func missionDestinationSystemIDs() -> [Int] {
        Array(Set(activeMissionSummaries().compactMap(\.destinationSystemID))).sorted()
    }

    /// The text shown in the **offer** dialog: EV Nova's initial mission
    /// description (dësc 4000-4255, by convention `offerTextID` = 3872 + id) —
    /// the pitch. NOT `BriefText`, which the Bible defines as "the desc to show
    /// in the dialog that comes up when you accept a mission" (a *post-accept*
    /// briefing); showing that here put a mission's acceptance/farewell text in
    /// front of the still-live Accept/Decline buttons. `BriefText` is instead
    /// shown by `acceptBriefing(for:)` after the player accepts. Both the `{…}`
    /// conditionals and the `<…>` wildcards are expanded.
    private func briefingText(for m: MissionRes) -> String {
        resolveMissionText(game.descText(m.offerTextID, context: textContext), for: m)
    }

    /// The post-accept briefing (mïsn `BriefText`, "the dialog that comes up
    /// when you accept") — empty when the mission defines none.
    public func acceptBriefing(for m: MissionRes) -> String {
        guard m.briefText >= 128 else { return "" }
        return resolveMissionText(game.descText(m.briefText, context: textContext), for: m)
    }

    /// Resolve and surface one of a mission's intermediate `dësc` texts
    /// (`ShipDoneText`, `LoadCargoText`, `DropCargoText`, …) through the SAME
    /// pipeline the completion/failure texts use: an id `< 128` (the -1/none
    /// sentinel range) is skipped, and an empty resolved body is never shown.
    private func showMissionText(_ descID: Int, for m: MissionRes) {
        guard descID >= 128 else { return }
        let text = resolveMissionText(game.descText(descID, context: textContext), for: m)
        if !text.isEmpty { services?.showStoryText(text, title: m.displayName) }
    }

    /// Expand a mission-related `dësc` body's `<…>` wildcards (`<PN>`, `<CQ>`,
    /// `<DSY>`…) for this mission and the current pilot. Callers pass text that
    /// has already had its `{…}` conditionals resolved by `descText`.
    func resolveMissionText(_ text: String, for m: MissionRes) -> String {
        // An accepted mission has its concrete destination frozen at accept time;
        // an offer resolves one deterministically so the offer text and the later
        // accepted text name the same world.
        let active = player.activeMissions.first { $0.missionID == m.id }
        let travel = active?.travelSpobID ?? concreteStellar(m.travelStellar, salt: 0x7 &* UInt64(bitPattern: Int64(m.id)))
        let ret = active?.returnSpobID ?? concreteStellar(m.returnStellar, salt: 0x51 &* UInt64(bitPattern: Int64(m.id)))
        return MissionText.resolve(text, mission: m, player: player, game: game, initialSpob: initialSpob,
                                   travelSpob: travel, returnSpob: ret)
    }

    /// Resolve a mission travel/return selector to a **concrete** stellar id.
    /// Fixed ids (≥128) pass through; random selectors (-2 any inhabited, -3 any
    /// uninhabited, 9999-10255 a govt's stellar, …) are matched via `StellarMatch`
    /// and one candidate is picked **deterministically** from the current landing
    /// (date × spob × mission), so the same destination shows in the list, the
    /// offer, and the accepted mission — not a different world each render.
    /// Returns nil for "-1 no destination" or when nothing matches.
    public func concreteStellar(_ code: Int, salt: UInt64) -> Int? {
        // Only 128...2175 is a literal spob id (`StellarMatching.swift`'s
        // documented ranges) — govt/class/independent selector codes (9999,
        // 10000+g, 15000+g, 20000+g, 25000+g, 30000+g, 31000+g) are also
        // >= 128 but are NOT literal ids; they must fall through to the
        // StellarMatch-based candidate search below. Treating every code
        // >= 128 as literal (the old check) made a random-destination mission
        // resolve to a bogus "spob #10000"-style lookup, which silently
        // rendered as the "your destination"/"an unknown system" placeholder
        // in mission text instead of the real, randomly-chosen world.
        if (128...2175).contains(code) { return code }
        if code == -1 { return nil }
        let candidates = game.spobs()
            .filter { $0.id != (initialSpob ?? -1) }   // not where the mission is offered
            .filter { StellarMatch.spob(code: code, spobID: $0.id, game: game, initialSpob: initialSpob) }
            .map { $0.id }
            .sorted()
        guard !candidates.isEmpty else { return nil }
        var h = UInt64(bitPattern: Int64(player.date.julianDay)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(initialSpob ?? 0)) &* 0xD1B54A32D192ED03
        h ^= salt
        return candidates[Int(h % UInt64(candidates.count))]
    }

    /// The `{…}`-conditional context for this pilot (control bits + gender),
    /// so mission/desc text resolves its `{bXXX …}`/`{G …}` segments correctly.
    var textContext: NovaTextContext {
        NovaTextContext(isBitSet: { [player] in player.setBits.contains($0) },
                        isMale: player.isMale)
    }
}
