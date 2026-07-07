import Foundation

// Nova Control Bit (NCB) expressions — the scripting language that drives EV
// Nova's entire story layer. Two dialects, both stored as short strings inside
// mïsn / crön / përs resources:
//
//   • TEST expressions  gate availability, e.g.  "!(b511 | b515) & !b350"
//   • SET expressions   apply side effects,  e.g.  "b350 b6666 S781"
//
// Grammar cross-checked against ResForge NovaTools' NCB parser (NCBTest.swift /
// NCBSet.swift). Operators are case-insensitive; bit references are lowercase
// `bNNN` in the real data. This file is pure logic — no game state — so it is
// trivially unit-testable. State access is provided via `NCBTestContext`;
// SET effects are handed back to the caller as a list of `NCBSetOp` to apply.

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

/// A parsed boolean control-bit test. Evaluate against any `NCBTestContext`.
///
/// Precedence (tightest first): `!`  >  `&`  >  `|`, with `(…)` grouping. This
/// is a superset of EV Nova's own grammar (which forbids mixing `&`/`|` at one
/// level without parentheses), so every real expression parses correctly.
public struct NCBTest: Sendable {
    fileprivate indirect enum Node: Sendable {
        case bit(Int)
        case outfit(Int)
        case explored(Int)
        case genderMale
        case unregisteredAtMost(Int)
        case constant(Bool)     // unknown operand → false (fail-closed)
        case not(Node)
        case and([Node])
        case or([Node])
    }

    fileprivate let root: Node
    /// The original source text (useful for debugging / editor display).
    public let source: String

    /// An empty expression is treated as "always true" (EV Nova's default — a
    /// mission with no AvailBits is unconditionally available).
    public var isAlwaysTrue: Bool {
        if case .constant(true) = root { return true }
        return false
    }

    public init(_ text: String) {
        source = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            root = .constant(true)
        } else {
            var parser = Parser(trimmed)
            root = parser.parseOr() ?? .constant(true)
        }
    }

    public func evaluate(_ ctx: NCBTestContext) -> Bool {
        Self.eval(root, ctx)
    }

    private static func eval(_ node: Node, _ ctx: NCBTestContext) -> Bool {
        switch node {
        case .bit(let n):                return ctx.isBitSet(n)
        case .outfit(let id):            return ctx.hasOutfit(id)
        case .explored(let id):          return ctx.isSystemExplored(id)
        case .genderMale:                return ctx.playerIsMale
        case .unregisteredAtMost(let n): return ctx.unregisteredDays <= n
        case .constant(let b):           return b
        case .not(let inner):            return !eval(inner, ctx)
        case .and(let nodes):            return nodes.allSatisfy { eval($0, ctx) }
        case .or(let nodes):             return nodes.contains { eval($0, ctx) }
        }
    }

    // MARK: Recursive-descent parser

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skipWS() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func parseOr() -> Node? {
            guard var left = parseAnd() else { return nil }
            var terms = [left]
            skipWS()
            while peek() == "|" {
                i += 1
                guard let rhs = parseAnd() else { break }
                terms.append(rhs)
                skipWS()
            }
            if terms.count > 1 { left = .or(terms) }
            return left
        }

        mutating func parseAnd() -> Node? {
            guard let first = parseNot() else { return nil }
            var terms = [first]
            skipWS()
            while peek() == "&" {
                i += 1
                guard let rhs = parseNot() else { break }
                terms.append(rhs)
                skipWS()
            }
            return terms.count > 1 ? .and(terms) : first
        }

        mutating func parseNot() -> Node? {
            skipWS()
            if peek() == "!" {
                i += 1
                guard let inner = parseNot() else { return nil }
                return .not(inner)
            }
            return parseAtom()
        }

        mutating func parseAtom() -> Node? {
            skipWS()
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                let inner = parseOr()
                skipWS()
                if peek() == ")" { i += 1 }   // tolerate the odd unbalanced paren
                return inner ?? .constant(true)
            }
            return parseOperand()
        }

        mutating func parseOperand() -> Node? {
            skipWS()
            guard let c = peek() else { return nil }
            let letter = Character(c.lowercased())
            i += 1
            let value = parseInt()
            switch letter {
            case "b": return .bit(value ?? 0)
            case "o": return .outfit(value ?? 0)
            case "e": return .explored(value ?? 0)
            case "p": return .unregisteredAtMost(value ?? 0)
            case "g": return .genderMale
            default:
                // Unknown operand type: consume it and fail closed.
                return .constant(false)
            }
        }

        mutating func parseInt() -> Int? {
            skipWS()
            var digits = ""
            if peek() == "-" { digits.append("-"); i += 1 }
            while let c = peek(), c.isNumber { digits.append(c); i += 1 }
            return Int(digits)
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
