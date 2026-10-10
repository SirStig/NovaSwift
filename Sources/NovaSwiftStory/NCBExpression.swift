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
        // 0x00447f20: only an empty string is always true, and the raw first
        // character must open a test — a string starting with a space or a
        // line break is false.
        isAlwaysTrue = text.isEmpty
        hasValidStart = text.first.map { "bB(!pPgGoOeE".contains($0) } ?? true
        var prepared: [Character] = []
        var previous: Character?
        for ch in text {
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
    /// An op that only runs on some of an `R(…)` coin flips. Produced only by
    /// the static `NCBSet.parse`; `NCBSet.resolve` has already flipped the coin.
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

/// SET expressions, executed the way the original interpreter does
/// (`Mission_ExecuteMisnScriptEngine`, 0x00449370). It is a single pass over the
/// bytes, not a tokenizer:
///
/// - Every byte is upper-cased, so `k148` and `K148` are the same op.
/// - An opcode letter (`! A C D E F G H K L M N P Q S T U X Y ^`) arms a
///   pending command and zeroes the operand; `B` arms "set bit" only when
///   nothing is pending, so `!b12`/`^b12` keep their `!`/`^`.
/// - Digits accumulate the operand.
/// - Any other byte — space, parenthesis, an unknown letter, the terminating
///   NUL — executes the pending command. A second opcode before a delimiter
///   re-arms without executing: `S862S863` runs only `S863`.
/// - `R` flips a coin. On 0 the byte right after it (normally `(`) is a
///   delimiter that skips the following byte, so the first op loses its opcode
///   and does nothing; on 1 the delimiter ending the second op is swallowed.
///   Spacing therefore matters, exactly as in the original: `R( g1 g2)` can run
///   both ops, and a lone `R(b5)` that fires leaves the *next* op suppressed.
/// - Each command ignores operands outside its resource range.
public enum NCBSet {
    /// The ops this expression executes, in order, with each `R`'s coin flip
    /// (0 or 1) drawn from `pick`.
    public static func resolve(_ text: String, pick: () -> Int) -> [NCBSetOp] {
        run(text, pick: pick).map(\.op)
    }

    /// Every op the expression *can* execute, for static analysis. Ops that only
    /// run on some coin flips are wrapped in `.random`. Covers each `R` taken
    /// both ways (all-0 and all-1 flips), which reaches every op of a well-formed
    /// `R(a b)`.
    public static func parse(_ text: String) -> [NCBSetOp] {
        let heads = run(text, pick: { 0 }), tails = run(text, pick: { 1 })
        let both = Set(heads.map(\.offset)).intersection(tails.map(\.offset))
        var seen = Set<Int>()
        return (heads + tails).sorted { $0.offset < $1.offset }.compactMap { entry in
            guard seen.insert(entry.offset).inserted else { return nil }
            return both.contains(entry.offset) ? entry.op : .random([entry.op])
        }
    }

    /// Every control bit this SET expression can write, and how — the SET-side
    /// counterpart of `NCBTest.referencedBits`, for building "what changes this
    /// bit" indexes.
    ///
    /// Includes writes that only happen on some `R` coin flips: anything asking
    /// "what could turn this on" has to count them, or a bit that's only ever
    /// set inside a random choice looks like nothing sets it at all.
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

    private static let opcodes = Set("!ACDEFGHKLMNPQSTUXY^".utf8)
    private static let idle = UInt8(ascii: "?")
    private static let setBitCommand = UInt8(ascii: " ")

    /// The interpreter loop. `offset` is the byte that armed each op, so the two
    /// coin-flip passes in `parse` can be lined up.
    private static func run(_ text: String, pick: () -> Int) -> [(offset: Int, op: NCBSetOp)] {
        let bytes = Array(text.utf8) + [0]
        var out: [(offset: Int, op: NCBSetOp)] = []
        var command = idle
        var armedAt = 0
        var operand: Int32 = 0
        var randomPick = -1, randomIndex = 0
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            let upper = (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
            var execute = false
            if opcodes.contains(upper) {
                operand = 0
                command = upper
                armedAt = i
            } else if upper == UInt8(ascii: "B") {
                operand = 0
                if command == idle { command = setBitCommand; armedAt = i }
            } else if upper == UInt8(ascii: "R") {
                randomIndex = 0
                command = idle
                randomPick = pick() == 0 ? 0 : 1
            } else if (0x30...0x39).contains(byte) {
                operand = operand &* 10 &+ Int32(byte - 0x30)
            } else if randomPick == -1 || randomIndex != randomPick {
                execute = true
            } else {
                if randomIndex == 0 { i += 1 } else { randomIndex += 1 }
                randomPick = -1
                command = idle
            }
            if execute, command != idle {
                // The original stores the operand in a 16-bit short.
                if let op = makeOp(command, Int(Int16(truncatingIfNeeded: operand))) {
                    out.append((armedAt, op))
                }
                command = idle
                randomIndex += 1
            }
            i += 1
        }
        return out
    }

    private static func makeOp(_ command: UInt8, _ v: Int) -> NCBSetOp? {
        let mission = 128...1127, ship = 128...895, outfit = 128...639
        let rank = 128...255, systemOrStellar = 128...2175, bit = 0...9999
        switch Character(Unicode.Scalar(command)) {
        case " ": return bit.contains(v) ? .setBit(v) : nil
        case "!": return bit.contains(v) ? .clearBit(v) : nil
        case "^": return bit.contains(v) ? .toggleBit(v) : nil
        case "S": return mission.contains(v) ? .startMission(v) : nil
        case "A": return mission.contains(v) ? .abortMission(v) : nil
        case "F": return mission.contains(v) ? .failMission(v) : nil
        case "G": return outfit.contains(v) ? .grantOutfit(v) : nil
        case "D": return outfit.contains(v) ? .removeOutfit(v) : nil
        case "C": return ship.contains(v) ? .changeShip(v, .keepOutfits) : nil
        case "E": return ship.contains(v) ? .changeShip(v, .addDefaultOutfits) : nil
        case "H": return ship.contains(v) ? .changeShip(v, .defaultOutfits) : nil
        case "K": return rank.contains(v) ? .activateRank(v) : nil
        case "L": return rank.contains(v) ? .deactivateRank(v) : nil
        case "M": return systemOrStellar.contains(v) ? .moveToSystem(v, keepPosition: false) : nil
        case "N": return systemOrStellar.contains(v) ? .moveToSystem(v, keepPosition: true) : nil
        case "Y": return systemOrStellar.contains(v) ? .destroyStellar(v) : nil
        case "U": return systemOrStellar.contains(v) ? .regenerateStellar(v) : nil
        case "X": return systemOrStellar.contains(v) ? .exploreSystem(v) : nil
        case "P": return .playSound(v)
        case "T": return .changeShipTitle(v)
        case "Q": return .leaveStellar(messageStr: v == 0 ? nil : v)
        default:  return nil
        }
    }
}
