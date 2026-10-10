import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// How a lane offer (bar, main spaceport, trade centre, shipyard, outfitter)
/// ended, which decides whether it comes up again this visit (0x00448670).
public enum MissionOfferOutcome: Sendable {
    /// Accepted or refused: out of the lane until it is rebuilt.
    case closed
    /// Accepted, but activation failed (no cargo room, no free slot): offered
    /// again only after the offer context changes away from the main spaceport.
    case activationFailed
}

// MARK: - Mission offers: rolls, targets, eligibility, the offer lane

extension StoryEngine {

    var geography: MissionGeography { MissionGeography.of(game) }

    var offerState: MissionOfferState {
        get { player.missionOffers ?? MissionOfferState() }
        set { player.missionOffers = newValue }
    }

    // MARK: Rolls and the offer lists

    /// Draw fresh AvailRandom rolls and forget the resolved targets — the
    /// original does this on every system arrival and at game start (inside
    /// 0x00458802), and on landing somewhere new.
    public func rerollMissionOffers() {
        var o = offerState
        o.rollSeed = UInt64(random(1 << 30)) << 30 | UInt64(random(1 << 30))
        o.zeroedRolls = []
        o.targets = [:]
        offerState = o
        locatorCandidateMemo = [:]
    }

    /// A mission's AvailRandom roll for this arrival: 1…100, or 0 once the
    /// mission has been accepted (a 0 always passes the gate).
    func offerRoll(_ missionID: Int) -> Int {
        let o = offerState
        if o.zeroedRolls.contains(missionID) { return 0 }
        var r = StoryRNG(seed: o.rollSeed ^ (UInt64(missionID) &* 0xD1B5_4A32_D192_ED03))
        return r.int(100) + 1
    }

    /// Landing at a stellar other than the one the lists were last built for
    /// rerolls them and rebuilds the offer lists (0x00457580). Landing also
    /// resets the lane-offer context (0x00443780).
    func refreshOffersOnLanding(at spobID: Int) {
        offerState.context = nil
        if offerState.listStellar != spobID {
            rerollMissionOffers()
            offerState.removed = []
            offerState.listStellar = spobID
            buildOfferLists(atSpob: spobID)
        }
    }

    /// `Mission_EvaluateMissionLists` 0x0043cf00: list 0 (mission computer)
    /// and list 1 (every other spaceport location) from the missions eligible
    /// now and not active, each sorted by DispWeight, highest first (ties in
    /// id order); their targets are resolved here.
    func buildOfferLists(atSpob spobID: Int?) {
        let lanes: [MissionOfferLocation] = [.bar, .mainSpaceport, .tradeCenter, .shipyard, .outfitter]
        var computer: [MissionRes] = [], lane: [MissionRes] = []
        for m in game.missions() {
            if m.availLocation == .missionComputer {
                if isEligible(m, at: .missionComputer, spobID: spobID) { computer.append(m) }
            } else if lanes.contains(m.availLocation), isEligible(m, at: m.availLocation, spobID: spobID) {
                lane.append(m)
            }
        }
        func order(_ a: MissionRes, _ b: MissionRes) -> Bool {
            a.displayWeight != b.displayWeight ? a.displayWeight > b.displayWeight : a.id < b.id
        }
        computer.sort(by: order)
        lane.sort(by: order)
        for m in computer + lane { _ = offerTargets(for: m) }
        var o = offerState
        o.computerList = computer.map(\.id)
        o.laneList = lane.map(\.id)
        offerState = o
    }

    /// After an accept while landed (the tail of 0x0043f100): the accepted
    /// mission and every listed one that is no longer eligible leave both
    /// lists. Nothing is ever added.
    func compactOfferLists(accepted missionID: Int) {
        var o = offerState
        let spob = player.landedSpob
        func keep(_ id: Int) -> Bool {
            guard id != missionID, let m = game.mission(id) else { return false }
            let ok = isEligible(m, at: m.availLocation, spobID: spob)
            if !ok { Log.mission.debug("suppressing previously available mission \(id)") }
            return ok
        }
        o.computerList = o.computerList?.filter(keep)
        o.laneList = o.laneList?.filter(keep)
        offerState = o
    }

