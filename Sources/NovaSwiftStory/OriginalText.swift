import Foundation
import NovaSwiftKit

/// Player-facing text the original builds from its string resources rather
/// than hard-coded English (Batch 7: UI-08, UI-11, UI-13). Every line is
/// assembled from STR# 2002 ("misc strings"), 137 (dates and count words) and
/// 138 (combat ratings), so a total conversion that re-texts those resources is
/// honoured. `rand(n)` stands in for the original's `NovaRandom_Range(n)`.
public struct OriginalText {
    public let game: NovaGame

    public init(game: NovaGame) { self.game = game }

    /// STR# 2002 entry `n` (1-based), or "" when the data lacks it.
    public func misc(_ n: Int) -> String { game.stringList(2002)?.string(at: n) ?? "" }

    /// How long a status-bar message stays up, in the original's raw sim calls.
    public enum Duration {
        /// Jump arrival, launch, most notices.
        public static let standard = 0xf0
        /// Landing request, clearance and denials.
        public static let landing = 0xfa
        /// Too far / too fast on the second Land press.
        public static let approach = 0x168
        /// The system buoy.
        public static let buoy = 0x1e0
        /// A përs HailQuote broadcast.
        public static let hailQuote = 0x1a4
        /// A staged mission `Q` message replacing the launch line.
        public static let missionQuote = 0x1f4
    }

    // MARK: Dates (0x00468450 / 0x00468600)

    /// "Jan. 1st, 1177" with the chär date prefix/suffix (STR# 137 #13–24 and
    /// the ordinals #25–28). `long` uses the full month names (#1–12).
    public func date(_ d: GameDate, long: Bool = false, prefix: String = "", suffix: String = "") -> String {
        let month = game.stringList(137)?.string(at: long ? d.month : d.month + 12) ?? ""
        var ordinal = 28                                  // "th"
        switch d.day % 10 {
        case 1: ordinal = 25
        case 2: ordinal = 26
        case 3: ordinal = 27
        default: break
        }
        if d.day > 10 && d.day < 14 { ordinal = 28 }
        let th = game.stringList(137)?.string(at: ordinal) ?? ""
        return "\(prefix)\(month) \(d.day)\(th), \(d.year)\(suffix)"
    }

    /// The chär date prefix/suffix for `player`: the ones saved with the pilot,
    /// else (older saves) the lowest-id chär's.
    public func dateAffixes(for player: PlayerState) -> (prefix: String, suffix: String) {
        if let p = player.datePrefix, let s = player.dateSuffix { return (p, s) }
        let first = game.characters().min { $0.id < $1.id }
        return (player.datePrefix ?? first?.datePrefix ?? "", player.dateSuffix ?? first?.dateSuffix ?? "")
    }

    public func date(for player: PlayerState, long: Bool = false) -> String {
        let a = dateAffixes(for: player)
        return date(player.date, long: long, prefix: a.prefix, suffix: a.suffix)
    }

    // MARK: Status-bar lines

    /// Hyperspace arrival with no buoy (0x0044f3d0): "Entering the" /
    /// "Jumping into the" / "Arriving in the" (#43–45, by `rand(3)`; a gate
    /// arrival #46, a wormhole #47) + system + "system on" (#48) + long date +
    /// ".", then " No stellar objects present." (#49) when the system has none.
    public func arrival(system: String, player: PlayerState, hasStellars: Bool,
                        via gate: GateKind? = nil, abandonedFighters: Int = 0, rand: (Int) -> Int) -> String {
        let lead: Int
        switch gate {
        case .hypergate: lead = 46
        case .wormhole: lead = 47
        case nil: lead = 43 + rand(3)
        }
        var line = "\(misc(lead)) \(system) \(misc(48)) \(date(for: player, long: true))."
        if !hasStellars { line += " " + misc(49) }
        // Bay fighters left behind: "  (Two fighters abandoned)" (#164/#165).
        if abandonedFighters > 0 {
            line += "  (\(capitalizedCountWord(abandonedFighters)) \(misc(abandonedFighters == 1 ? 164 : 165)))"
        }
        return line
    }

    public enum GateKind { case hypergate, wormhole }

    /// Leaving a spaceport (0x00456134): "Launching from" … "Departing"
    /// (#55–59, by `rand(5)`) + stellar + "on" (#60) + date + ".".
    public func launch(stellar: String, player: PlayerState, rand: (Int) -> Int) -> String {
        "\(misc(55 + rand(5))) \(stellar) \(misc(60)) \(date(for: player))."
    }

    // MARK: Landing (0x00457580 / 0x00459950)

    /// What kind of body a landing line talks about.
    public enum Body {
        case planet, station, hypergate, wormhole

        public init(_ spob: SpobRes) {
            if spob.isHypergate { self = .hypergate }
            else if spob.isWormhole { self = .wormhole }
            else if spob.isStation { self = .station }
            else { self = .planet }
        }
    }

