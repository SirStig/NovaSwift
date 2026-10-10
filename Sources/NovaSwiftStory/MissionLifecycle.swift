import Foundation
import NovaSwiftKit
import NovaSwiftEngine

// MARK: - Mission lifecycle: activation, objectives, resolution
//
// The original's runtime, slot by slot: activation (0x0043f100), the per-slot
// objective pass that runs every flight tick and twice per landing
// (0x00443c60), the landing pass (0x00443780) and the four ways a slot ends —
// success (0x00440410), final failure (0x00440930), auto-abort (0x00447d90)
// and abort (0x00440aa0). A failed mission stays in its slot until the player
// lands at its return stellar; a deadline only fails a mission in flight.

extension StoryEngine {

    /// STR# 2002 ("misc") entries the lifecycle shows.
    private enum MiscString {
        static let list = 2002
        static let missionShipLost = 0x11c   // a mission ship was lost — mission failed
        static let timeLimitExceeded = 0x11d // "Time limit exceeded - mission failed."
        static let noCargoRoomAccept = 0x163     // #355 "…enough cargo space to accept this mission"
        static let noFreeCargoRoomAccept = 0x164 // #356 "…enough free cargo space to accept…"
        static let noCargoRoom = 0x165           // #357 "…enough cargo space to load this cargo"
        static let noFreeCargoRoom = 0x166       // #358 "…enough free cargo space to load…"
    }

    // MARK: Slots

    func slotIndex(serial: Int) -> Int? {
        player.activeMissions.firstIndex { $0.serial == serial }
    }

    /// The slots of `missionID`, oldest first, by serial.
    private func serials(of missionID: Int) -> [Int] {
        ensureSerials()
        return player.activeMissions.filter { $0.missionID == missionID }.compactMap(\.serial)
    }

    /// Bring slots from an older save onto the original's runtime: a serial,
    /// and — when the old count says the ships are dealt with — goal counters
    /// that say so too, with the objective latched so OnShipDone, which the
    /// old code already ran, doesn't fire again.
    private func ensureSerials() {
        for i in player.activeMissions.indices where player.activeMissions[i].serial == nil {
            player.activeMissions[i].serial = nextSerial()
            let am = player.activeMissions[i]
            guard am.objectiveComplete == nil, let m = game.mission(am.missionID) else { continue }
            if m.hasShipObjective, am.shipObjectivesRemaining == 0 {
                switch m.shipGoal {
                case .disable:        player.activeMissions[i].shipsDisabled = m.shipCount
                case .board, .rescue: player.activeMissions[i].shipsBoarded = m.shipCount
                case .escort, .observe: player.activeMissions[i].shipsSighted = true
                default:              player.activeMissions[i].shipsDestroyed = m.shipCount
                }
                player.activeMissions[i].objectiveComplete = true
            }
        }
    }

    /// The first of the 16 slots no active mission holds (0x0043f100).
    private func firstFreeSlot() -> Int {
        let used = Set(player.activeMissions.enumerated().map { $0.element.slot ?? $0.offset })
        return (0..<PlayerState.missionSlotCount).first { !used.contains($0) } ?? player.activeMissions.count
    }

    private func nextSerial() -> Int {
        let s = player.nextMissionSerial ?? 1
        player.nextMissionSerial = s + 1
        return s
    }

    /// The return stellar of an accepted mission. ReturnStel -1 means the
    /// travel stellar; slots from saves made before that rule fall back to it.
    func returnStellar(of am: ActiveMission, _ m: MissionRes) -> Int? {
        if let r = am.returnSpobID { return r }
        return m.returnStellar == -1 ? am.travelSpobID : nil
    }

    // MARK: Activation (0x0043f100)

    /// Accept a mission the player was offered, with the targets its offer
    /// showed. Returns false when activation fails (no cargo room, or all 16
    /// slots taken). A lane offer (bar, spaceport, shops) is then out of the
    /// lane — or, if activation failed, re-offered after a context change.
    @discardableResult
    public func accept(_ missionID: Int) -> Bool {
        guard let m = game.mission(missionID) else {
            Log.mission.error("accept: unknown mission id \(missionID)")
            return false
        }
        let ok = activate(m, targets: offerTargets(for: m))
        if isLaneLocation(m.availLocation) {
            recordLaneOffer(missionID, ok ? .closed : .activationFailed)
        }
        if ok, player.landedSpob != nil { compactOfferLists(accepted: missionID) }
        return ok
    }

