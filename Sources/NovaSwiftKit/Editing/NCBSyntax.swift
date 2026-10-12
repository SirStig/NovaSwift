import Foundation

/// Static syntax checking and reference extraction for Nova control-bit (NCB)
/// expressions. The runtime interpreter lives in `NovaSwiftStory` (not a
/// dependency of this module), so this is a small independent checker built
/// from the Nova Bible and the interpreter's documented quirks: it finds what
/// the game would silently ignore or misread, and lists the resources an
/// expression touches (for the reference graph and renumbering).
public enum NCBSyntax {

    public struct Issue: Sendable, Hashable {
        public enum Severity: Sendable { case error, warning }
        public let severity: Severity
        public let message: String
        /// Character offset in the expression.
        public let offset: Int
    }

    /// One resource-bearing operand, e.g. `S781` → mission 781.
    public struct Operand: Sendable, Hashable {
        public let letter: Character
        public let value: Int
        /// Offset of the first digit and digit count, for rewriting.
        public let digitStart: Int
        public let digitCount: Int
        /// The resource it names, when the operator names one.
        public let resource: ResourceKey?
    }

    public static let maxBit = 9999

    // MARK: Operators

    /// SET operators that name a resource, and the type they name.
    static let setResourceOps: [Character: FourCharCode] = [
        "S": NovaType.mission, "A": NovaType.mission, "F": NovaType.mission,
        "G": NovaType.outfit, "D": NovaType.outfit,
        "C": NovaType.ship, "E": NovaType.ship, "H": NovaType.ship,
        "K": NovaType.rank, "L": NovaType.rank,
        "M": NovaType.syst, "N": NovaType.syst, "X": NovaType.syst,
        "Y": NovaType.spob, "U": NovaType.spob,
        "P": NovaType.snd, "T": NovaType.strList,
    ]
    /// Valid operand ranges (the interpreter ignores operands outside them).
    static let setRanges: [Character: ClosedRange<Int>] = [
        "S": 128...1127, "A": 128...1127, "F": 128...1127, "G": 128...639, "D": 128...639,
        "C": 128...895, "E": 128...895, "H": 128...895, "K": 128...255, "L": 128...255,
        "M": 128...2175, "N": 128...2175, "X": 128...2175, "Y": 128...2175, "U": 128...2175,
    ]
    private static let setOpcodes = Set("!ACDEFGHKLMNPQSTUXY^")

    // MARK: SET expressions

    /// Walks a SET expression the way the interpreter does: opcode letters arm a
    /// command, digits accumulate, any other byte executes it.
    private static func scanSet(_ text: String) -> (operands: [Operand], issues: [Issue]) {
        let chars = Array(text)
        var operands: [Operand] = []
        var issues: [Issue] = []
        var command: Character?
        var digitStart = 0, digitCount = 0, value = 0, commandAt = 0
        var armedUnexecuted = false

        func execute() {
            guard let c = command else { return }
            let op = Operand(letter: c, value: Int(Int16(truncatingIfNeeded: value)), digitStart: digitStart,
                             digitCount: digitCount, resource: nil)
            if digitCount == 0, c != "Q" {
                issues.append(Issue(severity: .warning, message: "“\(c)” has no number after it", offset: commandAt))
            }
            if let range = setRanges[c], digitCount > 0, !range.contains(op.value) {
                issues.append(Issue(severity: .warning,
                                    message: "\(c)\(op.value) is outside \(range.lowerBound)–\(range.upperBound); the game ignores it",
                                    offset: commandAt))
            }
            if c == " " || c == "!" || c == "^", digitCount > 0, !(0...maxBit).contains(op.value) {
                issues.append(Issue(severity: .warning, message: "Control bit \(op.value) is outside 0–\(maxBit)", offset: commandAt))
            }
            if let t = setResourceOps[c], digitCount > 0 {
                operands.append(Operand(letter: c, value: op.value, digitStart: digitStart, digitCount: digitCount,
                                        resource: ResourceKey(t, op.value)))
            } else if c == " " || c == "!" || c == "^" {
                operands.append(Operand(letter: c, value: op.value, digitStart: digitStart, digitCount: digitCount, resource: nil))
            }
            command = nil; armedUnexecuted = false
        }

        var i = 0
        var parenDepth = 0
        while i < chars.count {
            let ch = chars[i]
            let up = Character(ch.uppercased())
            if setOpcodes.contains(up) {
                if armedUnexecuted, digitCount > 0 {
                    issues.append(Issue(severity: .warning,
                                        message: "Operators must be separated by a space: only the last of “\(chars[commandAt])…\(up)” runs",
                                        offset: i))
                }
                command = up; commandAt = i; value = 0; digitCount = 0; digitStart = i + 1; armedUnexecuted = true
            } else if up == "B" {
                if command == nil { command = " "; commandAt = i; armedUnexecuted = true }
                value = 0; digitCount = 0; digitStart = i + 1
            } else if up == "R" {
                command = nil; armedUnexecuted = false
            } else if let a = ch.asciiValue, (48...57).contains(a) {
                if command == nil {
                    issues.append(Issue(severity: .warning, message: "A number with no operator before it is ignored", offset: i))
                    while i + 1 < chars.count, let n = chars[i + 1].asciiValue, (48...57).contains(n) { i += 1 }
                } else {
                    if digitCount == 0 { digitStart = i }
                    value = value &* 10 &+ Int(a - 48); digitCount += 1
                }
            } else {
                if ch == "(" { parenDepth += 1 }
                if ch == ")" { parenDepth -= 1 }
                if !(ch == " " || ch == "(" || ch == ")" || ch == "\t" || ch == "\r" || ch == "\n") {
                    issues.append(Issue(severity: .warning, message: "“\(ch)” isn't a set operator; the game ignores it", offset: i))
                }
                execute()
            }
            i += 1
        }
        execute()
        if parenDepth != 0 {
            issues.append(Issue(severity: .warning, message: "Unbalanced parentheses after R", offset: max(0, chars.count - 1)))
        }
        return (operands, issues)
    }