    /// The first Land press on a stellar that grants access: by `rand(3)` either
    /// "<name> traffic control reads you" (#78; stations "dockmaster" #76) or
    /// "Landing request received" (#79; stations #77); hypergates #74/#75 by
    /// `rand(2)`. Half the time ", <pilot>" follows; always ". Begin initial
    /// approach." (#80).
    public func landingRequest(body: Body, stellar: String, pilot: String, rand: (Int) -> Int) -> String {
        var line: String
        switch body {
        case .hypergate, .wormhole:
            line = misc(74 + rand(2))
        case .station:
            line = rand(3) == 0 ? "\(stellar) \(misc(76))" : misc(77)
        case .planet:
            line = rand(3) == 0 ? "\(stellar) \(misc(78))" : misc(79)
        }
        if rand(2) == 0 { line += ", \(pilot)" }
        return line + ". " + misc(80)
    }

    /// Clearance on reaching 250 px: by `rand(3)` "Cleared to land, <pilot>."
    /// (#97), "<pilot>, you're cleared to land." (#98) or "You are cleared to
    /// land." (#99) (stations #94–96, hypergates #91–93); then by `rand(2)`
    /// "Commence final approach." (#100) or "Welcome to <stellar>." (#101); and
    /// " [Landing fee is <n> credits.]" (#104 + #105, stations #103, gates #102).
    public func landingClearance(body: Body, stellar: String, pilot: String, fee: Int,
                                 rand: (Int) -> Int) -> String {
        let base: Int
        switch body {
        case .hypergate, .wormhole: base = 91
        case .station: base = 94
        case .planet: base = 97
        }
        var line: String
        switch rand(3) {
        case 0: line = "\(misc(base)), \(pilot). "
        case 1: line = "\(pilot), \(misc(base + 1)) "
        default: line = "\(misc(base + 2)) "
        }
        line += rand(2) == 0 ? misc(100) : "\(misc(101)) \(stellar)."
        if fee > 0 {
            let feeLead: Int
            switch body {
            case .hypergate, .wormhole: feeLead = 102
            case .station: feeLead = 103
            case .planet: feeLead = 104
            }
            line += " \(misc(feeLead)) \(fee) \(misc(fee == 1 ? 32 : 33))\(misc(105))"
        }
        return line
    }

    /// The first press on a stellar that denies access: "Hypergate usage
    /// denied." / "Docking request denied." / "Landing request denied."
    /// (#81–83).
    public func landingDenied(body: Body) -> String {
        switch body {
        case .hypergate, .wormhole: return misc(81)
        case .station: return misc(82)
        case .planet: return misc(83)
        }
    }

    /// Second-press refusals: too far (#65–68) and too fast (#69–72).
    public func tooFar(body: Body) -> String {
        switch body {
        case .hypergate: return misc(65)
        case .wormhole: return misc(66)
        case .station: return misc(67)
        case .planet: return misc(68)
        }
    }

    public func tooFast(body: Body) -> String {
        switch body {
        case .hypergate: return misc(69)
        case .wormhole: return misc(70)
        case .station: return misc(71)
        case .planet: return misc(72)
        }
    }

    /// A stellar whose sprite is inactive (a base still hidden, a gate that is
    /// offline): "Your ship is unable to" (#84) + the gate tail (#85/#86), or
    /// "dock at " / "land on " (#87/#88) + name + "." + the hull/environment tail
    /// (#89/#90).
    public func unableToLand(body: Body, stellar: String) -> String {
        switch body {
        case .hypergate: return "\(misc(84)) \(misc(85))"
        case .wormhole: return "\(misc(84)) \(misc(86))"
        case .station: return "\(misc(84)) \(misc(87)) \(stellar). \(misc(89))"
        case .planet: return "\(misc(84)) \(misc(88)) \(stellar). \(misc(90))"
        }
    }

    /// "You don't have enough credits to pay the landing fee." (#61 + #32/#33
    /// + #62–64).
    public func feeUnaffordable(body: Body) -> String {
        let tail: Int
        switch body {
        case .hypergate, .wormhole: tail = 62
        case .station: tail = 63
        case .planet: tail = 64
        }
        return "\(misc(61)) \(misc(33)) \(misc(tail))"
    }

    // MARK: Numbers and counts

    /// The original's digit grouping for credits ("1,234,567").
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// A count word: "a"/"an" (STR# 2002 #393/#394) for one, "two"…"ten"
    /// (STR# 137 #30–38) up to ten, digits beyond. `vowelNext` picks "an".
    public func countWord(_ n: Int, vowelNext: Bool = false) -> String {
        if n == 1 { return misc(vowelNext ? 394 : 393) }
        if (2...10).contains(n), let w = game.stringList(137)?.string(at: 28 + n) { return w }
        return "\(n)"
    }

    /// `Ship_FormatLocalizedCountWord` 0x00465d90 with capitalisation on:
    /// "One"…"Ten" (STR# 137 #29–38), grouped digits outside 1…10.
    public func capitalizedCountWord(_ n: Int) -> String {
        guard (1...10).contains(n), let w = game.stringList(137)?.string(at: 28 + n), let first = w.first else {
            return Self.grouped(n)
        }
        return first.uppercased() + w.dropFirst()
    }

    /// The combat-rating title from STR# 138, by the same thresholds as
    /// `CombatRating.title(forRating:)`.
    public func combatRating(_ rating: Int) -> String {
        let index = CombatRating.tierIndex(forRating: rating)
        return game.stringList(138)?.string(at: index + 1) ?? CombatRating.titles[index]
    }
}