    /// Start a mission from a script (`S`): fresh targets, no eligibility
    /// gates and no "already active" check — a second `S` opens a second slot
    /// (OQ D9). Fails silently when activation does.
    public func startMission(_ missionID: Int) {
        guard let m = game.mission(missionID) else {
            Log.mission.error("startMission: unknown mission id \(missionID)")
            return
        }
        _ = activate(m, targets: resolveTargets(for: m))
    }

    private func isLaneLocation(_ l: MissionOfferLocation) -> Bool {
        l == .bar || l == .mainSpaceport || l == .tradeCenter || l == .shipyard || l == .outfitter
    }

    private func activate(_ m: MissionRes, targets t: MissionTargets) -> Bool {
        // The free slot comes first and fails silently; only then the cargo
        // room, with the "to accept this mission" texts (0x0043f100).
        ensureSerials()
        guard player.activeMissions.count < PlayerState.missionSlotCount else {
            Log.mission.notice("activate: mission \(m.id) refused — all \(PlayerState.missionSlotCount) mission slots in use")
            return false
        }
        if t.cargoQty > 0, cargoCapacity() < t.cargoQty || freeCargoSpace() < t.cargoQty {
            Log.mission.debug("activate: mission \(m.id) refused — no room for \(t.cargoQty)t")
            showMiscText(cargoCapacity() < t.cargoQty ? MiscString.noCargoRoomAccept : MiscString.noFreeCargoRoomAccept)
            return false
        }
        Log.mission.notice("accept: mission \(m.id) (\"\(m.name, privacy: .public)\") accepted")

        let serial = nextSerial()
        var am = ActiveMission(
            missionID: m.id, acceptedDate: player.date, deadline: m.timeLimit > 0 ? t.deadline : nil,
            cargoPickedUp: false,
            shipObjectivesRemaining: m.hasShipObjective ? max(0, m.shipCount) : 0,
            travelSpobID: t.travelSpob, returnSpobID: t.returnSpob,
            resolvedCargoType: t.cargoType >= 0 ? t.cargoType : nil,
            resolvedCargoQty: t.cargoType >= 0 ? t.cargoQty : nil,
            acceptSystemID: player.currentSystem)
        am.serial = serial
        am.failed = false
        am.objectiveComplete = false
        am.slot = firstFreeSlot()
        populateMissionShips(&am, m)
        am.shipSystemResolved = true
        player.activeMissions.append(am)

        // OnAccept runs first, then the acceptance fee (clamped at 0), then
        // the at-start cargo and the travel latch.
        runScript(m.onAccept, m, "OnAccept")
        if m.pay < -50000 { setCredits(max(0, player.credits - (-50000 - m.pay))) }
        guard let i = slotIndex(serial: serial) else { return true }   // OnAccept aborted it
        if m.cargoPickup == .atStart { loadCargo(at: i) }
        let travel = player.activeMissions[i].travelSpobID
        player.activeMissions[i].visitedTravelStellar = travel == nil
            || (player.landedSpob != nil && geography.equivalent(travel, player.landedSpob))
        offerState.zeroedRolls.insert(m.id)
        services?.notify(.missionAccepted(missionID: m.id, name: m.name))

        // The acceptance dialogs: BriefText, then LoadCargoText for cargo
        // aboard from the start.
        let brief = acceptBriefing(for: m)
        if !brief.isEmpty { services?.showStoryText(brief, title: resolvedName(for: m)) }
        if m.cargoPickup == .atStart, let i = slotIndex(serial: serial) {
            showMissionText(m.loadCargoText, for: m, active: player.activeMissions[i])
        }
        if m.shipCount > 0, m.shipDude >= 128 { services?.spawnMissionShips(missionID: m.id, mission: m) }

        // A no-ship auto-abort mission accepted while docked, with its travel
        // leg already done and no return stellar, resolves on the spot.
        if player.landedSpob != nil, m.autoAbortWhenStarted, m.shipCount == 0,
           let i = slotIndex(serial: serial), player.activeMissions[i].visitedTravelStellar,
           player.activeMissions[i].returnSpobID == nil {
            resolveAutoAbort(serial: serial)
        }
        return true
    }

