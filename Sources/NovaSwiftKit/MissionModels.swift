import Foundation

// Typed decoders for the story/mission resource *bodies*: mïsn, crön, përs,
// ränk, dësc, STR#. Field offsets are the on-disk byte layout (big-endian),
// VERIFIED empirically against the real EV Nova data (791 mïsn / 125 crön /
// 31 ränk) and cross-checked against the ResForge NovaTools TMPL definitions.
// See docs/DATA_FORMAT.md and docs/MISSIONS.md.
//
// All multi-byte fields are big-endian (classic Mac / QuickDraw). The bit
// expression strings (AvailBits, OnAccept, …) are NUL-terminated Mac Roman
// C-strings living in fixed-size (255-byte) fields; their grammar is handled
// by the NCB engine in the NovaSwiftStory module.

// MARK: Byte helpers (big-endian, bounds-safe)

@inline(__always) private func mi16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func mu16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return (Int(d[base]) << 8) | Int(d[base + 1])
}

@inline(__always) private func mi32(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    return Int(Int32(bitPattern: v))
}

/// Read an 8-byte big-endian bitmask (QB64 `Contribute`/`Require` fields).
@inline(__always) private func mu64(_ d: Data, _ off: Int) -> UInt64 {
    guard off >= 0, off + 8 <= d.count else { return 0 }
    let base = d.startIndex + off
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(d[base + i]) }
    return v
}

/// Read a NUL-terminated Mac Roman C-string from a fixed-size field at `off`,
/// reading at most `maxLen` bytes. Trailing garbage after the NUL is ignored.
@inline(__always) private func cstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
    guard off >= 0, off < d.count else { return "" }
    let start = d.startIndex + off
    let end = min(start + maxLen, d.endIndex)
    var bytes: [UInt8] = []
    var i = start
    while i < end {
        let b = d[i]
        if b == 0 { break }
        bytes.append(b)
        i += 1
    }
    return String(bytes: bytes, encoding: .macOSRoman) ?? ""
}

// MARK: mïsn — mission

/// Where a mission's special ships should try to accomplish their goal.
public enum MissionShipGoal: Int, Sendable {
    case none = -1
    case destroy = 0
    case disable = 1
    case board = 2
    case escort = 3
    case observe = 4
    case rescue = 5     // ship starts disabled; player must protect / tow it
    case chaseOff = 6
}

/// Where the cargo (if any) is picked up.
public enum MissionCargoPickup: Int, Sendable {
    case none = -1
    case atStart = 0
    case atTravelStellar = 1
    case onSpecialShip = 2
}

/// Where the cargo (if any) is dropped off.
public enum MissionCargoDropoff: Int, Sendable {
    case none = -1
    case atTravelStellar = 0
    case atReturnStellar = 1
}

/// Where a mission is offered from.
public enum MissionOfferLocation: Int, Sendable {
    case missionComputer = 0
    case bar = 1
    case persShip = 2
    case mainSpaceport = 3
    case tradeCenter = 4
    case shipyard = 5
    case outfitter = 6
    case unknown = -1
}

/// A decoded `mïsn` resource — one mission definition.
///
/// This is the *static* definition. Runtime progress (accepted? objective met?)
/// lives in `NovaSwiftStory.ActiveMission`, keyed by this mission's `id`.
///
/// Field layout verified against the real game's 791 missions (each 1970 bytes):
/// a fixed 92-byte header, then seven 255-byte NCB strings, an 8-byte Require
/// mask + 2-byte date-increment wedged between OnAbort and OnShipDone, then the
/// button texts and display weight.
public struct MissionRes: Sendable {
    public let id: Int
    public let name: String

    // Availability
    public let availStellar: Int      // spob/special code where offered (-1 = any inhabited)
    public let availLocation: MissionOfferLocation
    public let availRecord: Int       // minimum legal record required
    public let availRating: Int       // minimum combat rating required
    public let availRandom: Int       // % chance to appear when eligible
    public let availShipType: Int     // required player ship (<128 / -1 = any)
    public let availBits: String      // NCB test expression gating availability

    // Travel / cargo
    public let travelStellar: Int
    public let returnStellar: Int
    public let cargoType: Int
    public let cargoQty: Int
    public let cargoPickup: MissionCargoPickup
    public let cargoDropoff: MissionCargoDropoff
    public let scanMask: Int

    // Reward
    public let pay: Int
    public let compRewardGovt: Int    // govt whose standing improves on completion
    public let compLegalReward: Int   // legal-record change on completion

