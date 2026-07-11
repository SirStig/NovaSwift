import Foundation

// Typed decoder for the `chär` resource — an EV Nova *starting scenario*
// (what the game calls a "pilot" template at new-game time). Field offsets are
// the on-disk big-endian byte layout, reverse-engineered and verified against
// the real base game's single `chär` #128 ".Trader" (362 bytes) and cross-checked
// against the ResForge NovaTools `chär` template.
//
// The base game ships exactly one `chär`; plug-ins / total-conversions add more,
// and the new-pilot screen lets the player pick among them. EV Nova hides any
// scenario whose name starts with "." when other (visible) scenarios exist.
//
// This is the single authoritative `CharRes` (an earlier minimal version lived in
// NovaEconomy.swift). The legacy `startingCredits`/`startingShip`/`startingSystem`
// accessors are preserved so existing callers keep working.

// MARK: Byte helpers (big-endian, bounds-safe) — file-local to avoid touching
// the `private` helpers in NovaModels.swift / MissionModels.swift.

@inline(__always) private func ci16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func ci32(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    let v = (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    return Int(Int32(bitPattern: v))
}

/// Read a NUL-terminated Mac Roman C-string from a fixed field of `maxLen` bytes.
@inline(__always) private func ccstr(_ d: Data, _ off: Int, _ maxLen: Int) -> String {
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

// MARK: chär — starting scenario / new-pilot template

/// One `chär` resource: the initial conditions a new pilot begins with — cash,
/// ship, a set of candidate start systems (one is chosen at random), initial
/// government standings, combat rating, an intro slideshow, and story bits to set.
public struct CharRes: Sendable {
    /// One initial government-standing entry (govt id + the status value applied;
    /// the negated value is also applied to that govt's enemies).
    public struct GovtStatus: Hashable, Sendable {
        public let govt: Int
        public let status: Int
    }
    /// One intro-slideshow slide: a PICT id and how long to show it (seconds).
    public struct IntroSlide: Hashable, Sendable {
        public let pictID: Int
        public let delaySeconds: Int
    }

    public let id: Int
    public let name: String

    /// Starting money.
    public let cash: Int
    /// Starting hull `shïp` id.
    public let shipID: Int
    /// Candidate start systems (`sÿst` ids); the game picks one at random.
    public let startSystems: [Int]
    /// Initial legal standings to apply.
    public let govtStatuses: [GovtStatus]
    /// Starting combat rating (kill count).
    public let kills: Int
    /// Intro slideshow shown when the pilot is created (may be empty).
    public let introSlides: [IntroSlide]
    /// `dësc` id of the intro story text (nil if none).
    public let introTextID: Int?
    /// NCB "set" expression run once at game start (empty if none).
    public let onStart: String
    /// Raw flags word (bit 0x0001 = "default character").
    public let flags: Int
    /// Starting calendar date, as raw day/month/year (converted to a GameDate by
    /// the story layer, which owns the calendar type).
    public let startDay: Int
    public let startMonth: Int
    public let startYear: Int
    /// Text shown before/after the numeric date in the UI (e.g. suffix " NC").
    public let datePrefix: String
    public let dateSuffix: String

    // MARK: Legacy accessors (kept for existing callers)

    /// Starting money. (Legacy name; same as `cash`.)
    public var startingCredits: Int { cash }
    /// Starting hull. (Legacy name; same as `shipID`.)
    public var startingShip: Int { shipID }
    /// Candidate start systems. (Legacy name; same as `startSystems`.)
    public var startingSystems: [Int] { startSystems }
    /// The system the pilot begins in (first candidate, else 128). (Legacy.)
    public var startingSystem: Int { startSystems.first ?? 128 }

    // MARK: Derived

    /// Whether this is the "default character" (flags bit 0x0001).
    public var isDefault: Bool { (flags & 0x0001) != 0 }

    /// Name shown in the picker: a leading "." (EV Nova's hide marker) is stripped.
    public var displayName: String {
        var n = name
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "Scenario \(id)" : n
    }

    /// True when EV Nova would hide this scenario from the picker (name starts ".").
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(_ r: Resource) {
        id = r.id
        name = r.name
        let d = r.data
        cash = ci32(d, 0)
        shipID = ci16(d, 4)
        // Four candidate start systems @6/8/10/12; a slot < 128 is unused.
        startSystems = (0..<4).map { ci16(d, 6 + $0 * 2) }.filter { $0 >= 128 }
        // Four govt ids @14… paired with four status values @22…; -1 govt = unused.
        var statuses: [GovtStatus] = []
        for i in 0..<4 {
            let g = ci16(d, 14 + i * 2)
            if g >= 0 { statuses.append(GovtStatus(govt: g, status: ci16(d, 22 + i * 2))) }
        }
        govtStatuses = statuses
        kills = ci16(d, 30)
        // Four intro PICTs @32… with matching delays @40…; -1 pict = unused.
        var slides: [IntroSlide] = []
        for i in 0..<4 {
            let p = ci16(d, 32 + i * 2)
            if p >= 0 { slides.append(IntroSlide(pictID: p, delaySeconds: ci16(d, 40 + i * 2))) }
        }
        introSlides = slides
        let textID = ci16(d, 48)
        introTextID = textID >= 0 ? textID : nil
        onStart = ccstr(d, 50, 256)
        flags = ci16(d, 306)
        startDay = ci16(d, 308)
        startMonth = ci16(d, 310)
        startYear = ci16(d, 312)
        datePrefix = ccstr(d, 314, 16)
        dateSuffix = ccstr(d, 330, 16)
    }
}