    /// The player declined an offered mission: RefuseText, then OnRefuse.
    public func decline(_ missionID: Int) {
        guard let m = game.mission(missionID) else {
            Log.mission.error("decline: unknown mission id \(missionID)")
            return
        }
        Log.mission.debug("decline: mission \(missionID) (\"\(m.name, privacy: .public)\") declined")
        let refusal = resolveMissionText(game.descText(m.refuseText, context: textContext), for: m)
        if !refusal.isEmpty { services?.showStoryText(refusal, title: resolvedName(for: m)) }
        runScript(m.onRefuse, m, "OnRefuse")
        if isLaneLocation(m.availLocation) { recordLaneOffer(missionID, .closed) }
    }

    // MARK: The objective pass (0x00443c60)

    /// Run the per-mission objective pass as a flight tick does: latch
    /// completion, fail missions whose time ran out, fire OnShipDone and
    /// resolve auto-abort missions. The app runs it on launch, after a jump's
    /// days, and after mission-ship events.
    public func missionFlightPass() {
        ensureSerials()
        for serial in player.activeMissions.compactMap(\.serial) {
            evaluateObjective(serial: serial, landing: false)
        }
    }

    /// The player lifted off: the docked state ends, a staged `Q` message is
    /// handed back for the launch line, and the flight pass runs.
    public func playerLaunched() -> String? {
        player.landedSpob = nil
        let message = player.pendingLaunchMessage
        player.pendingLaunchMessage = nil
        missionFlightPass()
        return message
    }