    /// The stellar random destinations are measured from: the one the player
    /// is docked at, or in flight the current system's first stellar.
    func anchorStellar() -> Int? {
        if let landed = player.landedSpob { return landed }
        return geography.systems[player.currentSystem]?.spobs.first
    }

    // MARK: Targets (0x0043d240)

    /// The targets a mission offered here would get, resolved once and kept
    /// until the next arrival or rebuild, so the offer, the list and the
    /// accepted mission agree.
    public func offerTargets(for m: MissionRes) -> MissionTargets {
        if let t = offerState.targets[m.id] { return t }
        let t = resolveTargets(for: m)
        offerState.targets[m.id] = t
        return t
    }

    /// Resolve a mission's travel and return stellars, cargo and deadline.
    /// ReturnStel -1 means the travel stellar (MS-08); a random locator with
    /// no candidate falls back to the anchor (the offering stellar, OQ D3).
    func resolveTargets(for m: MissionRes) -> MissionTargets {
        let reference = anchorStellar()
        let travel = m.travelStellar == -1 ? nil
            : selectStellar(locator: m.travelStellar, reference: reference, excluded: nil)
        let ret = m.returnStellar == -1 ? travel
            : selectStellar(locator: m.returnStellar, reference: reference, excluded: travel)
        let type: Int
        switch m.cargoType {
        case 0..<1000: type = m.cargoType
        case 1000:     type = random(6)
        default:       type = -1
        }
        return MissionTargets(travelSpob: travel, returnSpob: ret, cargoType: type,
                              cargoQty: specialCount(m.cargoQty),
                              deadline: m.timeLimit > 0 ? player.date.adding(days: m.timeLimit) : nil)
    }

    /// 0x0043d4c0: a count of N ≥ 0 is N; -1 is 0; -N is `ceil(N/2) + rand(N)`
    /// (MS-19).
    func specialCount(_ encoded: Int) -> Int {
        if encoded >= 0 { return encoded }
        if encoded == -1 { return 0 }
        let n = -encoded
        return (n + 1) / 2 + random(n)
    }

    /// 0x0043d510: a concrete stellar for a TravelStel/ReturnStel locator.
    func selectStellar(locator: Int, reference: Int?, excluded: Int?) -> Int? {
        if locator == -1 || locator == -4 { return reference }
        if (1..<128).contains(locator) { return reference }
        if (128..<(128 + 0x800)).contains(locator) {
            return locator != excluded ? locator : reference
        }
        let hidden = hiddenSystemIDs()
        let candidates = geography.stellarIDs.filter {
            locatorAccepts(locator, candidate: $0, reference: reference, excluded: excluded, hidden: hidden)
        }
        guard !candidates.isEmpty else { return reference }
        return candidates[random(candidates.count)]
    }

    /// Whether any stellar satisfies a random locator at all (no reference) —
    /// the sanity gate that keeps a mission with nowhere to go off the boards.
    func locatorHasCandidate(_ locator: Int) -> Bool {
        if (128..<(128 + 0x800)).contains(locator) { return true }
        guard locator == -2 || locator == -3 || locator > 0 else { return true }
        if let hit = locatorCandidateMemo[locator] { return hit }
        let hidden = hiddenSystemIDs()
        let found = geography.stellarIDs.contains {
            locatorAccepts(locator, candidate: $0, reference: nil, excluded: nil, hidden: hidden)
        }
        locatorCandidateMemo[locator] = found
        return found
    }

