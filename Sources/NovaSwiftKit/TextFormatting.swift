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
    /// The player-visible form of an EV Nova resource name: the developer
    /// annotation after the **last** semicolon is dropped, together with any
    /// spaces and semicolons in front of it (`NameString_StripSubtitleSuffix`
    /// 0x004cd230, which scans from the end).
    ///
    ///     "Shuttle;Second-Hand - poor"  →  "Shuttle"
    ///     "Lightning; Wild Geese"       →  "Lightning"
    ///     "A;B;C"                       →  "A;B"
    ///     ";hidden"                     →  ""
    ///
    /// Names without a semicolon are returned unchanged. Leading spaces are
    /// kept, and a name that begins with its only semicolon becomes empty —
    /// both exactly as the original.
    var novaDisplayName: String {
        guard let semi = lastIndex(of: ";") else { return self }
        var end = semi
        while end > startIndex {
            let prev = index(before: end)
            guard self[prev] == " " || self[prev] == ";" else { break }
            end = prev
        }
        return String(self[startIndex..<end])
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
    ///
    /// The split follows `FUN_0046e6d0`: the **first** `\n` or `\N` starts
    /// line two, and every later escape is dropped (both characters), so
    /// `A\NB\nC` shows "A" over "BC". A backslash in the last position is
    /// literal text.
    var novaGridName: String {
        let (first, second) = novaGridLines
        return second.map { first + "\n" + $0 } ?? first
    }
    /// The two grid-tile lines (`FUN_0046e6d0`); the second is nil when the
    /// name has no `\n`/`\N` escape.
    var novaGridLines: (String, String?) {
        let chars = Array(self)
        var line1 = "", line2 = "", split = false
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "n" || chars[i + 1] == "N" {
                split = true
                i += 2
                continue
            }
            if split { line2.append(chars[i]) } else { line1.append(chars[i]) }
            i += 1
        }
        return (line1, split ? line2 : nil)
    }
    /// See `novaGridName`.
    var novaSingleLineName: String {
        replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
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
// gövt #186 ships as "Federation;hates Temmin Shard" — the annotation belongs in
// the designer's notes, not on the player's targeting readout or map legend.
extension GovtRes: NovaNamedResource {}

// MARK: - Grouped numbers

public enum NovaNumberFormat {
    /// `DrawContext_DrawGroupedUInt` 0x00465af0 — the number form the outfitter,
    /// shipyard, player info, plunder, cargo panel and payment window draw:
    /// "N" below 1,000 (negatives included), "N,NNN" below 1,000,000 (the low
    /// group zero-padded), and "N.NNM" from a million up with the two decimals
    /// **truncated** (`(v % 1e6) / 1e4`). No currency suffix: callers append
    /// their own STR# text (" cr", STR# 2002 #34).
    public static func grouped(_ v: Int) -> String {
        if v < 1000 { return "\(v)" }
        if v < 1_000_000 {
            return "\(v / 1000)," + String(format: "%03d", v % 1000)
        }
        return "\(v / 1_000_000)." + String(format: "%02d", (v % 1_000_000) / 10_000) + "M"
    }
}

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