    public static func checkSet(_ text: String) -> [Issue] { scanSet(text).issues }
    public static func operands(set text: String) -> [Operand] { scanSet(text).operands }

    // MARK: TEST expressions

    private static func scanTest(_ text: String) -> (operands: [Operand], issues: [Issue]) {
        let chars = Array(text)
        var operands: [Operand] = []
        var issues: [Issue] = []
        func err(_ m: String, _ o: Int) { issues.append(Issue(severity: .error, message: m, offset: o)) }
        func warn(_ m: String, _ o: Int) { issues.append(Issue(severity: .warning, message: m, offset: o)) }

        if let first = chars.first, !"bB(!pPgGoOeE[".contains(first) {
            err("A test expression must start with b, o, e, p, g, !, ( or [; this one always evaluates to false", 0)
        }
        // Per-group state: did the last token complete an operand, and which
        // binary operators appeared (mixing them is order-dependent).
        struct Group { var needOperand = true; var ops = Set<Character>(); var open: Character? }
        var stack = [Group()]
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let up = Character(ch.uppercased())
            func readDigits() -> (start: Int, count: Int, value: Int) {
                let s = i + 1; var j = s; var v = 0
                while j < chars.count, let a = chars[j].asciiValue, (48...57).contains(a) { v = v &* 10 &+ Int(a - 48); j += 1 }
                i = j - 1
                return (s, j - s, v)
            }
            switch up {
            case " ", "\t", "\r", "\n": break
            case "B", "O", "E", "P":
                let d = readDigits()
                if d.count == 0 && up != "P" { err("“\(ch)” needs a number (e.g. \(ch)12)", i) }
                if up == "B", d.count > 0, d.value > maxBit { err("Control bit \(d.value) is outside 0–\(maxBit)", d.start) }
                if up == "O" || up == "E", d.count > 0 {
                    operands.append(Operand(letter: up, value: d.value, digitStart: d.start, digitCount: d.count,
                                            resource: ResourceKey(up == "O" ? NovaType.outfit : NovaType.syst, d.value)))
                }
                if stack[stack.count - 1].needOperand == false {
                    warn("Missing & or | before “\(ch)”", i)
                }
                stack[stack.count - 1].needOperand = false
            case "G":
                if stack[stack.count - 1].needOperand == false { warn("Missing & or | before “\(ch)”", i) }
                stack[stack.count - 1].needOperand = false
            case "!":
                break
            case "&", "|":
                if stack[stack.count - 1].needOperand { err("“\(ch)” needs something before it", i) }
                stack[stack.count - 1].needOperand = true
                stack[stack.count - 1].ops.insert(ch)
                if stack[stack.count - 1].ops.count > 1 {
                    warn("Mixing & and | without parentheses gives unpredictable results; group with ( )", i)
                    stack[stack.count - 1].ops = [ch]
                }
            case "=", "<", ">":
                stack[stack.count - 1].needOperand = true
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                while i + 1 < chars.count, let a = chars[i + 1].asciiValue, (48...57).contains(a) { i += 1 }
                stack[stack.count - 1].needOperand = false
            case "(", "[":
                if stack[stack.count - 1].needOperand == false { warn("Missing & or | before “\(ch)”", i) }
                stack.append(Group(open: ch))
            case ")", "]":
                if stack.count == 1 { err("Unmatched “\(ch)”", i) } else {
                    let g = stack.removeLast()
                    if g.needOperand && g.ops.isEmpty == false { err("Expression ends with an operator before “\(ch)”", i) }
                    if (g.open == "(") != (ch == ")") { err("Mismatched brackets: “\(g.open!)” closed by “\(ch)”", i) }
                    stack[stack.count - 1].needOperand = false
                }
            default:
                warn("“\(ch)” isn't part of the test language; the game ignores it", i)
            }
            i += 1
        }
        if stack.count > 1 { err("Missing closing bracket", chars.count - 1) }
        if let g = stack.first, g.needOperand, !g.ops.isEmpty { err("Expression ends with an operator", max(0, chars.count - 1)) }
        return (operands, issues)
    }

    public static func checkTest(_ text: String) -> [Issue] { scanTest(text).issues }
    public static func operands(test text: String) -> [Operand] { scanTest(text).operands }

    public static func check(_ text: String, kind: NCBKind) -> [Issue] {
        kind == .test ? checkTest(text) : checkSet(text)
    }
    public static func operands(_ text: String, kind: NCBKind) -> [Operand] {
        kind == .test ? operands(test: text) : operands(set: text)
    }

    /// Rewrites the numbers of resource operands (renumbering support). `map`
    /// returns the new id for a (type, old id), or nil to leave it.
    public static func rewrite(_ text: String, kind: NCBKind, map: (FourCharCode, Int) -> Int?) -> String {
        var chars = Array(text)
        let ops = operands(text, kind: kind).filter { $0.resource != nil }.sorted { $0.digitStart > $1.digitStart }
        for op in ops {
            guard let r = op.resource, let new = map(r.type, r.id) else { continue }
            chars.replaceSubrange(op.digitStart..<(op.digitStart + op.digitCount), with: Array(String(new)))
        }
        return String(chars)
    }
}
