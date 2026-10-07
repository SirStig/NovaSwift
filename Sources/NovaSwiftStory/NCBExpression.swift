import Foundation

// Nova Control Bit (NCB) expressions — the scripting language that drives EV
// Nova's entire story layer. Two dialects, both stored as short strings inside
// mïsn / crön / përs resources:
//
//   • TEST expressions  gate availability, e.g.  "!(b511 | b515) & !b350"
//   • SET expressions   apply side effects,  e.g.  "b350 b6666 S781"
//
// TEST behavior recovered from the EV Nova CE Windows executable at 0x447F20,
// 0x448BE0, and 0x449020, including its cursor and accumulator quirks. SET
// grammar remains cross-checked against ResForge NovaTools. Bit references are
// case-insensitive. This file is pure logic (no game state), so it is trivially
// unit-testable. State access is provided via `NCBTestContext`; SET effects are
// handed back to the caller as a list of `NCBSetOp` to apply.

// MARK: - Test expressions

/// What a TEST expression can read. `PlayerState` conforms to this.
public protocol NCBTestContext {
    func isBitSet(_ n: Int) -> Bool
    func hasOutfit(_ id: Int) -> Bool
    func isSystemExplored(_ id: Int) -> Bool
    var playerIsMale: Bool { get }
    /// Days the player has been "unregistered" (shareware gauge). For a fully
    /// owned install this is 0, so `pNNN` ("unregistered at most N days") passes.
    var unregisteredDays: Int { get }
}

/// A parsed control-bit test, using the original evaluator's accumulator rules.
/// Parentheses group expressions; square brackets count true operands. Mixed
/// `&`/`|` deliberately do not use conventional operator precedence.
public struct NCBTest: Sendable {
    private let chars: [Character]
    public let source: String
    public let isAlwaysTrue: Bool
    private let hasValidStart: Bool

    public init(_ text: String) {
        source = text
        // Retain the public API's whitespace normalization. Original resource
        // strings normally have no leading whitespace.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isAlwaysTrue = trimmed.isEmpty
        hasValidStart = trimmed.first.map { "bB(!pPgGoOeE".contains($0) } ?? true
        var prepared: [Character] = []
        var previous: Character?
        for ch in trimmed {
            // 0x447F20 inserts a space between adjacent opening parentheses.
            if ch == "(", previous == "(" { prepared.append(" ") }
            prepared.append(ch)
            previous = ch
        }
        chars = prepared
    }

    public func evaluate(_ ctx: NCBTestContext) -> Bool {
        if isAlwaysTrue { return true }
        guard hasValidStart else { return false }
        // The original wrapper accepts only a result of exactly one, including
        // when the inner evaluator returns a count rather than a boolean.
        var interpreter = Interpreter(chars: chars, ctx: ctx)
        var position = 0
        let result = interpreter.evaluate(&position)
        return !interpreter.failed && result == 1
    }

    /// Syntactically referenced bits and their pending negation, including
    /// counted sets. Identifiers use the evaluator's number decoding. Polarity
    /// follows grouping and pending `!`; it does not simplify comparisons or
    /// account for operands skipped by the original evaluator's cursor quirks.
    public var referencedBits: [(bit: Int, negated: Bool)] {
        var out: [(Int, Bool)] = []
        var cursor = 0
        Self.collectBits(chars, cursor: &cursor, negated: false, into: &out)
        return out
    }

    private static func collectBits(_ chars: [Character], cursor: inout Int, negated: Bool, into out: inout [(Int, Bool)]) {
        var pendingNegation = false
        while cursor < chars.count {
            let ch = chars[cursor]
            cursor += 1
            switch ch {
            case "!": pendingNegation = true
            case "b", "B":
                out.append((readNumber(chars, cursor: &cursor), negated != pendingNegation))
                pendingNegation = false
            case "o", "O", "e", "E", "p", "P":
                _ = readNumber(chars, cursor: &cursor)
                pendingNegation = false
            case "g", "G": pendingNegation = false
            case "(", "[":
                collectBits(chars, cursor: &cursor, negated: negated != pendingNegation, into: &out)
                pendingNegation = false
            case ")", "]": return
            default: break
            }
        }
    }

    /// Original identifiers consume only adjacent ASCII digits and wrap as
    /// signed 16-bit values. Share this rule with explanation metadata.
    private static func readNumber(_ chars: [Character], cursor: inout Int) -> Int {
        var value: Int16 = 0
        while cursor < chars.count, let digit = chars[cursor].asciiValue, (48...57).contains(digit) {
            value = value &* 10 &+ Int16(digit - 48)
            cursor += 1
        }
        return Int(value)
    }

    // 0x449020 in the EV Nova CE Windows executable scans each group's end
    // before consuming tokens, then restores the caller's cursor to that
    // boundary. Keep the cursor behavior: simply building a conventional
    // expression tree loses counted-set quirks.
    private struct Interpreter {
        let chars: [Character]
        let ctx: NCBTestContext
        var number = 0
        /// Set when the input cannot be tokenized; the whole TEST fails closed.
        var failed = false

