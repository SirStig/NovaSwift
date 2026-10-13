import Foundation
import NovaSwiftKit

// The in-flight status-bar sentences the original builds from STR# 2002 /
// 137 (UI-11, 2026-10-13 closing pass). Both frontends call these instead of
// hand-writing English, so a total conversion that re-texts the string
// resources is honoured and the two apps cannot drift. Each function names the
// call site it was read from.

extension OriginalText {

    // MARK: Count words

    /// `Ship_FormatLocalizedCountWord` 0x00465d90 with capitalisation off:
    /// "one"…"ten" (STR# 137 #29–38), grouped digits outside 1…10. (The
    /// capitalised form is `capitalizedCountWord`; the "a"/"an" form is
    /// `countWord`.)
    public func localizedCountWord(_ n: Int) -> String {
        guard (1...10).contains(n), let w = game.stringList(137)?.string(at: 28 + n) else { return Self.grouped(n) }
        return w
    }

    /// "a" or "an" (STR# 2002 #393 / #394) by the first letter of `name`
    /// (`FUN_004d6230` lower-cases it; a, e, i, o, u take "an").
    public func article(before name: String) -> String {
        let first = name.first.map { String($0).lowercased() } ?? ""
        return misc("aeiou".contains(first) && !first.isEmpty ? 394 : 393)
    }

    // MARK: Mission failure (0x004192d0, 0x00401800, 0x00443c60)

    /// "Mission failed." — #284 (0x11c). The original shows it once per
    /// event (the slot loop `break`s after the first failed mission).
    public var missionFailedLine: String { misc(284) }

    // MARK: Contraband scan result (Ship_ScanPlayerForContraband 0x00401800)

    /// What the government scan found. Mission cargo is a flat sentence; junk
    /// and outfits name the item.
    public enum ScanFinding: Equatable, Sendable {
        case missionCargo
        /// Junk's lower-case name (`JunkRes.runningTextName`).
        case junk(String)
        /// An illegal outfit: its lower-case singular and plural names and
        /// the owned count (one → "a/an <singular>", more → "<plural>").
        case outfit(singular: String, plural: String, count: Int)
    }

    /// "<scanner>:  <pilot>, <finding> has been detected." plus, when a fine
    /// is levied, " You have been fined N credits." (#375–#380; separators
    /// ":  ", ", ", " ", "." read from 0x0056b000–0x0056b00c). `scanner` is
    /// the scanning përs's name, else its hull's class name.
    public func scanDetected(scanner: String, pilot: String, finding: ScanFinding, fine: Int) -> String {
        var line = "\(scanner):  \(pilot), "
        switch finding {
        case .missionCargo:
            line += "\(misc(376)) \(misc(377)) \(misc(378)) \(misc(379))."
        case let .junk(name):
            line += "\(misc(376)) \(name) \(misc(378)) \(misc(379))."
        case let .outfit(singular, plural, count):
            line += misc(375) + " "
            if count == 1 { line += "\(article(before: singular)) \(singular)" } else { line += plural }
            line += " \(misc(379))."
        }
        if fine > 0 {
            line += " \(misc(380)) \(Self.grouped(fine)) \(misc(fine < 2 ? 32 : 33))."
        }
        return line
    }

    // MARK: Assistance (Ship_ApplyShipAiControls 0x00408150, mode 0xf)

    /// "<class>:  Repairs complete, <pilot>." — #384, 0xf0 raw calls, snd 151.
    public func repairsComplete(shipClass: String, pilot: String) -> String {
        "\(shipClass):  \(misc(384)), \(pilot)."
    }

    // MARK: Plunder (NovaUi_RunBoardingPlunderWindow 0x00482940)

    /// Credits button: "You stole all the credits from this ship." (#116 +
    /// #33 + #108). Nothing is shown when the hulk has none (snd 153 only).
    public var plunderedCredits: String { "\(misc(116)) \(misc(33)) \(misc(108))" }

    /// Cargo button: "You salvaged N tons of X from this ship." (#115, the
    /// grouped count, #1/#2, #391, the name, #108); #114 when none fits.
    public func plunderedCargo(tons: Int, name: String) -> String {
        "\(misc(115)) \(Self.grouped(tons)) \(misc(tons == 1 ? 1 : 2)) \(misc(391)) \(name) \(misc(108))"
    }

    public var plunderCargoNoRoom: String { misc(114) }

    /// Ammo button: "You salvaged two rockets from this ship." (#115, the
    /// lower-case count word, the outfit's lower-case singular or plural
    /// name, #108); #117 when nothing could be stowed.
    public func plunderedAmmo(rounds: Int, singular: String, plural: String) -> String {
        guard rounds > 0 else { return misc(117) }
        return "\(misc(115)) \(localizedCountWord(rounds)) \(rounds < 2 ? singular : plural) \(misc(108))"
    }

    /// Energy (fuel) button. `fitAll` is false when the tank filled with
    /// energy left over: #5 "You transferred all of this ship's energy…" if
    /// the tank is not yet full afterwards, #4 "You filled your reactors and
    /// batteries…" if it is; #6 when nothing fit.
    public func plunderedEnergy(tookAny: Bool, tankFull: Bool) -> String {
        guard tookAny else { return misc(6) }
        return misc(tankFull ? 4 : 5)
    }

    /// A boarded përs hands over an item (0x00482940 head): "You retrieved
    /// a/an <name> from this ship." — #106 (it carries its own trailing
    /// space), a/an for one by the first letter, #137 words for 2…10, digits
    /// beyond, the singular or plural name, #108.
    public func retrievedOutfit(count: Int, singular: String, plural: String) -> String {
        let amount: String
        if count == 1 { amount = article(before: singular) }
        else { amount = (2...10).contains(count) ? localizedCountWord(count) : Self.grouped(count) }
        let lead = misc(106)
        return "\(lead)\(lead.hasSuffix(" ") ? "" : " ")\(amount) \(count < 2 ? singular : plural) \(misc(108))"
    }

    /// "You assigned this ship to your fleet of escorts." — #123, the capture
    /// that becomes an escort (0x00482940).
    public var capturedAsEscortLine: String { misc(123) }

    // MARK: Bombs (Player-tick bomb fuse, the 0x0044b3d4 block)

    /// A nonlethal bomb goes off: "Your <outfit> has exploded!" (#39, the
    /// outfit's lower-case singular or plural name, #40 "has exploded!" /
    /// #41 "have exploded!"), 0x190 raw calls.
    public func bombExploded(count: Int, singular: String, plural: String) -> String {
        "\(misc(39)) \(count < 2 ? singular : plural) \(misc(count < 2 ? 40 : 41))"
    }
}
