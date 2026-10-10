import Foundation
import NovaSwiftKit

/// What an import produced, shown to the player before the pilot is created.
public struct EVNovaPilotImportSummary: Sendable {
    public var format: EVNovaPilotFile.Format
    public var pilotName: String
    public var nickname: String
    public var shipName: String
    public var hullName: String
    public var credits: Int
    public var date: GameDate
    public var location: String
    public var combatRating: Int
    public var ratingTitle: String
    public var activeMissions: Int
    public var escorts: Int
    public var controlBits: Int
    /// Content the data set doesn't contain (usually a missing plug-in), lossy
    /// repairs, and ambiguities. The import still succeeds.
    public var warnings: [String] = []
    /// Stored fields that NovaSwift has no counterpart for (not carried over).
    public var unmapped: [String] = []
}

public struct EVNovaPilotImportResult: Sendable {
    public var player: PlayerState
    public var summary: EVNovaPilotImportSummary
}

/// Turns decoded original-pilot blocks into a native `PlayerState` (the "Pilot
/// converter"). Every offset below is the Windows block layout; see
/// `docs/reverse-engineering/PILOT_IMPORT.md` for the field-by-field mapping.
public enum EVNovaPilotImporter {

    /// Read and convert a pilot file in one step.
    public static func importPilot(from url: URL, game: NovaGame) throws -> EVNovaPilotImportResult {
        let blocks = try EVNovaPilotFile.load(url: url)
        return convert(blocks, pilotName: blocks.containerName, game: game)
    }

    // MARK: Conversion