    /// One stellar against one locator family.
    private func locatorAccepts(_ locator: Int, candidate: Int, reference: Int?, excluded: Int?,
                                hidden: Set<Int>) -> Bool {
        let geo = geography
        guard candidate != reference, candidate != excluded,
              let s = geo.stellars[candidate], let sys = s.system, !hidden.contains(sys),
              geo.usableForTravel(s, destroyed: player.isStellarDestroyed(candidate)),
              geo.validRandomDestination(candidate, reference: reference) else { return false }
        let station: UInt32 = 0x10, uninhabited: UInt32 = 0x20
        let govt = s.govt
        switch locator {
        case -2:
            return s.flags & (station | uninhabited) == 0
        case -3:
            return s.flags & uninhabited != 0 && s.flags & station == 0
        case 10000..<15000:
            let wanted = locator - 10000 + 128
            guard govt == wanted else { return false }
            return s.flags & uninhabited == 0 || (geo.govts[wanted].map { $0.flags1 & 0x0800 != 0 } ?? false)
        case 15000..<20000:
            let wanted = locator - 15000 + 128
            guard govt != -1, govt != wanted, s.flags & uninhabited == 0 else { return false }
            // Original quirk: the test also reads the *system* table at the
            // stellar's own index, so a stellar passes when the system that
            // shares its id is governed by `wanted`.
            return geo.systems[candidate]?.govt == wanted || geo.allied(govt, wanted)
        case 20000..<25000:
            return s.flags & uninhabited == 0 && govt != locator - 20000 + 128
        case 25000..<30000:
            return s.flags & uninhabited == 0 && govt != -1 && geo.hostileOrXenophobic(govt, locator - 25000 + 128)
        case 30000..<31000:
            let wanted = locator - 30000 + 128
            return s.flags & uninhabited == 0 && govt != -1 && govt != wanted && geo.shareClass(govt, wanted)
        case 31000..<32000:
            let wanted = locator - 31000 + 128
            return s.flags & uninhabited == 0 && govt != -1 && govt != wanted && !geo.shareClass(govt, wanted)
        default:
            return false
        }
    }

    // MARK: Reputation seam (EC-02)

    /// The player's reputation in the current system — what AvailRecord tests.
    /// The original keeps one reputation per system (EC-02).
    func currentSystemReputation() -> Int { player.reputationHere }

    // MARK: Eligibility (0x00441b40)

    /// True if `mission` can be offered at `location` right now: the original's
    /// offering gates in their order, ending with "not already active".
    /// Completed missions are offered again — repeatability is the AvailBits'
    /// job alone (MS-04). `spobID` is the stellar being offered at (nil in
    /// flight).
    public func isEligible(_ mission: MissionRes, at location: MissionOfferLocation,
                           spobID: Int?) -> Bool {
        let m = mission
        if m.availStellar < -31999 || m.availRandom < 1 || m.availLocation == .unknown { return false }
        if m.availLocation != location { return false }
        let interaction = location == .persShip

        // Gate 0: AvailStel against the stellar being offered at.
        if m.availStellar != -1, !interaction {
            guard availStellarMatches(m.availStellar, spobID: spobID) else { return false }
        }
        // Gate 1: AvailBits.
        if !evaluate(test: m.availBits) { return false }
        // Gate 2: AvailRecord against the current system's reputation (MS-17).
        if m.availRecord != 0, !availRecordMatches(m.availRecord) { return false }
        // Gate 3: combat rating.
        if m.availRating >= 1, m.availRating > player.combatRating { return false }
        // Gate 4: this arrival's AvailRandom roll.
        if m.availRandom < 100, offerRoll(m.id) > m.availRandom { return false }
        // Gate 5: cargo room. Lists hide a mission only with Flags2 0x0001;
        // a ship offer always needs room (MS-12).
        if interaction ? m.cargoQty >= 1 : m.requiresCargoSpace {
            if freeCargoSpace() < m.cargoQty { return false }
        }
        // Gate 6: Require against the pooled Contribute bits.
        if m.require != 0, (activeContributeBits() & m.require) != m.require { return false }
        // Gate 7: AvailShipType (MS-24).
        if !shipTypeMatches(m.availShipType) { return false }
        // Gate 8: Flags 0x2000 / 0x4000 test the player hull's InherentAI.
        let ai = game.ship(player.shipType)?.inherentAI ?? 0
        if m.flags1 & 0x2000 != 0, ai < 3 { return false }
        if m.flags1 & 0x4000 != 0, ai > 2 { return false }
        // Gate 9: an acceptance fee the player can't pay hides the offer.
        if m.pay < -50000, player.credits < -50000 - m.pay { return false }
        // A random destination with nowhere to go is never offered.
        if !locatorHasCandidate(m.travelStellar) || !locatorHasCandidate(m.returnStellar) { return false }
        // Same-system denial: a fixed TravelStel/ReturnStel in the current
        // system (or its twin) is never offered, unless AvailStel is itself a
        // fixed stellar.
        if !(128..<(128 + 0x800)).contains(m.availStellar) {
            let here = geography.root(player.currentSystem)
            for locator in [m.travelStellar, m.returnStellar] where (128..<(128 + 0x800)).contains(locator) {
                if let sys = geography.stellars[locator]?.system, geography.root(sys) == here { return false }
            }
        }
        // Flags 0x0008 (drains a jump of fuel when it auto-aborts) needs that
        // jump's fuel to be offered.
        if m.flags1 & 0x0008 != 0, (player.fuel ?? Double.greatestFiniteMagnitude) < 100 { return false }
        return !player.isMissionActive(m.id)
    }