    private func evaluateObjective(serial: Int, landing: Bool) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) else { return }
        var am = player.activeMissions[i]
        let wasComplete = am.objectiveComplete ?? false
        let target = m.shipCount
        var failed = am.isFailed
        var complete = wasComplete
        if m.shipGoal == .none || target < 1 {
            complete = true
        } else {
            let destroyed = am.shipsDestroyed ?? 0, disabled = am.shipsDisabled ?? 0
            switch m.shipGoal {
            case .destroy:
                if destroyed >= target { complete = true }
            case .disable:
                // Destroying a disable target — even one already disabled —
                // fails the mission.
                if destroyed < 1 { if disabled >= target { complete = true } } else { failed = true }
            case .board, .rescue:
                if (am.shipsBoarded ?? 0) >= target { complete = true }
            case .escort:
                // Complete while the escorted ships are alive and unharmed;
                // any one destroyed or disabled fails it.
                if destroyed < 1, disabled < 1 { complete = am.shipsSighted ?? false } else { failed = true }
            case .observe:
                if am.shipsSighted ?? false { complete = true }
            case .chaseOff:
                complete = (am.shipsChasedOff ?? 0) + destroyed >= target
            case .none:
                complete = true
            }
        }
        am.objectiveComplete = complete
        am.failed = failed
        player.activeMissions[i] = am

        // The deadline arm: the countdown ran out — fail in flight only.
        if !failed, !landing, let deadline = am.deadline, player.date >= deadline {
            if !m.invisible { showMiscOverlay(MiscString.timeLimitExceeded) }
            quickFail(serial: serial)
            return
        }
        // First completion: ShipDoneText, OnShipDone, and auto-abort.
        if !failed, complete, !wasComplete {
            showMissionText(m.shipDoneText, for: m, active: am)
            if m.shipGoal != .none { runScript(m.onShipDone, m, "OnShipDone") }
            if m.autoAbortWhenStarted { resolveAutoAbort(serial: serial) }
        }
    }

    // MARK: The landing pass (0x00443780)

    /// The player landed on `spobID`: the offer lists refresh, and every
    /// mission runs its landing pass — cargo pickup and drop-off at the travel
    /// stellar, delivery at the return stellar, and success (travel leg done
    /// and objective complete) or the final resolution of a failed mission
    /// there. Deadlines don't fail anything while docked.
    public func playerLanded(onSpob spobID: Int) {
        player.landedSpob = spobID
        if let sys = game.systemContaining(spob: spobID) {
            player.landedSystems = (player.landedSystems ?? []).union([sys])
            player.exploredSystems.insert(sys)
        }
        refreshOffersOnLanding(at: spobID)
        ensureSerials()
        var anySuccess = false
        for serial in player.activeMissions.compactMap(\.serial) {
            evaluateObjective(serial: serial, landing: true)
            landingCargo(serial: serial, at: spobID)
            if let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) {
                let am = player.activeMissions[i]
                if geography.equivalent(returnStellar(of: am, m), spobID) {
                    if am.travelSpobID == nil || am.travelSpobID == returnStellar(of: am, m) {
                        player.activeMissions[i].visitedTravelStellar = true
                    }
                    if !am.isFailed {
                        if m.shipGoal == .escort, (am.shipsDestroyed ?? 0) < 1 {
                            player.activeMissions[i].objectiveComplete = true
                        }
                        let a = player.activeMissions[i]
                        if a.visitedTravelStellar, a.objectiveComplete ?? false {
                            resolveSuccess(serial: serial)
                            anySuccess = true
                        }
                    } else {
                        resolveFailure(serial: serial)
                    }
                }
            }
            evaluateObjective(serial: serial, landing: true)
        }
        // A success here rebuilds the lists (0x00443780).
        if anySuccess {
            offerState.removed = []
            offerState.targets = [:]
            buildOfferLists(atSpob: spobID)
        } else if offerState.computerList == nil || offerState.laneList == nil {
            buildOfferLists(atSpob: spobID)
        }
    }

    /// Cargo at the travel and return stellars (0x004438d0).
    private func landingCargo(serial: Int, at spobID: Int) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) else { return }
        let am = player.activeMissions[i]
        if geography.equivalent(am.travelSpobID, spobID) {
            if m.cargoPickup == .atTravelStellar, !am.cargoPickedUp {
                if cargoRoomCheck(am.resolvedCargoQty ?? 0) {
                    loadCargo(at: i)
                    player.activeMissions[i].visitedTravelStellar = true
                    showMissionText(m.loadCargoText, for: m, active: player.activeMissions[i])
                }
            } else {
                player.activeMissions[i].visitedTravelStellar = true
            }
            if m.cargoDropoff == .atTravelStellar, player.activeMissions[i].isCarryingCargo {
                unloadCargo(at: i)
                showMissionText(m.dropCargoText, for: m, active: player.activeMissions[i])
            }
        }
        let a = player.activeMissions[i]
        if geography.equivalent(returnStellar(of: a, m), spobID), m.cargoDropoff == .atReturnStellar,
           a.isCarryingCargo,
           (a.objectiveComplete ?? false) || m.shipGoal == .none
            || (m.shipGoal == .escort && (a.shipsDestroyed ?? 0) < 1) {
            unloadCargo(at: i)
            showMissionText(m.dropCargoText, for: m, active: player.activeMissions[i])
        }
    }

    // MARK: Mission-ship events (MS-11)

    /// A mission ship was destroyed. Destroying a disable, escort or
    /// not-yet-boarded board/rescue target fails the mission at once.
    public func missionShipDestroyed(missionID: Int, wasBoarded: Bool = false) {
        guard let serial = serials(of: missionID).first(where: { slotIndex(serial: $0).map { !player.activeMissions[$0].isFailed } ?? false })
                ?? serials(of: missionID).first,
              let i = slotIndex(serial: serial), let m = game.mission(missionID) else { return }
        let am = player.activeMissions[i]
        let failShape = m.shipGoal == .disable || m.shipGoal == .escort
            || ((m.shipGoal == .board || m.shipGoal == .rescue) && !wasBoarded)
        player.activeMissions[i].shipsDestroyed = (am.shipsDestroyed ?? 0) + 1
        updateRemaining(at: i, m)
        if (am.shipsDestroyed ?? 0) == 0, failShape, !am.isFailed, !m.invisible {
            showMiscOverlay(MiscString.missionShipLost)
            quickFail(serial: serial)
        }
        evaluateObjective(serial: serial, landing: player.landedSpob != nil)
    }

    /// A mission ship was disabled. Losing an escort this way fails the
    /// mission.
    public func missionShipDisabled(missionID: Int) {
        guard let serial = serials(of: missionID).first, let i = slotIndex(serial: serial),
              let m = game.mission(missionID) else { return }
        let am = player.activeMissions[i]
        player.activeMissions[i].shipsDisabled = (am.shipsDisabled ?? 0) + 1
        updateRemaining(at: i, m)
        if (am.shipsDisabled ?? 0) == 0, m.shipGoal == .escort, !am.isFailed, !m.invisible {
            showMiscOverlay(MiscString.missionShipLost)
            quickFail(serial: serial)
        }
        evaluateObjective(serial: serial, landing: player.landedSpob != nil)
    }

    /// A mission ship was boarded. `CargoPickup == 2` loads the cargo here,
    /// if there is room for it; returns false when there isn't, and the board
    /// is refused.
    @discardableResult
    public func missionShipBoarded(missionID: Int) -> Bool {
        guard let serial = serials(of: missionID).first, let i = slotIndex(serial: serial),
              let m = game.mission(missionID) else { return true }
        let am = player.activeMissions[i]
        if m.cargoPickup == .onSpecialShip, !am.cargoPickedUp {
            guard cargoRoomCheck(am.resolvedCargoQty ?? 0) else { return false }
            loadCargo(at: i)
            showMissionText(m.loadCargoText, for: m, active: player.activeMissions[i])
            player.activeMissions[i].shipsBoarded = (am.shipsBoarded ?? 0) + 1
        } else if m.shipGoal == .board || m.shipGoal == .rescue {
            player.activeMissions[i].shipsBoarded = (am.shipsBoarded ?? 0) + 1
        }
        updateRemaining(at: i, m)
        evaluateObjective(serial: serial, landing: player.landedSpob != nil)
        return true
    }

    /// A mission ship left the system — the chase-off goal counts these.
    public func missionShipLeft(missionID: Int) {
        guard let serial = serials(of: missionID).first, let i = slotIndex(serial: serial),
              let m = game.mission(missionID) else { return }
        player.activeMissions[i].shipsChasedOff = (player.activeMissions[i].shipsChasedOff ?? 0) + 1
        updateRemaining(at: i, m)
        evaluateObjective(serial: serial, landing: player.landedSpob != nil)
    }

    /// The mission's ships are in the player's system and in view: an escort
    /// goal counts as under way, an observe goal as done.
    public func missionShipsSighted(missionID: Int) {
        guard let serial = serials(of: missionID).first, let i = slotIndex(serial: serial),
              !(player.activeMissions[i].shipsSighted ?? false) else { return }
        player.activeMissions[i].shipsSighted = true
        evaluateObjective(serial: serial, landing: player.landedSpob != nil)
    }

    /// An escorted or rescued ship was destroyed by someone else.
    public func missionShipLost(missionID: Int) {
        guard let m = game.mission(missionID) else {
            Log.mission.error("missionShipLost: unknown mission id \(missionID)")
            return
        }
        if m.shipGoal == .escort || m.shipGoal == .rescue { missionShipDestroyed(missionID: missionID) }
    }

    /// Keep the "ships still to deal with" count the spawner reads in step
    /// with the goal counters.
    private func updateRemaining(at i: Int, _ m: MissionRes) {
        guard m.hasShipObjective else { return }
        let am = player.activeMissions[i]
        let done: Int
        switch m.shipGoal {
        case .disable:        done = (am.shipsDisabled ?? 0) + (am.shipsDestroyed ?? 0)
        case .board, .rescue: done = (am.shipsBoarded ?? 0) + (am.shipsDestroyed ?? 0)
        case .chaseOff:       done = (am.shipsChasedOff ?? 0) + (am.shipsDestroyed ?? 0)
        default:              done = am.shipsDestroyed ?? 0
        }
        player.activeMissions[i].shipObjectivesRemaining = max(0, m.shipCount - done)
    }

    // MARK: Ending a slot

    /// Fail an active mission now (a scan, a boarding, the player disabled,
    /// a lost mission ship, the deadline): OnFailure runs and the mission is
    /// marked failed, and it stays listed until the player lands at its return
    /// stellar (0x00440bf0). Quirk: the original reuses the CanAbort latch as
    /// the gate for releasing the mission's ships, and that release also
    /// clears the slot — so an abortable mission is dropped on the spot (its
    /// cargo with it), with no landing resolution.
    public func failMission(_ missionID: Int) {
        for serial in serials(of: missionID) { quickFail(serial: serial) }
    }

    private func quickFail(serial: Int) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID),
              !player.activeMissions[i].isFailed else { return }
        Log.mission.notice("failMission: mission \(m.id) (\"\(m.name, privacy: .public)\") failed")
        runScript(m.onFailure, m, "OnFailure")
        if let i = slotIndex(serial: serial) { player.activeMissions[i].failed = true }
        player.failedMissions.insert(m.id)
        if m.canAbort { clearSlotAssignments(serial: serial, missionID: m.id) }
        offerState.listStellar = nil
        services?.notify(.missionFailed(missionID: m.id, name: m.name))
    }

    /// `Mission_ClearMisnSlotAssignments` 0x00440aa0 without its OnAbort arm:
    /// release the mission's ships and clear the slot (its cargo goes too).
    private func clearSlotAssignments(serial: Int, missionID: Int) {
        services?.releaseMissionShips(missionID: missionID)
        guard let j = slotIndex(serial: serial) else { return }
        let am = player.activeMissions.remove(at: j)
        releaseCargo(am)
    }

    /// Final failure at the return stellar (0x00440930): OnFailure runs again,
    /// the CompGovt's systems lose half the CompReward, and FailText shows —
    /// with its mission wildcards reading `[Error]`, as the slot is gone.
    private func resolveFailure(serial: Int) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) else { return }
        runScript(m.onFailure, m, "OnFailure")
        if (128...383).contains(m.compRewardGovt), m.compLegalReward != 0 {
            player.applyMissionFailureReputation(govt: m.compRewardGovt, delta: m.compLegalReward, game: game)
        }
        services?.releaseMissionShips(missionID: m.id)
        guard let j = slotIndex(serial: serial) else { return }
        let am = player.activeMissions.remove(at: j)
        releaseCargo(am)
        let text = MissionText.resolve(game.descText(m.failureText, context: textContext),
                                       fields: nil, player: player, game: game)
        if m.failureText >= 128, !text.isEmpty { services?.showStoryText(text, title: m.displayName) }
    }

    /// Success at the return stellar (0x00440410): CompText, OnSuccess,
    /// DatePostInc days, the CompGovt walk and PayVal.
    private func resolveSuccess(serial: Int) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) else { return }
        Log.mission.notice("completeMission: mission \(m.id) (\"\(m.name, privacy: .public)\") completed, pay=\(m.pay)")
        let am = player.activeMissions[i]
        let text = resolveMissionText(game.descText(m.completionText, context: textContext), for: m, active: am)
        let title = resolveMissionText(m.displayName, for: m, active: am)
        if m.completionText >= 128, !text.isEmpty { services?.showStoryText(text, title: title) }
        player.activeMissions.remove(at: i)
        releaseCargo(am)
        player.completedMissions.insert(m.id)
        runScript(m.onSuccess, m, "OnSuccess")
        if m.datePostIncrement > 0 { advanceDays(m.datePostIncrement) }
        if (128...383).contains(m.compRewardGovt), m.compLegalReward != 0 {
            player.applyMissionSuccessReputation(govt: m.compRewardGovt, delta: m.compLegalReward, game: game)
        }
        applyPayVal(m.pay)
        offerState.listStellar = nil
        services?.notify(.missionCompleted(missionID: m.id, name: m.name))
    }

    /// Complete an active mission as if the player had landed at its return
    /// stellar with everything done.
    public func completeMission(_ missionID: Int) {
        guard let serial = serials(of: missionID).first else {
            Log.mission.error("completeMission: mission \(missionID) not active; ignoring")
            return
        }
        resolveSuccess(serial: serial)
    }

    /// An auto-abort (Flags 0x0001) mission's objective is done (0x00447d90):
    /// OnAbort, DatePostInc days, Flags 0x0008 drains a jump of fuel and Flags2
    /// 0x0002 pays PayVal. The original applies no CompGovt reward here.
    private func resolveAutoAbort(serial: Int) {
        guard let i = slotIndex(serial: serial), let m = game.mission(player.activeMissions[i].missionID) else { return }
        runScript(m.onAbort, m, "OnAbort")
        if m.datePostIncrement > 0 { advanceDays(m.datePostIncrement) }
        if m.flags1 & 0x0008 != 0 { player.fuel = currentFuel() - 100 }
        if m.flags2 & 0x0002 != 0 { applyPayVal(m.pay) }
        services?.releaseMissionShips(missionID: m.id)
        guard let j = slotIndex(serial: serial) else { return }
        let am = player.activeMissions.remove(at: j)
        releaseCargo(am)
        player.completedMissions.insert(m.id)
        offerState.listStellar = nil
    }

    /// Abort `missionID`. A player abort (`manual`) honours CanAbort and costs
    /// Flags 0x0040 missions 5 × CompReward with the CompGovt; a script `A`
    /// does neither. Both release the mission and run OnAbort.
    public func abortMission(_ missionID: Int, silent: Bool = false, manual: Bool = true) {
        let slots = serials(of: missionID)
        guard !slots.isEmpty, let m = game.mission(missionID) else {
            Log.mission.debug("abortMission: mission \(missionID) not active; ignoring")
            return
        }
        for serial in (manual ? Array(slots.prefix(1)) : slots) {
            if manual {
                guard m.canAbort else { return }
                if m.flags1 & 0x0040 != 0, (128...383).contains(m.compRewardGovt) {
                    player.applyMissionAbortReputation(govt: m.compRewardGovt, delta: m.compLegalReward, game: game)
                }
            }
            services?.releaseMissionShips(missionID: m.id)
            runScript(m.onAbort, m, "OnAbort")
            if let i = slotIndex(serial: serial) {
                let am = player.activeMissions.remove(at: i)
                releaseCargo(am)
            }
            offerState.listStellar = nil
        }
        Log.mission.notice("abortMission: mission \(missionID) (\"\(m.name, privacy: .public)\") aborted (silent=\(silent))")
        if !silent { services?.notify(.missionAborted(missionID: missionID, name: m.name)) }
    }

    // MARK: Cargo

    private func cargoRoomCheck(_ qty: Int) -> Bool {
        guard qty > 0 else { return true }
        if cargoCapacity() < qty { showMiscText(MiscString.noCargoRoom); return false }
        if freeCargoSpace() < qty { showMiscText(MiscString.noFreeCargoRoom); return false }
        return true
    }

    private func loadCargo(at i: Int) {
        let am = player.activeMissions[i]
        player.activeMissions[i].cargoPickedUp = true
        if let c = cargo(of: am) { player.cargo[c.type, default: 0] += c.qty }
    }

    private func unloadCargo(at i: Int) {
        let am = player.activeMissions[i]
        player.activeMissions[i].cargoDelivered = true
        removeCargo(am)
    }

    /// A mission ending takes its cargo with it, if still aboard.
    private func releaseCargo(_ am: ActiveMission) {
        guard am.isCarryingCargo else { return }
        removeCargo(am)
    }

    private func removeCargo(_ am: ActiveMission) {
        // Builds before the no-cargo fix loaded a phantom ton of commodity -1.
        if cargo(of: am) == nil, let type = am.resolvedCargoType, type < 0 {
            player.cargo[type] = nil
            return
        }
        guard let c = cargo(of: am) else { return }
        let left = (player.cargo[c.type] ?? 0) - c.qty
        player.cargo[c.type] = left > 0 ? left : nil
    }

    /// The commodity and tonnage a slot moves; nil when it carries none.
    /// Slots from older saves fall back to the static mïsn fields.
    private func cargo(of am: ActiveMission) -> (type: Int, qty: Int)? {
        let m = game.mission(am.missionID)
        let type = am.resolvedCargoType ?? m?.cargoType ?? -1
        let qty = am.resolvedCargoQty ?? m.map { abs($0.cargoQty) } ?? 0
        guard type >= 0, qty > 0 else { return nil }
        return (type, qty)
    }

    /// What the Player Info jettison threw out (`Player_RedistributeFleetCargoOverflow`
    /// 0x0041f330 with its jettison-all flag, UI-13).
    public struct Jettison: Sendable, Equatable {
        /// Tons thrown out, mission cargo included (the player ship's pods).
        public var total = 0
        /// Tons before the mission cargo was added (the escorts' pod share).
        public var ordinaryTotal = 0
        /// A jettisoned mission showed "Mission failed." instead of the
        /// jettison line.
        public var missionFailedShown = false
    }

    /// Jettison the hold: every commodity and junk ton goes, and so does the
    /// cargo of each abortable mission carrying some — counted even at zero
    /// tons — which then fails (the quick-fail, which for an abortable
    /// mission also drops it). Unless a mission's Flags hold 0x0400, its
    /// failure shows STR# 2002 #284 (`docked` suppresses it, as the original
    /// does while the landing visit owns the world). A non-abortable mission's
    /// cargo stays aboard.
    public func jettisonCargo(docked: Bool) -> Jettison {
        var result = Jettison()
        let missionTons = carriedMissionCargo()
        for (type, held) in player.cargo {
            let ordinary = held - min(held, missionTons[type] ?? 0)
            guard ordinary > 0 else { continue }
            result.total += ordinary
            let left = held - ordinary
            player.cargo[type] = left > 0 ? left : nil
        }
        result.ordinaryTotal = result.total
        for am in player.activeMissions where am.isCarryingCargo {
            guard let m = game.mission(am.missionID), m.canAbort else { continue }
            let type = am.resolvedCargoType ?? m.cargoType
            guard type >= 0 else { continue }
            result.total += cargo(of: am)?.qty ?? 0
            if m.flags1 & 0x0400 == 0, !docked {
                showMiscOverlay(MiscString.missionShipLost)
                result.missionFailedShown = true
            }
            if let serial = am.serial { quickFail(serial: serial) }
            if result.total == 0 { result.total = 1 }
        }
        return result
    }

    /// Tons of each cargo type the active missions have aboard. The original
    /// keeps mission cargo in the mission slots, apart from the hold's
    /// commodity bins and junk; NovaSwift merges it into `player.cargo`, so
    /// fleet-wide hold operations (EC-21, UI-13) subtract this first.
    public func carriedMissionCargo() -> [Int: Int] {
        PilotEconomy.missionCargo(player, game: game)
    }

    private func currentFuel() -> Double {
        if let f = player.fuel { return f }
        return PilotEconomy.loadout(player, galaxy: Galaxy(game: game))?.maxFuel ?? 0
    }

    // MARK: PayVal (0x00440750)

    /// Apply a mïsn PayVal on success (or Flags2 0x0002 auto-abort): ≥ 1 pays
    /// credits; -10128-g / -20128-g / -30128-g set *negative* standing to 0
    /// with government g / its allies / its class-mates; -40001…-40099 takes
    /// that percent of the player's credits; everything else does nothing —
    /// the acceptance fee (below -50000) was charged at accept (MS-09).
    func applyPayVal(_ code: Int) {
        switch code {
        case 1...:
            setCredits(player.credits + code)
        case -19999 ... -10000:
            let g = -10000 - code
            player.cleanLegalRecord(.government(g), game: game)
        case -29999 ... -20000:
            let g = -20000 - code
            player.cleanLegalRecord(.alliesOf(g), game: game)
        case -39999 ... -30000:
            let g = -30000 - code
            player.cleanLegalRecord(.classmatesOf(g), game: game)
        case -40099 ... -40001:
            let pct = Double(-40000 - code)
            setCredits(Int(Double(player.credits) - Double(player.credits) * pct * 0.01))
        default:
            break
        }
    }

    private func setCredits(_ value: Int) {
        let delta = value - player.credits
        guard delta != 0 else { return }
        player.credits = value
        services?.notify(.creditsChanged(delta: delta, total: player.credits))
    }

    // MARK: Scripts and text

    /// Run one of a mission's SET strings with that mission as the `Q`
    /// wildcard context.
    func runScript(_ expr: String, _ m: MissionRes, _ field: String) {
        guard !expr.isEmpty else { return }
        let outer = scriptMission
        scriptMission = m
        apply(set: expr, source: ncbSource("mïsn", m.id, m.name, field))
        scriptMission = outer
    }

    /// Resolve and show one of a mission's dësc texts (ShipDone, LoadCargo,
    /// DropCargo…); ids below 128 and empty bodies show nothing.
    func showMissionText(_ descID: Int, for m: MissionRes, active: ActiveMission? = nil) {
        guard descID >= 128 else { return }
        let text = resolveMissionText(game.descText(descID, context: textContext), for: m, active: active)
        if !text.isEmpty { services?.showStoryText(text, title: resolveMissionText(m.displayName, for: m, active: active)) }
    }

    private func showMiscText(_ index: Int) {
        if let s = stringListEntry(MiscString.list, index: index), !s.isEmpty {
            services?.showStoryText(s, title: "")
        }
    }

    private func showMiscOverlay(_ index: Int) {
        if let s = stringListEntry(MiscString.list, index: index), !s.isEmpty {
            services?.showOverlayMessage(s)
        }
    }

    /// Expand a mission dësc's `<…>` wildcards. With an accepted slot (given,
    /// or the mission's first) the slot's own targets are used; otherwise the
    /// offer's.
    func resolveMissionText(_ text: String, for m: MissionRes, active: ActiveMission? = nil) -> String {
        guard text.contains("<") else { return text }
        let fields: MissionText.Fields
        if let am = active ?? player.activeMission(m.id) {
            var name: String?
            if let entry = am.shipNameEntry { name = game.stringList(m.shipNameStrID)?.string(at: entry) }
            fields = .init(travelSpob: am.travelSpobID, returnSpob: returnStellar(of: am, m),
                           cargoType: am.resolvedCargoType ?? m.cargoType,
                           cargoQty: am.resolvedCargoQty ?? max(0, m.cargoQty),
                           pay: m.pay, deadline: am.deadline, specialShipName: name ?? "", accepted: true)
        } else {
            let t = offerTargets(for: m)
            fields = .init(travelSpob: t.travelSpob, returnSpob: t.returnSpob, cargoType: t.cargoType,
                           cargoQty: t.cargoQty, pay: m.pay, deadline: t.deadline,
                           specialShipName: nil, accepted: false)
        }
        return MissionText.resolve(text, fields: fields, player: player, game: game)
    }
}