    public static func convert(_ blocks: EVNovaPilotFile.Blocks, pilotName: String?,
                               game: NovaGame) -> EVNovaPilotImportResult {
        let r = Reader(b1: blocks.block1, b2: blocks.block2, big: blocks.bigEndian)
        var warnings: [String] = []
        var unmapped: [String] = []

        // MARK: date
        var date = GameDate.defaultStart
        let month = Int(r.u16(1, 0x14)), day = Int(r.u16(1, 0x16)), year = Int(r.u16(1, 0x18))
        if (1...12).contains(month), (1...31).contains(day), year > 0 {
            date = GameDate(day: day, month: month, year: year)
        } else {
            warnings.append("The saved date (\(day)/\(month)/\(year)) is invalid; using the default start date.")
        }

        // MARK: ship, name
        let shipIdx = Int(r.u16(1, 0x02))
        var shipID = 128 + shipIdx
        if game.ship(shipID) == nil {
            warnings.append("Ship class \(shipID) is not in the loaded data (a missing plug-in?); using the first available ship.")
            shipID = game.ships().first?.id ?? 128
        }
        let hullName = game.ship(shipID)?.name ?? ""
        let nameIn = pilotName?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = nameIn.isEmpty ? "Captain" : nameIn

        var p = PlayerState(pilotName: name, isMale: r.u16(2, 0x04) == 1, shipType: shipID,
                            shipName: blocks.shipName.isEmpty ? hullName : blocks.shipName,
                            credits: 0, currentSystem: game.startingSystem()?.id ?? 128, date: date)
        p.strictPlay = r.u16(2, 0x02) == 1
        p.exploredSystems = []
        let credits = Int(Int32(bitPattern: r.u32(1, 0x281A)))
        p.credits = max(0, credits)
        p.combatRating = Int(r.u32(1, 0xE94E))

        let nick = r.text(2, 0x5D98, limit: 0x40)
        p.nickname = nick.isEmpty ? nil : nick
        p.datePrefix = r.text(2, 0x5EDE, limit: 15)
        p.dateSuffix = r.text(2, 0x5EEE, limit: 15)

        // MARK: cargo, junk, fuel
        for i in 0..<6 {
            let v = Int(r.u16(1, 0x04 + 2 * i))
            if v > 0 { p.cargo[i] = v }
        }
        var missingJunk = 0
        for i in 0..<0x80 {
            let v = Int(r.i16(2, 0x3488 + 2 * i))
            guard v > 0 else { continue }
            if game.junk(128 + i) != nil { p.cargo[128 + i] = v } else { missingJunk += 1 }
        }
        if missingJunk > 0 { warnings.append("\(missingJunk) kind(s) of junk cargo are not in the loaded data and were dropped.") }
        p.fuel = Double(r.u16(1, 0x12))
        // 0x10 (shield) is ignored by the original loader too: it reloads at full
        // shield and armor. NovaSwift does the same (nil = full).

        // MARK: outfits, weapon banks
        var missingOutfits: [Int] = []
        for i in 0..<0x200 {
            let v = Int(r.u16(1, 0x101A + 2 * i))
            guard v > 0 else { continue }
            p.outfits[128 + i] = v
            if game.outfit(128 + i) == nil { missingOutfits.append(128 + i) }
        }
        if !missingOutfits.isEmpty {
            warnings.append("\(missingOutfits.count) outfit type(s) are not in the loaded data (ids \(idList(missingOutfits))); kept in the pilot but inactive until the plug-in is enabled.")
        }
        var unresolvedWeapons: [Int] = []
        for w in 0..<0x100 {
            let weaponID = 128 + w
            let mounted = Int(r.i16(1, 0x241A + 2 * w)), ammo = Int(r.i16(1, 0x261A + 2 * w))
            if mounted > 0 {
                if let o = game.outfitInstalling(weapon: weaponID) {
                    if p.outfits[o, default: 0] < mounted { p.outfits[o] = mounted }
                } else { unresolvedWeapons.append(weaponID) }
            }
            if ammo > 0 {
                if let o = game.outfitLoadingAmmo(for: weaponID) {
                    if p.outfits[o, default: 0] < ammo { p.outfits[o] = ammo }
                } else if !unresolvedWeapons.contains(weaponID) { unresolvedWeapons.append(weaponID) }
            }
        }
        if !unresolvedWeapons.isEmpty {
            warnings.append("Weapon bank(s) \(idList(unresolvedWeapons)) have no matching outfit in the loaded data; their rounds were not carried over.")
        }

        // MARK: control bits
        for i in 0..<10000 where r.b1[0xB7BE + i] != 0 { p.setBits.insert(i) }

        // MARK: exploration, legal record
        var droppedSystems = 0
        var landed: Set<Int> = []
        for i in 0..<0x800 {
            let level = Int(r.u16(1, 0x1A + 2 * i))
            if level > 0 {
                let id = 128 + i
                guard game.system(id) != nil else { droppedSystems += 1; continue }
                p.exploredSystems.insert(id)
                if level >= 2 { landed.insert(id) }
            }
            let rep = Int(r.i16(1, 0x141A + 2 * i))
            if rep != 0, game.system(128 + i) != nil { p.systemReputation?[128 + i] = rep }
        }
        p.landedSystems = landed
        if droppedSystems > 0 { warnings.append("\(droppedSystems) explored system(s) are not in the loaded data.") }

        // MARK: position
        let jump = Int(r.u16(1, 0x00))
        let spobID = 128 + jump
        if jump != 0xFFFF, game.spob(spobID) != nil, let sys = game.systemContaining(spob: spobID) {
            p.landedSpob = spobID
            p.currentSystem = sys
        } else {
            warnings.append("The saved landing spot (stellar \(jump)) could not be placed in the loaded data; the pilot starts in space.")
            p.currentSystem = p.exploredSystems.sorted().first ?? p.currentSystem
        }
        p.exploredSystems.insert(p.currentSystem)
        let location = game.spob(spobID)?.name ?? game.system(p.currentSystem)?.displayName ?? ""

        // MARK: ranks
        var badRanks = 0
        for i in 0..<0x80 where r.u16(2, 0x5DDE + 2 * i) != 0 {
            if game.rank(128 + i) != nil { p.activeRanks.insert(128 + i) } else { badRanks += 1 }
        }
        if badRanks > 0 { warnings.append("\(badRanks) rank(s) are not in the loaded data.") }

        // MARK: cron events
        var crons: [Int: CronRuntime] = [:]
        var badCrons = 0
        for i in 0..<0x200 {
            let dur = Int(r.i16(2, 0x3590 + 2 * i)), hold = Int(r.i16(2, 0x3990 + 2 * i))
            guard dur >= 0 || hold >= 0 else { continue }
            guard game.cron(128 + i) != nil else { badCrons += 1; continue }
            var c = CronRuntime(cronID: 128 + i)
            c.active = true; c.duration = dur; c.holdoff = hold
            crons[128 + i] = c
        }
        p.cronRuntime = crons
        if badCrons > 0 { warnings.append("\(badCrons) running crön event(s) are not in the loaded data.") }

        // MARK: disasters
        var disasters: [Int: GameDate] = [:]
        var picked: [Int: Int] = [:]
        for i in 0..<0x100 {
            let left = Int(r.i16(2, 0x3088 + 2 * i))
            guard left > 0, let o = game.oops(128 + i) else { continue }
            disasters[o.id] = date.adding(days: left)
            let st = Int(r.u16(2, 0x3288 + 2 * i))
            if o.stellar == -1, st < 0x800, game.spob(128 + st) != nil { picked[o.id] = 128 + st }
        }
        p.activeDisasters = disasters
        p.disasterStellars = picked.isEmpty ? nil : picked

        // MARK: stellars (dominated, destroyed, garrisons), system cooldowns
        var dominated: Set<Int> = [], destroyed: Set<Int> = []
        var destroyedOn: [Int: Int] = [:], garrison: [Int: Int] = [:], reinf: [Int: Int] = [:]
        let now = date.julianDay
        for i in 0..<0x800 {
            let id = 128 + i
            if r.b1[0xDECE + i] != 0, game.spob(id) != nil { dominated.insert(id) }
            let regen = Int(r.i16(2, 0x4D90 + 2 * i))
            if regen >= 1, let s = game.spob(id) {
                destroyed.insert(id)
                destroyedOn[id] = now - max(0, (s.regenerationDays ?? regen) - regen)
            }
            let cool = Int(r.i16(2, 0x3D90 + 2 * i))
            if cool > 0, game.system(id) != nil { reinf[id] = cool }
        }
        for i in 0..<0x800 {
            let id = 128 + i
            guard !dominated.contains(id), let s = game.spob(id), s.defenseTotal > 0 else { continue }
            let present = Int(r.i16(2, 0x0006 + 2 * i))
            if present >= 0, present != s.defenseTotal { garrison[id] = present }
        }
        p.dominatedStellars = dominated.isEmpty ? nil : dominated
        p.destroyedStellars = destroyed.isEmpty ? nil : destroyed
        p.stellarDestroyedOnDay = destroyedOn.isEmpty ? nil : destroyedOn
        p.stellarGarrisons = garrison.isEmpty ? nil : garrison
        p.reinforcementRetriggerDays = reinf.isEmpty ? nil : reinf

        // MARK: përs
        var grudges: Set<Int> = [], defeated: Set<Int> = []
        let engine = StoryEngine(game: game, player: p)
        for i in 0..<0x400 {
            guard let pers = game.pers(128 + i) else { continue }
            if r.u16(2, 0x1806 + 2 * i) != 0 { grudges.insert(pers.id) }
            // The saved flag means "alive and available"; it is also 0 for a
            // përs whose ActiveOn doesn't hold, so only count it as a kill when
            // the përs would otherwise be active.
            if r.u16(2, 0x1006 + 2 * i) == 0, pers.activeOn.isEmpty || engine.evaluate(test: pers.activeOn) {
                defeated.insert(pers.id)
            }
        }
        p.persGrudges = grudges.isEmpty ? nil : grudges
        p.defeatedPers = defeated.isEmpty ? nil : defeated

        // MARK: escorts
        for i in 0..<0x40 {
            let raw = Int(r.i16(1, 0xE6CE + 2 * i))
            guard raw >= 0 else { continue }
            let hired = raw >= 1000
            let id = 128 + raw % 1000
            guard let hull = game.ship(id) else {
                warnings.append("Escort ship class \(id) is not in the loaded data and was dropped.")
                continue
            }
            let rec = p.registerEscort(shipType: id, name: hull.name, origin: hired ? .hired : .captured,
                                       dailyFee: hired ? hull.escortDailyFee : 0)
            if r.u16(1, 0xE7CE + 2 * i) != 0, hull.escortUpgradesTo >= 128 {
                p.setPendingEscortUpgrade(id: rec.id, to: hull.escortUpgradesTo)
            } else if !hired, r.u16(1, 0xE84E + 2 * i) != 0 {
                p.setPendingEscortSale(id: rec.id)
            }
        }

        // MARK: missions
        var slotsMissing = 0
        for slot in 0..<16 {
            let f = 0x281E + slot * 0x14, m = 0x295E + slot * 0x8E6
            guard r.b1[f] != 0 else { continue }
            let missionID = 128 + Int(r.i16(1, m + 0x4D))
            guard game.mission(missionID) != nil else { slotsMissing += 1; continue }
            func spob(_ off: Int) -> Int? {
                let v = Int(r.i16(1, m + off))
                return v >= 0 && v < 0x800 && game.spob(128 + v) != nil ? 128 + v : nil
            }
            let goal = Int(r.i16(1, m + 0x0A)), target = Int(r.i16(1, m + 0x30))
            let destroyedN = Int(r.i16(1, m + 0x26)), boardedN = Int(r.i16(1, m + 0x28))
            let disabledN = Int(r.i16(1, m + 0x2A)), sightedN = Int(r.i16(1, m + 0x2C))
            let chasedN = Int(r.i16(1, m + 0x2E))
            let complete = r.b1[f + 2] != 0
            var remaining = 0
            if goal >= 0, target > 0 {
                switch goal {
                case 0: remaining = target - destroyedN
                case 1: remaining = target - disabledN
                case 2, 5: remaining = target - boardedN
                case 6: remaining = target - chasedN - destroyedN
                default: remaining = complete ? 0 : target
                }
            }
            let cargoType = Int(r.i16(1, m + 0x12)), cargoQty = Int(r.i16(1, m + 0x14))
            let days = Int(r.i16(1, m + 0x45))
            var am = ActiveMission(missionID: missionID, acceptedDate: date,
                                   deadline: days >= 0 ? date.adding(days: days) : nil,
                                   cargoPickedUp: r.b1[m + 0x33] != 0,
                                   shipObjectivesRemaining: max(0, remaining),
                                   visitedTravelStellar: r.b1[f + 1] != 0,
                                   travelSpobID: spob(0x00), returnSpobID: spob(0x04),
                                   resolvedCargoType: cargoType >= 0 ? cargoType : nil,
                                   resolvedCargoQty: cargoType >= 0 && cargoQty > 0 ? cargoQty : nil)
            am.objectiveComplete = complete ? true : nil
            am.failed = r.b1[f + 3] != 0 ? true : nil
            am.shipsDestroyed = destroyedN > 0 ? destroyedN : nil
            am.shipsBoarded = boardedN > 0 ? boardedN : nil
            am.shipsDisabled = disabledN > 0 ? disabledN : nil
            am.shipsChasedOff = chasedN > 0 ? chasedN : nil
            am.shipsSighted = sightedN > 0 ? true : nil
            let sysRaw = Int(r.i16(1, m + 0x10))
            am.shipSystemResolved = true
            am.shipSystemID = sysRaw == -6 ? -6 : (sysRaw >= 0 && sysRaw < 0x800 && game.system(128 + sysRaw) != nil ? 128 + sysRaw : nil)
            let flags = r.u16(1, m + 0x55)
            let lockedIdx = Int(r.i16(1, m + 0x53))
            if flags & 0x0800 != 0, lockedIdx >= 0, game.ship(128 + lockedIdx) != nil { am.lockedShipType = 128 + lockedIdx }
            let nameEntry = Int(r.i16(1, m + 0x49)), subEntry = Int(r.i16(1, m + 0x51))
            am.shipNameEntry = nameEntry > 0 ? nameEntry : nil
            am.shipSubtitleEntry = subEntry > 0 ? subEntry : nil
            let auxMax = Int(r.i16(1, m + 0x61)), auxLeft = Int(r.i16(1, m + 0x6B))
            am.auxShipsRemaining = auxMax > 0 && auxLeft >= 0 ? auxLeft : nil
            am.slot = slot
            let serial = p.nextMissionSerial ?? 1
            am.serial = serial
            p.nextMissionSerial = serial + 1
            p.activeMissions.append(am)
        }
        if slotsMissing > 0 {
            warnings.append("\(slotsMissing) active mission(s) are not in the loaded data (a missing plug-in?) and were dropped.")
        }
        if !p.activeMissions.isEmpty {
            warnings.append("The original does not save when a mission was accepted; accept dates are set to the pilot's current date.")
        }

        // MARK: escort group orders (g_target_category_command, block 2 +0x5d90)
        let orders = (0..<4).map { Int(r.i16(2, 0x5D90 + 2 * $0)) }
        if orders.contains(where: { $0 >= 0 }) {
            p.escortCategoryOrders = orders.map { (0...4).contains($0) ? $0 : -1 }
        }

        // MARK: not carried over
        func count(_ n: Int, _ f: (Int) -> Bool) -> Int { (0..<n).filter(f).count }
        if r.u16(1, 0x10) > 0 { unmapped.append("Shield points (the original ignores them too; ships load at full shield and armor)") }
        let fighters = count(0x40) { r.i16(1, 0xE74E + 2 * $0) >= 0 }
        if fighters > 0 { unmapped.append("\(fighters) launched carrier fighter(s) (restocked from your fighter outfits instead)") }
        if count(0x40, { r.i16(1, 0xE8CE + 2 * $0) != -1 && r.i16(1, 0xE8CE + 2 * $0) != 0 }) > 0 {
            unmapped.append("Fighter voice-type modes")
        }
        if count(0x800, { r.u16(2, 0x2086 + 2 * $0) != 0 }) > 0 { unmapped.append("Per-planet domination-day counters") }
        if (0..<3).contains(where: { r.u16(2, 0x5DD8 + 2 * $0) != 0 }) { unmapped.append("Ship paint color") }
        if r.b2[0x3086] != 0 { unmapped.append("The intro-seen latch") }
        if count(4, { r.u16(2, 0x3588 + 2 * $0) != 0 }) > 0 { unmapped.append("Cosmetic stat-jitter values (the original never reads them)") }
        unmapped.append("Mission accept dates and per-mission random rolls (not saved by the original in a usable form)")
        if blocks.format == .classicMac {
            warnings.append("Classic Mac pilots are converted from their resource fork; the layout is derived from the Windows format and has not been checked against a real Mac pilot.")
        }

        let rating = p.combatRating
        let summary = EVNovaPilotImportSummary(
            format: blocks.format, pilotName: name, nickname: p.nickname ?? "", shipName: p.shipName,
            hullName: hullName, credits: p.credits, date: date, location: location, combatRating: rating,
            ratingTitle: CombatRating.title(forRating: rating), activeMissions: p.activeMissions.count,
            escorts: p.escortWing.count, controlBits: p.setBits.count, warnings: warnings, unmapped: unmapped)
        return EVNovaPilotImportResult(player: p, summary: summary)
    }