    // Special ships (the mission's "target"/escort ships)
    public let shipCount: Int
    public let shipSystem: Int
    public let shipDude: Int
    public let shipGoal: MissionShipGoal
    public let shipBehavior: Int
    public let shipNameStrID: Int
    public let shipStart: Int
    public let auxShipCount: Int
    public let auxShipDude: Int
    public let auxShipSystem: Int

    // Text (dësc / STR# resource ids; -1 = none)
    public let shipSubtitleStrID: Int
    public let briefText: Int
    public let quickBriefText: Int
    public let loadCargoText: Int
    public let dropCargoText: Int
    public let completionText: Int
    public let failureText: Int
    public let shipDoneText: Int
    public let refuseText: Int

    public let timeLimit: Int         // days to complete (<=0 = none)
    public let canAbort: Bool
    public let flags1: Int
    public let flags2: Int
    public let datePostIncrement: Int // days the galaxy clock advances on completion

    // Control-bit side effects (NCB set expressions)
    public let onAccept: String
    public let onRefuse: String
    public let onSuccess: String
    public let onFailure: String
    public let onAbort: String
    public let onShipDone: String

    /// @1622, 8 bytes: bits that must be met (via the player's ship/outfit/rank/
    /// cron `Contribute` fields) for this mission to be available at all — a gate
    /// distinct from, and additional to, `availBits`'s NCB test. Verified against
    /// the `mïsn` TMPL (#510): `Require@1622` sits between `OnAbort` (ending at
    /// 1367+255=1622) and `DatePostIncrement@1630`. See docs/reverse-engineering/GOVERNMENT.md §4.4.
    public let require: UInt64

    public let acceptButton: String
    public let refuseButton: String
    public let displayWeight: Int

    // Named flag bits (subset that matters to the runtime).
    public var autoAbortWhenStarted: Bool { flags1 & 0x0001 != 0 }
    public var cannotBeRefused: Bool      { flags1 & 0x0004 != 0 }
    public var failIfScanned: Bool        { flags1 & 0x0020 != 0 }
    public var invisible: Bool            { flags1 & 0x0400 != 0 }
    public var requiresCargoSpace: Bool   { flags2 & 0x0001 != 0 }
    public var failIfPlayerDisabled: Bool { flags2 & 0x0004 != 0 }

    /// The conventional "offer text" `dësc` id EV Nova shows in the mission
    /// listing: 3872 + the mission id (verified: mïsn 128 → dësc 4000).
    public var offerTextID: Int { 3872 + id }

    /// True if this mission has a special-ship objective the player must fulfil
    /// in space (destroy/board/escort/…), as opposed to a pure cargo run.
    public var hasShipObjective: Bool {
        shipCount > 0 && shipGoal != MissionShipGoal.none
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data

        availStellar   = mi16(d, 0)
        // 2: unused
        availLocation  = MissionOfferLocation(rawValue: mi16(d, 4)) ?? .unknown
        availRecord    = mi16(d, 6)
        availRating    = mi16(d, 8)
        availRandom    = mi16(d, 10)
        travelStellar  = mi16(d, 12)
        returnStellar  = mi16(d, 14)
        cargoType      = mi16(d, 16)
        cargoQty       = mi16(d, 18)
        cargoPickup    = MissionCargoPickup(rawValue: mi16(d, 20)) ?? .none
        cargoDropoff   = MissionCargoDropoff(rawValue: mi16(d, 22)) ?? .none
        scanMask       = mu16(d, 24)
        // 26: unused
        pay            = mi32(d, 28)
        shipCount      = mi16(d, 32)
        shipSystem     = mi16(d, 34)
        shipDude       = mi16(d, 36)
        shipGoal       = MissionShipGoal(rawValue: mi16(d, 38)) ?? .none
        shipBehavior   = mi16(d, 40)
        shipNameStrID  = mi16(d, 42)
        shipStart      = mi16(d, 44)
        compRewardGovt = mi16(d, 46)
        compLegalReward = mi16(d, 48)
        shipSubtitleStrID = mi16(d, 50)
        briefText      = mi16(d, 52)
        quickBriefText = mi16(d, 54)
        loadCargoText  = mi16(d, 56)
        dropCargoText  = mi16(d, 58)
        completionText = mi16(d, 60)
        failureText    = mi16(d, 62)
        timeLimit      = mi16(d, 64)
        canAbort       = mi16(d, 66) != 0
        shipDoneText   = mi16(d, 68)
        // 70: unused
        auxShipCount   = mi16(d, 72)
        auxShipDude    = mi16(d, 74)
        auxShipSystem  = mi16(d, 76)
        flags1         = mu16(d, 78)
        flags2         = mu16(d, 80)
        // 82,84: unused
        refuseText     = mi16(d, 86)
        availShipType  = mi16(d, 88)
        // 90: (availShip legacy / unused word) — availShipType is the meaningful field

        // Seven 255-byte NCB strings; Require(8) + datePostIncrement(2) sit
        // between OnAbort and OnShipDone.
        availBits  = cstr(d, 92,   255)
        onAccept   = cstr(d, 347,  255)
        onRefuse   = cstr(d, 602,  255)
        onSuccess  = cstr(d, 857,  255)
        onFailure  = cstr(d, 1112, 255)
        onAbort    = cstr(d, 1367, 255)
        require    = mu64(d, 1622)
        datePostIncrement = mi16(d, 1630)
        onShipDone = cstr(d, 1632, 255)
        acceptButton = cstr(d, 1887, 32)
        refuseButton = cstr(d, 1919, 33)
        displayWeight = mi16(d, 1952)
    }
}

