import Foundation
import NovaSwiftKit

// MARK: - Mission special and auxiliary ships: where and what they fly
//
// What `Mission_PopulateMissionSlotFromDef` 0x0043f8c0 fixes at accept — the
// special ships' system (ShipSyst through 0x0043e6f0), the one hull every
// special ship flies under mïsn Flags 0x0800, and the rolled ShipName and
// ShipSubtitle entries — and the two tests the spawn tick 0x0041d6e0 makes
// against the system the player is in: the resolved ShipSyst for special
// ships, and the AuxShipSyst code table (0x00447a30) for auxiliary ships.

extension StoryEngine {

    /// The resolved ShipSyst meaning "wherever the player is" (−6).
    public static let followPlayerSystem = -6

    // MARK: Accept-time resolution (0x0043f8c0)

    /// Fill in the special-ship fields of a just-activated slot: the
    /// resolved ShipSyst, the hull lock (Flags 0x0800) and the ShipName /
    /// ShipSubtitle entries. Every roll draws the story generator.
    func populateMissionShips(_ am: inout ActiveMission, _ m: MissionRes) {
        if m.flags1 & 0x0800 != 0, m.shipDude >= 128 {
            am.lockedShipType = selectMissionHull(dudeID: m.shipDude, ignoreAvailability: false)
                ?? selectMissionHull(dudeID: m.shipDude, ignoreAvailability: true)
        }
        am.shipSystemID = resolveShipSystem(m.shipSystem, travel: am.travelSpobID, return: am.returnSpobID,
                                            missionID: m.id, shipCount: m.shipCount)
        if m.shipNameStrID >= 128, let n = game.stringList(m.shipNameStrID)?.strings.count, n > 0 {
            am.shipNameEntry = random(n) + 1
        }
        if m.shipSubtitleStrID >= 128, let n = game.stringList(m.shipSubtitleStrID)?.strings.count, n > 0 {
            am.shipSubtitleEntry = random(n) + 1
        }
    }

    /// `Dude_SelectShipTypeIndexFromDudeDef` 0x0046b4b0: a weighted pick among
    /// the dude's hulls whose AppearOn passes (or all of them when
    /// `ignoreAvailability`): `Rand(total)`, and the first entry whose running
    /// total reaches the roll + 1. nil when no hull qualifies.
    public func selectMissionHull(dudeID: Int, ignoreAvailability: Bool) -> Int? {
        guard let dude = game.dude(dudeID) else { return nil }
        let entries = dude.ships.filter { ignoreAvailability || hullAvailable($0.shipID) }
        let total = entries.reduce(0) { $0 + $1.prob }
        guard total > 0 else { return nil }
        let roll = random(total)
        var acc = 0
        for e in entries {
            acc += e.prob
            if roll + 1 <= acc { return e.shipID }
        }
        return nil
    }

    /// A hull's availability flag (shïp +0xa41): its AppearOn test passes.
    func hullAvailable(_ shipID: Int) -> Bool {
        guard let s = game.ship(shipID) else { return false }
        return s.appearOn.isEmpty || NCBTest(s.appearOn).evaluate(player)
    }

    /// The special ships' system, resolved once at accept from the mïsn's
    /// ShipSyst (0x0043f8c0 → 0x0043e6f0): −1 the current system, −2 a random
    /// other system, −3 the travel stellar's system (else the return
    /// stellar's), −4 the return stellar's, −5 one random neighbour of the
    /// current system, −6 follow the player, 128… that system, and the
    /// government families from 9999. nil when nothing qualifies (no ships).
    func resolveShipSystem(_ code: Int, travel: Int?, return ret: Int?, missionID: Int,
                           shipCount: Int) -> Int? {
        let here = player.currentSystem
        switch code {
        case -1: return here
        case -2: return randomShipSystem { _ in true }
        case -3:
            if let s = travel.flatMap(geography.stellarSystem) ?? ret.flatMap(geography.stellarSystem) { return s }
            Log.mission.notice("mission \(missionID) failed to find a suitable system for special ships (TravelStel doesn't exist!)")
            return nil
        case -4:
            if let s = ret.flatMap(geography.stellarSystem) { return s }
            Log.mission.notice("mission \(missionID) failed to find a suitable system for special ships (ReturnStel doesn't exist!)")
            return nil
        case -6: return Self.followPlayerSystem
        case -5:
            // A random link of the current system that resolves to a visible
            // system. The original spins forever on a system without one;
            // this gives up after a bounded number of rolls.
            let links = geography.systems[here]?.links ?? []
            guard !links.isEmpty else { return nil }
            for _ in 0..<4096 {
                let link = links[random(links.count)]
                guard let v = visibleTwin(link), isSystemVisible(v) else { continue }
                return v
            }
            return nil
        case 128..<(128 + 0x800):
            return code
        case 9999...31999:
            return randomGovtShipSystem(code)
        default:
            if shipCount > 0 {
                Log.mission.notice("mission \(missionID) contained invalid special ship system reference")
            }
            return nil
        }
    }