    private static func idList(_ ids: [Int]) -> String {
        let head = ids.prefix(8).map(String.init).joined(separator: ", ")
        return ids.count > 8 ? head + ", …" : head
    }

    // MARK: Field reader

    struct Reader {
        let b1: [UInt8], b2: [UInt8], big: Bool
        func blk(_ n: Int) -> [UInt8] { n == 1 ? b1 : b2 }
        func u16(_ n: Int, _ o: Int) -> UInt16 {
            let b = n == 1 ? b1 : b2
            guard o + 2 <= b.count else { return 0 }
            return big ? EVNovaPilotFile.be16(b, o) : EVNovaPilotFile.le16(b, o)
        }
        func i16(_ n: Int, _ o: Int) -> Int16 { Int16(bitPattern: u16(n, o)) }
        func u32(_ n: Int, _ o: Int) -> UInt32 {
            let b = n == 1 ? b1 : b2
            guard o + 4 <= b.count else { return 0 }
            return big ? EVNovaPilotFile.be32(b, o) : EVNovaPilotFile.le32(b, o)
        }
        /// A fixed text field: a C string, or a Pascal string (classic Mac) when
        /// the first byte is a plausible length and the text has no NUL in it.
        func text(_ n: Int, _ o: Int, limit: Int) -> String {
            let b = n == 1 ? b1 : b2
            guard o + limit <= b.count else { return "" }
            let f = Array(b[o..<(o + limit)])
            let len = Int(f[0])
            var bytes: [UInt8]
            if len >= 1, len < limit, !f[1...len].contains(0) {
                bytes = Array(f[1...len])
            } else {
                bytes = Array(f.prefix { $0 != 0 })
            }
            if bytes.count > limit - 1 { bytes = Array(bytes.prefix(limit - 1)) }
            return String(bytes: bytes, encoding: .macOSRoman) ?? ""
        }
    }
}