// MARK: crön — time-based background event

/// A decoded `crön` resource: a background event that fires when the galaxy
/// clock enters its active window and its `enableOn` test passes, then runs
/// `onStart`, holds for `duration` days, and runs `onEnd`.
///
/// Layout verified against the real game (125 crons, 822 bytes each): a
/// 24-byte fixed header, then three NCB strings at 24 / 279 / 534 — **255 /
/// 255 / 256 bytes**, not 255 each (the `crön` TMPL types `OnEnd` as `n100` =
/// 0x100 = 256 bytes, one longer than `EnableOn`/`OnStart`), then an 8-byte
/// `Contribute` + 8-byte `Require` bitmask pair and four 2-byte `NewsGovt`/
/// `GovtNewsStr` id pairs. Confirmed byte-for-byte against `crön #128`
/// "Wraith Change" (`swift run novaswift-extract raw "data/EV Nova" crön 128`):
/// 822 bytes total, `newsGovts[0] == 130` (a real govt id) and
/// `govtNewsStrs[0] == 15000` (a real `STR#` id) at their predicted offsets.
/// See docs/reverse-engineering/EVENTS.md §5.
public struct CronRes: Sendable {
    public let id: Int
    public let name: String

    // Active window (0 = "any" / wildcard for that component).
    public let firstDay: Int, firstMonth: Int, firstYear: Int
    public let lastDay: Int, lastMonth: Int, lastYear: Int
    public let random: Int          // % chance per eligible day
    public let duration: Int        // days the event stays active
    public let preHoldoff: Int      // min days after eligible before it may start
    public let postHoldoff: Int     // min days after it ends before it may recur
    public let independentNewsStrID: Int
    public let flags: Int

    public let enableOn: String     // NCB test — must pass for the event to start
    public let onStart: String      // NCB set — applied when the event begins
    public let onEnd: String        // NCB set — applied when the event ends

    /// @790, 8 bytes: bits this event contributes (while active) toward other
    /// resources' `Require` gates (`oütf.Require`, `mïsn.Require`, `gövt.Require`).
    /// See docs/reverse-engineering/GOVERNMENT.md §4.4.
    public let contribute: UInt64
    /// @798, 8 bytes: bits that must be met (via the player's ship/outfit/rank
    /// `Contribute` fields) for this cron to be allowed to activate at all —
    /// a capability gate distinct from `enableOn`'s control-bit test.
    public let require: UInt64
    /// @806, 4×2 bytes: `NewsGovt1-4` — up to four government ids that each get
    /// their own "local news" feed while this event is active.
    public let newsGovts: [Int]
    /// @814, 4×2 bytes: `GovtNewsStr1-4` — the `STR#` id to randomly pick local
    /// news text from, one per corresponding `newsGovts` slot.
    public let govtNewsStrs: [Int]

    public var loopStartUntilFalse: Bool { flags & 0x0001 != 0 }
    public var loopEndUntilFalse: Bool   { flags & 0x0002 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        firstDay   = mi16(d, 0)
        firstMonth = mi16(d, 2)
        firstYear  = mi16(d, 4)
        lastDay    = mi16(d, 6)
        lastMonth  = mi16(d, 8)
        lastYear   = mi16(d, 10)
        random     = mi16(d, 12)
        duration   = mi16(d, 14)
        preHoldoff = mi16(d, 16)
        postHoldoff = mi16(d, 18)
        independentNewsStrID = mi16(d, 20)
        flags      = mu16(d, 22)
        enableOn = cstr(d, 24,  255)
        onStart  = cstr(d, 279, 255)
        onEnd    = cstr(d, 534, 256)
        contribute = mu64(d, 790)
        require    = mu64(d, 798)
        newsGovts     = (0..<4).map { mi16(d, 806 + $0 * 2) }
        govtNewsStrs  = (0..<4).map { mi16(d, 814 + $0 * 2) }
    }
}

// MARK: përs — named character / unique NPC captain