        private enum Token { case symbol(Character), truth(Bool), number(Int), invalid }

        mutating func evaluate(_ position: inout Int) -> Int {
            var opens = position < chars.count && "([".contains(chars[position]) ? 0 : 1
            var closes = 0
            var scan = position
            var end: Int?
            while scan < chars.count {
                let ch = chars[scan]
                if "([".contains(ch) { opens += 1 }
                if ")]".contains(ch) { closes += 1 }
                if opens == closes { end = scan - 1; break }
                scan += 1
            }
            let boundary = end ?? scan
            var cursor = position
            var recent = 0
            var accumulator = 1
            var count = 0
            var pendingNegation = false
            var op: Character = "?"
            loop: while cursor < chars.count {
                if chars[cursor] == " " { cursor += 1; continue }
                let before = cursor
                let token = nextToken(&cursor)
                // Every token must consume input. Fail closed rather than spin
                // if a malformed string ever stops the cursor advancing.
                if case .invalid = token { failed = true }
                guard !failed, cursor > before else {
                    failed = true
                    position = chars.count + 1
                    return 0
                }
                switch token {
                case .invalid: break
                case .truth(let raw):
                    let truth = raw != pendingNegation
                    pendingNegation = false
                    if truth {
                        count += 1
                        if op == "|" { accumulator = 1 }
                        recent = 1
                    } else {
                        if op == "&" { accumulator = 0 }
                        recent = 0
                    }
                case .number(let value):
                    number = value
                    switch op {
                    case "=": accumulator = recent == number ? 1 : 0
                    case "<": accumulator = recent < number ? 1 : 0
                    case ">": accumulator = recent > number ? 1 : 0
                    default: break
                    }
                case .symbol(let ch):
                    switch ch {
                    case "(", "[":
                        var result = evaluate(&cursor)
                        if pendingNegation { result = result == 0 ? 1 : 0 }
                        pendingNegation = false
                        if op == "&" {
                            accumulator = recent
                            if result == 0 { accumulator = 0; recent = 0 }
                        } else if op == "|" {
                            accumulator = recent
                            if result == 1 { accumulator = 1; recent = 1 }
                        } else {
                            recent = result
                        }
                    case "]": op = "+"; accumulator = count; break loop
                    case ")": break loop
                    case "!": pendingNegation = true
                    case "&", "|": op = ch; accumulator = recent
                    case "=", "<", ">": op = ch; accumulator = 0
                    default: break
                    }
                }
            }
            position = boundary + 2
            return op == "?" ? recent : accumulator
        }

        private mutating func nextToken(_ cursor: inout Int) -> Token {
            let ch = chars[cursor]
            // Match digits by ASCII value: a Character range like "0"..."9"
            // also matches grapheme clusters such as "1\u{FE0F}\u{20E3}", which
            // readNumber would then refuse to consume.
            if let ascii = ch.asciiValue, (48...57).contains(ascii) {
                return .number(NCBTest.readNumber(chars, cursor: &cursor))
            }
            cursor += 1
            // A digit-led cluster that is not a plain ASCII digit cannot occur
            // in the original single-byte strings; treat it as malformed.
            if ch.asciiValue == nil, let first = ch.unicodeScalars.first,
               ("0"..."9").contains(first) {
                return .invalid
            }
            switch ch {
            case "&", "|":
                while cursor < chars.count, chars[cursor] == ch { cursor += 1 }
                return .symbol(ch)
            case "b", "B":
                let n = NCBTest.readNumber(chars, cursor: &cursor)
                return .truth((0..<10_000).contains(n) && ctx.isBitSet(n))
            case "o", "O": return .truth(ctx.hasOutfit(NCBTest.readNumber(chars, cursor: &cursor)))
            case "e", "E": return .truth(ctx.isSystemExplored(NCBTest.readNumber(chars, cursor: &cursor)))
            case "p", "P": return .truth(ctx.unregisteredDays <= NCBTest.readNumber(chars, cursor: &cursor))
            case "g", "G": return .truth(ctx.playerIsMale)
            default: return .symbol(ch)
            }
        }
    }
}

// MARK: - Set expressions

/// One side-effect operation from a SET expression. The story engine applies
/// these — some mutate `PlayerState` directly (bits, missions, ranks, outfits),
/// others need the outside world and are forwarded to `GameServices`.
public enum NCBSetOp: Equatable, Sendable {
    case setBit(Int)
    case clearBit(Int)
    case toggleBit(Int)
    case startMission(Int)
    case abortMission(Int)
    case failMission(Int)
    case grantOutfit(Int)
    case removeOutfit(Int)
    case moveToSystem(Int, keepPosition: Bool)
    case changeShip(Int, ChangeShipMode)
    case activateRank(Int)
    case deactivateRank(Int)
    case playSound(Int)
    case destroyStellar(Int)
    case regenerateStellar(Int)
    case exploreSystem(Int)
    case changeShipTitle(Int)      // STR# id
    case leaveStellar(messageStr: Int?)
    /// A random 50/50 choice between one or two ops (EV Nova's `R(…)`). The
    /// engine picks one at apply time using its RNG.
    case random([NCBSetOp])
}