    /// AvailStel (0x00441b40 gate 0) against the stellar being offered at.
    private func availStellarMatches(_ filter: Int, spobID: Int?) -> Bool {
        let geo = geography
        let selected = spobID.flatMap { geo.stellars[$0] }
        let selectedGovt = selected?.govt ?? -1
        switch filter {
        case 128..<(128 + 0x800):
            return spobID == filter
        case 5000...9998:
            // A stellar in a system adjacent to the current one.
            return geo.systems[player.currentSystem]?.links.contains(filter - 5000) ?? false
        case 10000..<15000:
            return selectedGovt == filter - 10000 + 128
        case 15000..<20000:
            return selectedGovt != -1 && geo.allied(filter - 15000 + 128, selectedGovt)
        case 20000..<25000:
            return selectedGovt != filter - 20000 + 128
        case 25000..<30000:
            return selectedGovt != -1 && geo.hostileOrXenophobic(filter - 25000 + 128, selectedGovt)
        case 30000..<31000:
            return geo.shareClass(filter - 30000 + 128, selectedGovt)
        case 31000..<32000:
            // Original quirk: this lane subtracts 30000, so the government it
            // looks up is out of range and the class test always fails — the
            // lane passes at any governed stellar.
            return selectedGovt != -1 && !geo.shareClass(filter - 30000 + 128, selectedGovt)
        default:
            return false
        }
    }

    /// AvailRecord (OQ D4): positive needs `rep ≥ value`, negative `rep ≤
    /// value`; -32000 / -32001 mean the landed stellar / any stellar is
    /// dominated, tested only while landed (in flight they fall through to the
    /// reputation compare and in practice never pass); below that never.
    private func availRecordMatches(_ record: Int) -> Bool {
        let rep = currentSystemReputation()
        if record < -31999 {
            guard let landed = player.landedSpob else { return rep <= record }
            switch record {
            case -32000:
                return player.hasDominated(landed)
                    || ((game.spob(landed)?.flags2 ?? 0) & 0x0020 != 0)
            case -32001:
                return !(player.dominatedStellars ?? []).isEmpty
            default:
                return false
            }
        }
        return record < 1 ? rep <= record : rep >= record
    }

    /// AvailShipType (MS-24): 128…896 the player flies that hull; 1128…1896
    /// not `value - 1000`; 2128…2384 the hull's inherent government (combat or
    /// attributes) is `value - 2000`; 3128…3384 it is not `value - 3000`.
    /// Anything else passes.
    func shipTypeMatches(_ value: Int) -> Bool {
        let hull = game.ship(player.shipType)
        switch value {
        case 128...896:
            return player.shipType == value
        case 1128...1896:
            return player.shipType != value - 1000
        case 2128...2384:
            let g = value - 2000
            return hull.map { $0.inherentCombatGovt == g || $0.inherentAttributesGovt == g } ?? false
        case 3128...3384:
            let g = value - 3000
            return hull.map { $0.inherentCombatGovt != g && $0.inherentAttributesGovt != g } ?? true
        default:
            return true
        }
    }

    // MARK: Lists and offers

    /// The eligible missions at a spot, highest DispWeight first (ties in
    /// resource order) — the mission BBS list, or every lane candidate.
    public func missionsOffered(at location: MissionOfferLocation, spob spobID: Int?) -> [MissionRes] {
        let offered = game.missions()
            .filter { isEligible($0, at: location, spobID: spobID) }
            .sorted { $0.displayWeight != $1.displayWeight ? $0.displayWeight > $1.displayWeight : $0.id < $1.id }
        Log.mission.debug("missionsOffered: location=\(String(describing: location), privacy: .public) spob=\(spobID ?? -1) -> \(offered.count) mission(s)")
        return offered
    }

