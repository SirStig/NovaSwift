import Foundation

// Two things stand between EV Nova's raw resource text and what the player is
// supposed to read.
//
// 1. Resource *names* carry a developer annotation after a semicolon. The data
//    ships ship #361 as "Shuttle;Second-Hand - poor" and ship #256 as
//    "Zephyr;Cloaking"; the game shows "Shuttle" and "Zephyr". The used-ship
//    variants say so in their own `dësc` (#13233: "…not far from being consigned
//    to the junk heap"), which is where that information belongs — not in the
//    class name on the targeting display.
//
// 2. `dësc` bodies are *mutable text*. Per the Nova Bible, a description may
//    embed `{bXXX "yes" "no"}` (test control bit XXX), `{G "male" "female"}`,
//    and `{P "registered" "unregistered"}` — each optionally negated with `!`,
//    each with an optional second string, and each allowing `\"` escapes inside
//    the strings. Rendering the raw bytes leaks `{b424 "` into the outfitter.

// MARK: - Display names

public extension String {
    /// The player-visible form of an EV Nova resource name: everything from the
    /// first semicolon onward is a developer annotation and is dropped.
    ///
    ///     "Shuttle;Second-Hand - poor"  →  "Shuttle"
    ///     "Zephyr;Cloaking"             →  "Zephyr"
    ///     "Lightning; Wild Geese"       →  "Lightning"
    ///     "Recover Stolen Art;Special"  →  "Recover Stolen Art"
    ///
    /// Names without a semicolon are returned unchanged. A name that *begins*
    /// with a semicolon has no visible part, so the raw name is kept rather than
    /// rendering an empty label.
    var novaDisplayName: String {
        guard let semi = firstIndex(of: ";") else { return self }
        let visible = self[startIndex..<semi].trimmingCharacters(in: .whitespaces)
        return visible.isEmpty ? self : visible
    }

    /// The shop-grid names EV Nova draws under an item's picture encode their
    /// line break as a **literal two-character escape** — a backslash followed by
    /// `n`, not a newline byte. `oütf` #130 ships its outfitter name as
    /// `Light Blaster\nTurret`, #134 as `IR Missile\nLauncher`, and `shïp` #142's
    /// short name as `Fed Patrol\nBoat`; the original wraps each onto two lines in
    /// the 83×54 tile. Rendered raw, the escape leaks into the label
    /// ("IR Missile\nLauncher").
    ///
    /// - `novaGridName` turns the escape into the real line break the tile wants.
    /// - `novaSingleLineName` flattens it to a space, for the many places that
    ///   want the item's name inside running text (a toast, a search list, an
    ///   "n× <item>" line) where a hard break would be wrong.
    var novaGridName: String { replacingOccurrences(of: "\\n", with: "\n") }
    /// See `novaGridName`.
    var novaSingleLineName: String { replacingOccurrences(of: "\\n", with: " ") }
}

/// A resource whose `name` field is shown to the player and therefore needs the
/// developer annotation stripped. `name` stays raw so logs and the extractor can
/// still disambiguate the twelve `Second-Hand` hulls and the eight `;Cloaking`
/// Zephyrs from one another.
public protocol NovaNamedResource {
    var name: String { get }
}

public extension NovaNamedResource {
    /// The name as the player should see it. See `String.novaDisplayName`.
    var displayName: String { name.novaDisplayName }
}

extension ShipRes: NovaNamedResource {}
extension OutfRes: NovaNamedResource {}
extension MissionRes: NovaNamedResource {}
extension PersRes: NovaNamedResource {}
extension SpobRes: NovaNamedResource {}
extension SystRes: NovaNamedResource {}
// gövt #186 ships as "Federation;hates Temmin Shard" — the annotation belongs in
// the designer's notes, not on the player's targeting readout or map legend.
extension GovtRes: NovaNamedResource {}

// MARK: - Description formatting

/// What a `dësc` body needs to resolve its conditional segments.
public struct NovaTextContext: Sendable {
    /// Whether NCB control bit `index` is set.
    public var isBitSet: @Sendable (Int) -> Bool
    public var isMale: Bool
    /// EV Nova's shareware-registration test. This port has nothing to register,
    /// so the faithful reading of `{P …}` is "always registered" — the player
    /// sees the text a paid 2002 copy would have shown.
    public var isRegistered: Bool
    /// Days since registration, for the `{Pxxx …}` form ("registered at least
    /// xxx days ago").
    public var daysRegistered: Int

    public init(isBitSet: @escaping @Sendable (Int) -> Bool = { _ in false },
                isMale: Bool = true,
                isRegistered: Bool = true,
                daysRegistered: Int = .max) {
        self.isBitSet = isBitSet
        self.isMale = isMale
        self.isRegistered = isRegistered
        self.daysRegistered = daysRegistered
    }
}

public enum NovaDescFormatter {

    /// Resolve every `{…}` conditional in a `dësc` body and normalize the
    /// classic-Mac carriage returns the resources are stored with.
    ///
    /// This is the original's character machine (0x0044a4d0, MS-21), quirks
    /// included: the `!` negate latch is never reset, so every conditional
    /// after the first `{!…}` in a text is inverted too; a `{` whose header
    /// isn't `b`/`g`/`p` swallows text until one turns up; a `\` escapes the
    /// next character inside an arm; and anything after the chosen arm up to
    /// the `}` is dropped.
    public static func render(_ raw: String, context: NovaTextContext = .init()) -> String {
        enum State { case copy, header, digits, seekTaken, taken, seekSkipped, skipped, afterSkipped, discard }
        var out = ""
        out.reserveCapacity(raw.count)
        var state = State.copy
        var negate = false
        var escaped = false
        var count = 0
        var isBitTest = false
        for ch in raw {
            switch state {
            case .copy:
                if ch == "{" { state = .header } else { out.append(ch) }
            case .header:
                switch ch {
                case "g", "G":
                    state = (context.isMale != negate) ? .seekTaken : .seekSkipped
                case "p", "P":
                    count = 0; isBitTest = false; state = .digits
                case "b", "B":
                    count = 0; isBitTest = true; state = .digits
                case "!":
                    negate = true
                default:
                    break
                }
            case .digits:
                if let d = ch.wholeNumberValue, ch.isASCII {
                    count = count &* 10 &+ d
                    continue
                }
                let pass = isBitTest ? (count >= 0 && context.isBitSet(count)) : context.isRegistered
                if pass != negate {
                    state = ch == "\"" ? .taken : .seekTaken
                } else {
                    state = ch == "\"" ? .skipped : .seekSkipped
                }
            case .seekTaken:
                if ch == "\"" { state = .taken }
            case .taken:
                if ch == "\\" {
                    escaped = true
                } else if ch != "\"" || escaped {
                    out.append(ch)
                    escaped = false
                } else {
                    state = .discard
                }
            case .seekSkipped:
                if ch == "\"" { state = .skipped }
            case .skipped:
                if ch == "\\" {
                    escaped = true
                } else if ch != "\"" || escaped {
                    escaped = false
                } else {
                    state = .afterSkipped
                }
            case .afterSkipped:
                if ch == "}" { state = .copy } else if ch == "\"" { state = .taken }
            case .discard:
                if ch == "}" { state = .copy }
            }
        }
        return normalizeNewlines(out)
    }

    /// EV Nova's resources use classic Mac CR line endings (and CRLF in places).
    public static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
    }
}