/// A decoded `përs` resource: a named unique captain that can appear in space,
/// optionally offering a linked mission. AI/combat behaviour is fleshed out by
/// the (separate) AI module; the story engine only needs the mission link, the
/// activation test, and where the person roams.
///
/// The full përs body carries variable-length weapon arrays near its tail; this
/// decoder reads the fixed head plus the `activeOn` NCB test (empirically at
/// offset 52) and the linked mission, which is what the story layer consumes.
public struct PersRes: Sendable {
    public let id: Int
    public let name: String

    public let linkSystem: Int
    public let govt: Int
    public let aiType: Int
    public let aggression: Int
    public let retreatShield: Int
    public let shipType: Int
    public let linkMission: Int      // mïsn id this person offers (-1 = none)
    public let flags1: Int
    public let activeOn: String      // NCB test gating whether the person exists
    public let subtitle: String

    public var deactivateAfterAccept: Bool { flags1 & 0x0100 != 0 }
    public var offerOnBoard: Bool          { flags1 & 0x0200 != 0 }
    public var leavesAfterAccept: Bool     { flags1 & 0x0800 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        linkSystem    = mi16(d, 0)
        govt          = mi16(d, 2)
        aiType        = mi16(d, 4)
        aggression    = mi16(d, 6)
        retreatShield = mi16(d, 8)
        shipType      = mi16(d, 10)
        linkMission   = mi16(d, 30)
        flags1        = mu16(d, 32)
        activeOn      = cstr(d, 52, 256)
        subtitle      = cstr(d, 314, 64)
    }
}

// MARK: ränk — player standing with a government

/// A decoded `ränk` resource: a title the player can hold with a government,
/// carrying salary and privileges. Layout verified against the real game
/// (31 ranks): Contribute(8) + Flags(2) sit between SalaryCap and the names.
public struct RankRes: Sendable {
    public let id: Int
    public let name: String

    public let weight: Int
    public let govt: Int
    public let priceModifier: Int    // % of normal prices at this govt's ports
    public let salary: Int           // credits per day
    public let salaryCap: Int        // 0 = uncapped
    /// @14, 8 bytes: bits this rank contributes (while active) toward other
    /// resources' `Require` gates — "prevent the player from buying certain
    /// items or doing certain missions until achieving a certain rank."
    /// See docs/reverse-engineering/GOVERNMENT.md §4.4.
    public let contribute: UInt64
    public let flags: Int
    public let conversationName: String
    public let shortName: String

    public var permanent: Bool          { flags & 0x0008 != 0 }
    public var govtWontAttack: Bool     { flags & 0x0100 != 0 }
    public var canAlwaysLand: Bool      { flags & 0x0200 != 0 }
    public var freeRepairRefuel: Bool   { flags & 0x0800 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        weight        = mi16(d, 0)
        govt          = mi16(d, 2)
        priceModifier = mi16(d, 4)
        salary        = mi32(d, 6)
        salaryCap     = mi32(d, 10)
        contribute    = mu64(d, 14)
        flags         = mu16(d, 22)
        conversationName = cstr(d, 24, 64)
        shortName        = cstr(d, 88, 64)
    }
}

// MARK: dësc — description text

/// A decoded `dësc` resource: a block of narrative text (with an optional
/// picture / movie). The description string is a leading NUL-terminated C-string
/// at offset 0; the picture id / movie / flags follow it (skipped here — the
/// story layer only needs the text).
public struct DescRes: Sendable {
    public let id: Int
    public let text: String

    public init(_ r: Resource) {
        id = r.id
        text = cstr(r.data, 0, r.data.count)
    }
}

// MARK: STR# — indexed string list

/// A decoded `STR#` resource: a count-prefixed list of Pascal strings. Used for
/// ship names, cargo types, comm/hail quotes, button labels, etc.
public struct StringListRes: Sendable {
    public let id: Int
    public let name: String
    public let strings: [String]

    /// 1-based lookup (EV Nova indexes STR# entries from 1); returns nil if out
    /// of range.
    public func string(at index1: Int) -> String? {
        let i = index1 - 1
        guard i >= 0, i < strings.count else { return nil }
        return strings[i]
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        var out: [String] = []
        guard d.count >= 2 else { strings = []; return }
        let count = mu16(d, 0)
        var off = 2
        for _ in 0..<count {
            guard off < d.count else { break }
            let len = Int(d[d.startIndex + off]); off += 1
            guard off + len <= d.count else { break }
            let s = String(bytes: d[(d.startIndex + off)..<(d.startIndex + off + len)],
                           encoding: .macOSRoman) ?? ""
            out.append(s)
            off += len
        }
        strings = out
    }
}
