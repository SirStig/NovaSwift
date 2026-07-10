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
    /// Unrecognized or malformed sequences are emitted verbatim: a plug-in
    /// author's stray `{` should show up as a stray `{`, not swallow the rest of
    /// the description.
    public static func render(_ raw: String, context: NovaTextContext = .init()) -> String {
        var out = ""
        out.reserveCapacity(raw.count)

        var i = raw.startIndex
        while i < raw.endIndex {
            guard raw[i] == "{" else {
                out.append(raw[i])
                i = raw.index(after: i)
                continue
            }
            if let (replacement, next) = parseConditional(raw, from: i, context: context) {
                out += replacement
                i = next
            } else {
                out.append(raw[i])           // not a conditional — pass it through
                i = raw.index(after: i)
            }
        }
        return normalizeNewlines(out)
    }

    /// EV Nova's resources use classic Mac CR line endings (and CRLF in places).
    public static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Parsing

    /// Parse `{[!]TEST "a" ["b"]}` starting at `open` (which must be `{`).
    /// Returns the substituted text and the index just past the closing brace,
    /// or nil when this isn't a well-formed conditional.
    private static func parseConditional(
        _ s: String, from open: String.Index, context: NovaTextContext
    ) -> (String, String.Index)? {
        var i = s.index(after: open)
        guard i < s.endIndex else { return nil }

        var negate = false
        if s[i] == "!" {
            negate = true
            i = s.index(after: i)
            guard i < s.endIndex else { return nil }
        }

        guard let (test, afterTest) = parseTest(s, from: i, context: context) else { return nil }
        i = afterTest

        // Up to two quoted strings, whitespace-separated.
        var strings: [String] = []
        while strings.count < 2 {
            skipSpaces(s, &i)
            guard i < s.endIndex else { return nil }
            if s[i] == "}" { break }
            guard s[i] == "\"", let (str, afterStr) = parseQuoted(s, from: i) else { return nil }
            strings.append(str)
            i = afterStr
        }

        skipSpaces(s, &i)
        guard i < s.endIndex, s[i] == "}" else { return nil }
        guard !strings.isEmpty else { return nil }

        let value = negate ? !test : test
        // "If there is no second string, nothing will be substituted."
        let replacement = value ? strings[0] : (strings.count > 1 ? strings[1] : "")
        return (replacement, s.index(after: i))
    }

    /// Parse the test token: `bXXX`, `G`, or `P` / `Pxxx`.
    private static func parseTest(
        _ s: String, from start: String.Index, context: NovaTextContext
    ) -> (Bool, String.Index)? {
        var i = start
        guard i < s.endIndex else { return nil }

        switch s[i] {
        case "b", "B":
            i = s.index(after: i)
            guard let (bitIndex, afterDigits) = parseDigits(s, from: i) else { return nil }
            return (context.isBitSet(bitIndex), afterDigits)

        case "G", "g":
            i = s.index(after: i)
            return (context.isMale, i)

        case "P", "p":
            i = s.index(after: i)
            // Optional day count: "registered at least xxx days ago".
            if let (days, afterDigits) = parseDigits(s, from: i) {
                return (context.isRegistered && context.daysRegistered >= days, afterDigits)
            }
            return (context.isRegistered, i)

        default:
            return nil
        }
    }

    private static func parseDigits(_ s: String, from start: String.Index) -> (Int, String.Index)? {
        var i = start
        var value = 0
        var any = false
        while i < s.endIndex, let d = s[i].wholeNumberValue, s[i].isNumber {
            value = value * 10 + d
            any = true
            i = s.index(after: i)
        }
        return any ? (value, i) : nil
    }

    /// Parse a `"…"` string, honoring C-style `\"` and `\\` escapes.
    private static func parseQuoted(_ s: String, from start: String.Index) -> (String, String.Index)? {
        var i = s.index(after: start)   // skip opening quote
        var out = ""
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                out.append(s[next])          // \" → ", \\ → \
                i = s.index(after: next)
                continue
            }
            if c == "\"" { return (out, s.index(after: i)) }
            out.append(c)
            i = s.index(after: i)
        }
        return nil   // unterminated
    }

    private static func skipSpaces(_ s: String, _ i: inout String.Index) {
        while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
    }
}