    /// The landing's mission-computer list (list 0): fixed when the player
    /// landed, compacted only by accepts.
    public func missionComputerList(spob spobID: Int?) -> [MissionRes] {
        if offerState.computerList == nil { buildOfferLists(atSpob: spobID) }
        return (offerState.computerList ?? []).compactMap { game.mission($0) }
    }

    /// The next lane offer at `location` (0x00448670): the first mission of
    /// the landing's list 1 with this AvailLoc that is not marked shown and is
    /// still eligible now. Switching to any context other than the main
    /// spaceport (3) re-arms the activation-failed ones. The bar calls this
    /// on its timer, the main spaceport once per landing, the shops when
    /// opened and then on their idle timer.
    public func nextLaneOffer(at location: MissionOfferLocation, spob spobID: Int) -> MissionRes? {
        var o = offerState
        if o.context != location.rawValue {
            if location != .mainSpaceport { o.shown = [] }
            o.context = location.rawValue
            offerState = o
        }
        if offerState.laneList == nil { buildOfferLists(atSpob: spobID) }
        for id in offerState.laneList ?? [] {
            guard let m = game.mission(id), m.availLocation == location,
                  !offerState.shown.contains(id), !offerState.removed.contains(id) else { continue }
            if isEligible(m, at: location, spobID: spobID) { return m }
        }
        return nil
    }

    /// Leaving the spaceport window or a shop (trade centre, outfitter,
    /// shipyard) resets the lane-offer context (0x00448660), so coming back
    /// to the same screen re-offers the missions whose activation failed.
    public func clearLaneOfferContext() {
        offerState.context = nil
    }

    /// Record how a lane offer ended. `accept`/`decline` do this themselves
    /// for lane missions; exposed for callers that close an offer otherwise.
    /// A closed offer leaves list 1 (0x00448670 compacts it out).
    public func recordLaneOffer(_ missionID: Int, _ outcome: MissionOfferOutcome) {
        switch outcome {
        case .closed:
            offerState.removed.insert(missionID)
            offerState.laneList?.removeAll { $0 == missionID }
        case .activationFailed:
            offerState.shown.insert(missionID)
        }
    }


    /// Build a presentable offer (resolving briefing text + buttons) and hand it
    /// to the UI via `GameServices` (`NovaUi_RunMissionOfferWindow` 0x00442510).
    /// A can't-refuse offer whose offer text is empty opens no window: it
    /// activates at once, silently. Returns whether a window was presented.
    @discardableResult
    public func present(_ mission: MissionRes) -> Bool {
        let text = briefingText(for: mission)
        if mission.cannotBeRefused, text.isEmpty {
            Log.mission.debug("present: mission \(mission.id) has no offer text and can't be refused — activating silently")
            accept(mission.id)
            return false
        }
        let labels = offerButtonLabels(for: mission)
        let offer = MissionOffer(
            mission: mission,
            title: resolvedName(for: mission),
            briefingText: text,
            pictureID: game.desc(mission.offerTextID)?.pictureID,
            acceptButton: labels.accept, refuseButton: labels.refuse,
            canRefuse: !mission.cannotBeRefused, canAccept: canAccept(mission))
        services?.presentMissionOffer(offer)
        return true
    }

    /// The offer window's button labels (0x00442510): the mïsn's AcceptButton
    /// and RefuseButton, each kept only when its first character, lowercased,
    /// is a letter a–z. A blanked accept label reads STR# 150 #50 "Yes" — #27
    /// "Okay" when the offer can't be refused — and a blanked refuse label
    /// #51 "No".
    public func offerButtonLabels(for m: MissionRes) -> (accept: String, refuse: String) {
        func usable(_ s: String) -> Bool {
            guard let c = s.unicodeScalars.first else { return false }
            let lower = Character(c).lowercased()
            return lower.count == 1 && ("a"..."z").contains(lower)
        }
        func button(_ index: Int, _ fallback: String) -> String {
            let s = stringListEntry(150, index: index) ?? ""
            return s.isEmpty ? fallback : s
        }
        let accept = usable(m.acceptButton) ? m.acceptButton
            : (m.cannotBeRefused ? button(27, "Okay") : button(50, "Yes"))
        let refuse = usable(m.refuseButton) ? m.refuseButton : button(51, "No")
        return (accept, refuse)
    }