    /// A random visible system in a different twin group from the current
    /// one, among those passing `accepts` (0x0043e6f0's precheck-and-roll).
    private func randomShipSystem(_ accepts: (MissionGeography.System) -> Bool) -> Int? {
        let geo = geography
        let hereRoot = geo.root(player.currentSystem)
        let candidates = geo.systems.keys.sorted().filter { id in
            guard let s = geo.systems[id], isSystemVisible(id), geo.root(id) != hereRoot else { return false }
            return accepts(s)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates[random(candidates.count)]
    }

    /// The ShipSyst government families (0x0043e6f0). The government is the
    /// code's 0-based index (9999 is independent, −1).
    private func randomGovtShipSystem(_ code: Int) -> Int? {
        let geo = geography
        func g(_ base: Int) -> Int { code - base + 128 }
        switch code {
        case 9999...14999:
            let want = code == 9999 ? -1 : g(10000)
            return randomShipSystem { $0.govt == want }
        case 15000...19999:
            // The precheck counts the government's own systems too; the roll
            // does not. Here the candidates are the roll's.
            let want = g(15000)
            return randomShipSystem { $0.govt >= 0 && $0.govt != want && geo.allied($0.govt, want) }
        case 20000...24999:
            let want = g(20000)
            return randomShipSystem { $0.govt != want }
        case 25000...29999:
            let want = g(25000)
            return randomShipSystem { geo.hostileOrXenophobic($0.govt, want) }
        case 30000...30999:
            let want = g(30000)
            return randomShipSystem { geo.shareClass($0.govt, want) }
        case 31000...31999:
            let want = g(31000)
            return randomShipSystem { !geo.shareClass($0.govt, want) }
        default:
            return nil
        }
    }

    /// `System_ResolveVisibleSystemForTravel`: the system itself when it is
    /// visible, else the visible member of its twin group.
    func visibleTwin(_ system: Int) -> Int? {
        if isSystemVisible(system) { return system }
        let geo = geography
        let group = geo.twinGroups[geo.root(system) ?? system] ?? [system]
        return group.first(where: isSystemVisible)
    }

    /// Slots from a save made before ShipSyst was resolved at accept get it
    /// now, measured from the system they were accepted in.
    public func resolveLegacyMissionShipSystems() {
        for i in player.activeMissions.indices where player.activeMissions[i].shipSystemID == nil
            && !(player.activeMissions[i].shipSystemResolved ?? false) {
            guard let m = game.mission(player.activeMissions[i].missionID) else { continue }
            let saved = player.currentSystem
            if let anchor = player.activeMissions[i].acceptSystemID { player.currentSystem = anchor }
            let am = player.activeMissions[i]
            let resolved = resolveShipSystem(m.shipSystem, travel: am.travelSpobID, return: am.returnSpobID,
                                             missionID: m.id, shipCount: m.shipCount)
            player.currentSystem = saved
            player.activeMissions[i].shipSystemID = resolved
            player.activeMissions[i].shipSystemResolved = true
        }
    }

    // MARK: Spawn-time tests (0x0041d6e0)

    /// Whether a slot's special ships belong in `current`: its resolved
    /// ShipSyst is −6, or that system's visible twin is `current`.
    public func shipSystemMatches(_ am: ActiveMission, currentSystem current: Int) -> Bool {
        guard let sys = am.shipSystemID else { return false }
        if sys == Self.followPlayerSystem { return true }
        return visibleTwin(sys) == current
    }

    /// `Mission_DoesSystemMatchMissionLocator` 0x00447a30: the AuxShipSyst
    /// code, tested live against `current` — −1/−6 any system, −2 the travel
    /// stellar's system, −3 the return stellar's, 128… that system or its
    /// visible twin, 5000… that system or one of its links, and the
    /// government families from 9999 (0-based government index).
    public func auxSystemMatches(_ am: ActiveMission, _ m: MissionRes, currentSystem s: Int) -> Bool {
        let code = m.auxShipSystem
        let geo = geography
        let sysGovt = geo.systems[s]?.govt ?? -1
        func g(_ base: Int) -> Int { code - base + 128 }
        switch code {
        case -1, -6:
            return true
        case -2:
            return am.travelSpobID.flatMap(geo.stellarSystem) == s
        case -3:
            return returnStellar(of: am, m).flatMap(geo.stellarSystem) == s
        case 128..<(128 + 0x800):
            return s == code || visibleTwin(code) == s
        case 5000...9998:
            let center = code - 5000 + 128
            return s == center || (geo.systems[center]?.links.contains(s) ?? false)
        case 9999...14999:
            return sysGovt == (code == 9999 ? -1 : g(10000))
        case 15000...19999:
            return sysGovt >= 0 && (sysGovt == g(15000) || geo.allied(sysGovt, g(15000)))
        case 20000...24999:
            return sysGovt != g(20000)
        case 25000...29999:
            guard sysGovt >= 0 else { return false }
            let want = g(25000)
            if geo.govts[want]?.xenophobic == true, want != sysGovt, !geo.allied(sysGovt, want) { return true }
            return geo.hostileOrXenophobic(sysGovt, want)
        case 30000...30999:
            return sysGovt >= 0 && geo.shareClass(sysGovt, g(30000))
        case 31000...31999:
            return sysGovt >= 0 && !geo.shareClass(sysGovt, g(31000))
        default:
            return false
        }
    }

    // MARK: Names

    /// The name a slot's special ships carry: the ShipName STR# entry rolled
    /// at accept (the same one `<SN>` reads). Empty when none.
    public func missionShipName(_ am: ActiveMission, _ m: MissionRes) -> String {
        guard m.shipNameStrID >= 128, let entry = am.shipNameEntry else { return "" }
        return game.stringList(m.shipNameStrID)?.string(at: entry) ?? ""
    }

    /// The subtitle a slot's special ships carry: the ShipSubtitle STR#
    /// entry rolled at accept. Empty when none.
    public func missionShipSubtitle(_ am: ActiveMission, _ m: MissionRes) -> String {
        guard m.shipSubtitleStrID >= 128, let entry = am.shipSubtitleEntry else { return "" }
        return game.stringList(m.shipSubtitleStrID)?.string(at: entry) ?? ""
    }
}

extension MissionGeography {
    /// The system a stellar sits in.
    func stellarSystem(_ spob: Int) -> Int? { stellars[spob]?.system }
}