/// How a SET expression writes a control bit.
public enum NCBBitEffect: Equatable, Sendable { case set, clear, toggle }

/// Which outfits carry over when a SET expression swaps the player's ship.
public enum ChangeShipMode: Equatable, Sendable {
    case keepOutfits       // C
    case addDefaultOutfits // E
    case defaultOutfits    // H
}

/// Parses a SET expression into an ordered list of `NCBSetOp`.
///
/// SET expressions are whitespace-separated operations. Bit ops are lowercase
/// (`b350`, `!b363`, `^b12`); command ops are single uppercase letters followed
/// by a resource id (`S781` start mission, `G152` grant outfit, `K128` activate
/// rank, `Q25059` leave with message, `R(b1 b2)` random). Unknown tokens are
/// skipped rather than aborting the whole expression.
public enum NCBSet {
    public static func parse(_ text: String) -> [NCBSetOp] {
        var ops: [NCBSetOp] = []
        for token in tokenize(text) {
            if let op = parseToken(token) { ops.append(op) }
        }
        return ops
    }

    /// Every control bit this SET expression can write, and how — the SET-side
    /// counterpart of `NCBTest.referencedBits`, for building "what changes this
    /// bit" indexes.
    ///
    /// Recurses into `R( … )`. A random op only fires half the time, but it
    /// still *can* write the bit, so anything asking "what could turn this on"
    /// has to count it: dropping it makes a bit that's only ever set inside a
    /// random choice look like nothing sets it at all.
    public static func referencedBits(_ text: String) -> [(bit: Int, effect: NCBBitEffect)] {
        bitEffects(in: parse(text))
    }

    private static func bitEffects(in ops: [NCBSetOp]) -> [(bit: Int, effect: NCBBitEffect)] {
        var out: [(bit: Int, effect: NCBBitEffect)] = []
        for op in ops {
            switch op {
            case let .setBit(n): out.append((n, .set))
            case let .clearBit(n): out.append((n, .clear))
            case let .toggleBit(n): out.append((n, .toggle))
            case let .random(inner): out.append(contentsOf: bitEffects(in: inner))
            default: break
            }
        }
        return out
    }

    /// Split on whitespace, but keep `R( … )` (which contains spaces) together.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth = max(0, depth - 1) }
            if ch.isWhitespace && depth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func parseToken(_ token: String) -> NCBSetOp? {
        // Bit operations first (lowercase b, optionally prefixed by ! or ^).
        if token.hasPrefix("!b") || token.hasPrefix("!B") {
            return intSuffix(token, dropping: 2).map { .clearBit($0) }
        }
        if token.hasPrefix("^b") || token.hasPrefix("^B") {
            return intSuffix(token, dropping: 2).map { .toggleBit($0) }
        }
        if token.hasPrefix("b") || token.hasPrefix("B") {
            return intSuffix(token, dropping: 1).map { .setBit($0) }
        }

        guard let first = token.first else { return nil }
        // Random choice: R(op) or R(op op)
        if first == "R" || first == "r" {
            let inner = token.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let choices = parse(String(inner))
            return choices.isEmpty ? nil : .random(choices)
        }

        // Command ops: <Letter><id>. "Q" may appear bare (no id).
        let value = intSuffix(token, dropping: 1)
        switch first {
        case "S": return value.map { .startMission($0) }
        case "A": return value.map { .abortMission($0) }
        case "F": return value.map { .failMission($0) }
        case "G": return value.map { .grantOutfit($0) }
        case "D": return value.map { .removeOutfit($0) }
        case "M": return value.map { .moveToSystem($0, keepPosition: false) }
        case "N": return value.map { .moveToSystem($0, keepPosition: true) }
        case "C": return value.map { .changeShip($0, .keepOutfits) }
        case "E": return value.map { .changeShip($0, .addDefaultOutfits) }
        case "H": return value.map { .changeShip($0, .defaultOutfits) }
        case "K": return value.map { .activateRank($0) }
        case "L": return value.map { .deactivateRank($0) }
        case "P": return value.map { .playSound($0) }
        case "Y": return value.map { .destroyStellar($0) }
        case "U": return value.map { .regenerateStellar($0) }
        case "X": return value.map { .exploreSystem($0) }
        case "T": return value.map { .changeShipTitle($0) }
        case "Q": return .leaveStellar(messageStr: value)
        default:  return nil
        }
    }

    private static func intSuffix(_ token: String, dropping n: Int) -> Int? {
        Int(token.dropFirst(n))
    }
}