    /// Why the Mission BBS won't open (0x0043c470), or nil when it opens: all
    /// 16 slots taken (STR# 2002 #351 + " 16 " + #352), or nothing on list 0
    /// that is still eligible (#353).
    public func missionBBSRefusal(spob spobID: Int?) -> String? {
        if player.activeMissions.count >= PlayerState.missionSlotCount {
            let a = stringListEntry(2002, index: 0x15f) ?? ""
            let b = stringListEntry(2002, index: 0x160) ?? ""
            return a + " \(PlayerState.missionSlotCount) " + b
        }
        let any = missionComputerList(spob: spobID).contains {
            isEligible($0, at: .missionComputer, spobID: spobID)
        }
        return any ? nil : (stringListEntry(2002, index: 0x161) ?? "")
    }

    /// Whether accepting would get past activation's cargo check: the rolled
    /// tonnage must fit both the hold and its free space (0x0043f100).
    public func canAccept(_ mission: MissionRes) -> Bool {
        let qty = offerTargets(for: mission).cargoQty
        guard qty > 0 else { return true }
        return cargoCapacity() >= qty && freeCargoSpace() >= qty
    }

    /// The player ship's own capacity, cargo pods included (0x0046a730).
    func cargoCapacity() -> Int { PilotEconomy.shipCargoCapacity(player, galaxy: Galaxy(game: game)) }

    /// The room left in the player ship (0x0046a7c0): freighter escorts take
    /// the ordinary cargo first, mission cargo rides in the player ship.
    func freeCargoSpace() -> Int { PilotEconomy.remainingCargoSpace(player, galaxy: Galaxy(game: game)) }

    /// Where a mission on offer would send the player — the same stellar
    /// `<DST>` names in its briefing. Lets the Mission BBS answer "where is
    /// this?" before the player commits, which the original never could.
    public func offerDestination(for m: MissionRes) -> (spobID: Int, systemID: Int, stellar: String, system: String)? {
        let active = player.activeMission(m.id)
        guard let spobID = active?.travelSpobID ?? offerTargets(for: m).travelSpob,
              let spob = game.spob(spobID),
              let sysID = owningSystem(ofSpob: spobID), let sys = game.system(sysID)
        else { return nil }
        return (spobID, sys.id, spob.displayName, sys.displayName)
    }

    /// The system the starmap preselects when opened from an offer or the
    /// BBS (0x0043c470 key 6, 0x00442510 button 4): only for mïsn Flags
    /// 0x0100 — the travel stellar's system, else the return stellar's.
    public func offerHighlightSystem(for m: MissionRes) -> Int? {
        guard m.flags1 & 0x0100 != 0 else { return nil }
        let t = offerTargets(for: m)
        guard let spob = t.travelSpob ?? t.returnSpob else { return nil }
        return game.systemContaining(spob: spob)
    }

    /// The fully-resolved offer briefing for a mission (conditionals + `<…>`
    /// wildcards expanded).
    public func briefing(for m: MissionRes) -> String { briefingText(for: m) }

    /// The mission's player-visible **name** with its `<…>` wildcards expanded —
    /// e.g. "Ferry Passengers to <DST>" → "Ferry Passengers to New Babylon".
    public func resolvedName(for m: MissionRes) -> String {
        resolveMissionText(m.displayName, for: m)
    }

    /// The offer text (dësc 3872 + id), the pitch shown with Accept/Decline.
    func briefingText(for m: MissionRes) -> String {
        resolveMissionText(game.descText(m.offerTextID, context: textContext), for: m)
    }

    /// The post-accept briefing (mïsn `BriefText`) — empty when the mission
    /// defines none.
    public func acceptBriefing(for m: MissionRes) -> String {
        guard m.briefText >= 128 else { return "" }
        return resolveMissionText(game.descText(m.briefText, context: textContext), for: m)
    }
}
