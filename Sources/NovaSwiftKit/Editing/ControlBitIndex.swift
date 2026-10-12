import Foundation

/// Cross-reference of every control bit (0–9999) in a `ResourceCollection`:
/// which resources **test** it (every schema NCB test field, plus `{bNNN …}`
/// conditionals inside `dësc` text) and which **set / clear / toggle** it
/// (every NCB set field). Pure data, no UI; drives the editor's Story & Bits
/// tool (bit index, mission flow graph, dead-gate detection, free-bit finder).
public struct ControlBitIndex: Sendable {

    public enum Role: String, Sendable, Hashable { case test, set, clear, toggle }

    public struct Reference: Hashable, Sendable, Identifiable {
        public let bit: Int
        public let key: ResourceKey
        /// Schema field key (`availBits`, `onSuccess`, …) or `"text"` for desc markup.
        public let fieldKey: String
        public let fieldLabel: String
        public let role: Role
        /// Tests only: written `!bNNN` (needs the bit **clear**).
        public let negated: Bool
        public var id: String { "\(bit)/\(key.type.rawValue)/\(key.id)/\(fieldKey)/\(role.rawValue)" }
        public var isTest: Bool { role == .test }
        /// Set or toggle: can make a bit become true.
        public var raises: Bool { role == .set || role == .toggle }
    }

    public enum Status: String, Sendable, Hashable {
        case ok
        case setNeverTested
        case testedNeverSet
        /// Tested, and every setter is itself an unreachable mission/cron.
        case onlySetByUnreachable
    }

    public private(set) var byBit: [Int: [Reference]] = [:]
    public private(set) var byResource: [ResourceKey: [Reference]] = [:]
    /// Bits referenced by something the plug-in layer touched.
    public private(set) var pluginTouchedBits: Set<Int> = []
    /// Missions/crons that cannot become available (see `init`).
    public private(set) var unreachable: Set<ResourceKey> = []
    /// Bits some reachable source can raise.
    public private(set) var liveBits: Set<Int> = []
    /// Missions started by an `S`/`A`/`F` NCB operator: target → starters.
    public private(set) var startedBy: [ResourceKey: [ResourceKey]] = [:]

    public static let bitRange = 0...NCBSyntax.maxBit

    public var usedBits: [Int] { byBit.keys.sorted() }

    public func references(bit: Int) -> [Reference] { byBit[bit] ?? [] }
    public func testers(of bit: Int) -> [Reference] { (byBit[bit] ?? []).filter(\.isTest) }
    /// Everything that writes the bit (set, clear or toggle).
    public func writers(of bit: Int) -> [Reference] { (byBit[bit] ?? []).filter { !$0.isTest } }
    public func references(of key: ResourceKey) -> [Reference] { byResource[key] ?? [] }

    public func status(of bit: Int) -> Status {
        let refs = byBit[bit] ?? []
        let tests = refs.filter(\.isTest)
        let raisers = refs.filter(\.raises)
        let writers = refs.filter { !$0.isTest }
        if tests.isEmpty { return writers.isEmpty ? .ok : .setNeverTested }
        // Only a non-negated test can be starved of a setter.
        guard tests.contains(where: { !$0.negated }) else { return .ok }
        if raisers.isEmpty { return .testedNeverSet }
        if !liveBits.contains(bit) { return .onlySetByUnreachable }
        return .ok
    }

    // MARK: Building

    /// `touched`: keys the plug-in layer owns (highlighting only).
    public init(_ collection: ResourceCollection, touched: Set<ResourceKey> = []) {
        var refs: [Reference] = []
        var starters: [ResourceKey: [ResourceKey]] = [:]
        var gates: [ResourceKey: String] = [:]
        let descType = FourCharCode("dësc")!
        let persType = FourCharCode("përs")!

        for schema in ResourceSchemas.all {
            let ncbFields = schema.fields.compactMap { f -> (SchemaField, NCBKind)? in
                if case let .ncb(kind, _) = f.kind { return (f, kind) }
                return nil
            }
            if ncbFields.isEmpty && schema.type != persType { continue }
            for r in collection.resources(of: schema.type) {
                let key = ResourceKey(r.type, r.id)
                let data = schema.padded(r.data)
                for (f, kind) in ncbFields {
                    guard case let .string(text) = FieldCodec.read(f, from: data), !text.isEmpty else { continue }
                    if kind == .test {
                        if f.key == "availBits" || f.key == "enableOn" { gates[key] = text }
                        for t in Self.testBits(in: text) {
                            refs.append(Reference(bit: t.bit, key: key, fieldKey: f.key, fieldLabel: Self.shortLabel(f.label),
                                                  role: .test, negated: t.negated))
                        }
                    } else {
                        for op in NCBSyntax.operands(set: text) {
                            if let res = op.resource {
                                if res.type == NovaType.mission, "SAF".contains(op.letter) {
                                    starters[res, default: []].append(key)
                                }
                                continue
                            }
                            guard Self.bitRange.contains(op.value) else { continue }
                            let role: Role = op.letter == "!" ? .clear : op.letter == "^" ? .toggle : .set
                            refs.append(Reference(bit: op.value, key: key, fieldKey: f.key, fieldLabel: Self.shortLabel(f.label),
                                                  role: role, negated: false))
                        }
                    }
                }
                if schema.type == persType,
                   case let .int(m)? = schema.read("linkMission", from: data), m >= 128 {
                    starters[ResourceKey(NovaType.mission, m), default: []].append(key)
                }
            }
        }
        // {bNNN "…" "…"} conditionals in desc text.
        for r in collection.resources(of: descType) {
            let key = ResourceKey(r.type, r.id)
            let text = DescRecord(r.data).text
            guard text.contains("{") else { continue }
            for t in Self.descBits(in: text) {
                refs.append(Reference(bit: t.bit, key: key, fieldKey: "text", fieldLabel: "Text conditional",
                                      role: .test, negated: t.negated))
            }
        }

        var byBit: [Int: [Reference]] = [:], byRes: [ResourceKey: [Reference]] = [:]
        var touchedBits = Set<Int>()
        for r in refs {
            byBit[r.bit, default: []].append(r)
            byRes[r.key, default: []].append(r)
            if touched.contains(r.key) { touchedBits.insert(r.bit) }
        }
        self.byBit = byBit
        self.byResource = byRes
        self.pluginTouchedBits = touchedBits
        self.startedBy = starters
        computeReachability(collection, gates: gates)
    }

    private static func shortLabel(_ s: String) -> String {
        if let i = s.firstIndex(of: "(") { return s[..<i].trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// Growing fixpoint over the *boolean structure* of each availability test.
    ///
    /// A mission/cron is reachable when its availability expression (`availBits` /
    /// `enableOn`) can evaluate true for some assignment of the bits that are able to
    /// be set, or a reachable resource starts it (`S`/`A`/`F`, përs link). A bit is
    /// live when any non-gated source (outfit, spöb, chär, …) or a reachable
    /// mission/cron can raise it. Bits start clear, so every bit can be false; it can
    /// additionally be true only once live. `o`/`e`/`p`/`g` operands are free (either
    /// value). The expression is evaluated with a port of the game's own test
    /// interpreter (`NCBProbe`), so `&`, `|`, `!`, parentheses and `[count]` groups
    /// behave exactly as at runtime, including the original's accumulator quirks.
    ///
    /// Still an over-approximation in time: each bit is treated independently, so a
    /// `b1 & !b1`-style contradiction is caught but "b1 is set by the same mission that
    /// also requires it clear" ordering is not.
    private mutating func computeReachability(_ c: ResourceCollection, gates: [ResourceKey: String]) {
        let gatedTypes: [FourCharCode] = [NovaType.mission, FourCharCode("crön")!]
        var candidates: [ResourceKey] = []
        for type in gatedTypes { for r in c.resources(of: type) { candidates.append(ResourceKey(r.type, r.id)) } }
        let candSet = Set(candidates)
        var reachable = Set<ResourceKey>()
        var live = Set<Int>()
        var probes: [ResourceKey: NCBProbe] = [:]
        for (k, text) in gates where candSet.contains(k) { probes[k] = NCBProbe(text) }
        // Bits raised by sources that are not gated missions/crons are live from the start.
        for (bit, rs) in byBit { if rs.contains(where: { $0.raises && !candSet.contains($0.key) }) { live.insert(bit) } }
        var changed = true
        while changed {
            changed = false
            for k in candidates where !reachable.contains(k) {
                let ok = (probes[k]?.isSatisfiable(canBeSet: { live.contains($0) }) ?? true)
                    || (startedBy[k] ?? []).contains(where: { !candSet.contains($0) || reachable.contains($0) })
                if ok {
                    reachable.insert(k); changed = true
                    for r in byResource[k] ?? [] where r.raises && live.insert(r.bit).inserted { changed = true }
                }
            }
        }
        unreachable = candSet.subtracting(reachable)
        liveBits = live
    }

    // MARK: Free bits

    /// Start bits of up to `limit` runs of `count` consecutive unreferenced bits.
    public func freeRuns(count: Int, from lower: Int = 0, limit: Int = 12) -> [Int] {
        guard count > 0 else { return [] }
        var out: [Int] = []
        var runStart = lower, run = 0
        var b = lower
        while b <= NCBSyntax.maxBit, out.count < limit {
            if byBit[b] == nil {
                if run == 0 { runStart = b }
                run += 1
                if run == count { out.append(runStart); run = 0; }
            } else { run = 0 }
            b += 1
        }
        return out
    }

    // MARK: Text scanners

    /// `bNNN` operands of a test expression (`!` directly before the `b` negates).
    public static func testBits(in text: String) -> [(bit: Int, negated: Bool)] {
        let chars = Array(text)
        var out: [(Int, Bool)] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "b" || chars[i] == "B" {
                var j = i + 1, v = 0, n = 0
                while j < chars.count, let a = chars[j].asciiValue, (48...57).contains(a), n < 6 { v = v * 10 + Int(a - 48); j += 1; n += 1 }
                if n > 0, v <= NCBSyntax.maxBit {
                    var k = i - 1
                    while k >= 0, chars[k] == " " { k -= 1 }
                    out.append((v, k >= 0 && chars[k] == "!"))
                }
                i = j
            } else { i += 1 }
        }
        return out
    }

    /// `{bNNN …}` / `{!bNNN …}` conditionals in desc text.
    public static func descBits(in text: String) -> [(bit: Int, negated: Bool)] {
        let chars = Array(text)
        var out: [(Int, Bool)] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var j = i + 1, neg = false
            while j < chars.count, chars[j] == " " || chars[j] == "!" { if chars[j] == "!" { neg = true }; j += 1 }
            if j < chars.count, chars[j] == "b" || chars[j] == "B" {
                j += 1
                var v = 0, n = 0
                while j < chars.count, let a = chars[j].asciiValue, (48...57).contains(a), n < 6 { v = v * 10 + Int(a - 48); j += 1; n += 1 }
                if n > 0, v <= NCBSyntax.maxBit { out.append((v, neg)) }
            }
            i = max(j, i + 1)
        }
        return out
    }

    /// EV Nova's `"Visible Name; TagN"` convention → storyline key ("Vellos").
    /// Same rule as `StorylineAnalyzer.storyTag` in NovaSwiftStory.
    public static func storylineKey(ofMissionName name: String) -> String? {
        guard let semi = name.lastIndex(of: ";") else { return nil }
        let tag = name[name.index(after: semi)...].trimmingCharacters(in: .whitespaces)
        let chars = Array(tag)
        var i = chars.count
        while i > 0, chars[i - 1].isNumber { i -= 1 }
        guard i < chars.count, i > 0 else { return nil }
        let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }
}

/// Author-written names/notes for control bits, stored in the plug-in as a JSON
/// resource the original game never loads (like `NSmd`, but kept on open).
public struct BitNotes: Codable, Sendable, Equatable {
    public struct Note: Codable, Sendable, Equatable {
        public var name: String
        public var note: String
        public init(name: String = "", note: String = "") { self.name = name; self.note = note }
        public var isEmpty: Bool { name.isEmpty && note.isEmpty }
    }
    public static let type = FourCharCode("NSbt")!
    public static let resourceID = 128

    public var bits: [String: Note] = [:]
    public init() {}

    public subscript(bit: Int) -> Note {
        get { bits[String(bit)] ?? Note() }
        set { if newValue.isEmpty { bits[String(bit)] = nil } else { bits[String(bit)] = newValue } }
    }
    public init(data: Data) { self = (try? JSONDecoder().decode(BitNotes.self, from: data)) ?? BitNotes() }
    public func encoded() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}


// MARK: - Static NCB test evaluation

/// Satisfiability of an NCB TEST expression, for the editor's reachability analysis.
///
/// This is a port of `NCBTest`'s interpreter (NovaSwiftStory, from the CE executable at
/// 0x447F20 / 0x449020: left-to-right `&`/`|` accumulator, `!`, nested `( )`, `[ ]`
/// counted groups and `= < >` comparisons) with the game-state context replaced by a
/// closure over abstract operands. NovaSwiftKit cannot depend on NovaSwiftStory, hence
/// the copy; keep the two in step. Satisfiability enumerates assignments of the operands
/// that have more than one feasible value (at most `maxFree`, else it answers "maybe").
struct NCBProbe: Sendable {
    enum Atom: Hashable, Sendable {
        case bit(Int)
        /// `o` outfit, `e` explored, `p` unregistered days, `g` gender (lower-cased letter).
        case other(Character, Int)
    }

    static let maxFree = 14

    private let chars: [Character]
    private let alwaysTrue: Bool
    private let hasValidStart: Bool
    /// Distinct operands in first-read order (token reads are value-independent).
    let atoms: [Atom]

    init(_ text: String) {
        alwaysTrue = text.isEmpty
        hasValidStart = text.first.map { "bB(!pPgGoOeE".contains($0) } ?? true
        var prepared: [Character] = []
        var previous: Character?
        for ch in text {
            if ch == "(", previous == "(" { prepared.append(" ") }
            prepared.append(ch)
            previous = ch
        }
        chars = prepared
        var seen: [Atom] = []
        var probe = Interpreter(chars: prepared, value: { a in
            if !seen.contains(a) { seen.append(a) }
            return false
        })
        var position = 0
        _ = probe.evaluate(&position)
        atoms = seen
    }

    /// The expression's value under `value` (operand → truth).
    func evaluate(_ value: @escaping (Atom) -> Bool) -> Bool {
        if alwaysTrue { return true }
        guard hasValidStart else { return false }
        var interpreter = Interpreter(chars: chars, value: value)
        var position = 0
        let result = interpreter.evaluate(&position)
        return !interpreter.failed && result == 1
    }

    /// Whether some assignment of the feasible operand values makes the test true.
    /// A bit can always be false (bits start clear) and can be true when `canBeSet`.
    func isSatisfiable(canBeSet: (Int) -> Bool) -> Bool {
        if alwaysTrue { return true }
        guard hasValidStart else { return false }
        var free: [Atom] = []
        for a in atoms {
            switch a {
            case .bit(let n): if canBeSet(n) { free.append(a) }
            case .other: free.append(a)
            }
        }
        if free.count > Self.maxFree { return true }
        var index: [Atom: Int] = [:]
        for (i, a) in free.enumerated() { index[a] = i }
        for mask in 0..<(1 << free.count) {
            let ok = evaluate { a in
                guard let i = index[a] else { return false }
                return (mask >> i) & 1 == 1
            }
            if ok { return true }
        }
        return false
    }

    private static func readNumber(_ chars: [Character], cursor: inout Int) -> Int {
        var value: Int16 = 0
        while cursor < chars.count, let digit = chars[cursor].asciiValue, (48...57).contains(digit) {
            value = value &* 10 &+ Int16(digit - 48)
            cursor += 1
        }
        return Int(value)
    }

    private struct Interpreter {
        let chars: [Character]
        let value: (Atom) -> Bool
        var number = 0
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
                case .number(let n):
                    number = n
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
            if let ascii = ch.asciiValue, (48...57).contains(ascii) {
                return .number(NCBProbe.readNumber(chars, cursor: &cursor))
            }
            cursor += 1
            if ch.asciiValue == nil, let first = ch.unicodeScalars.first,
               ("0"..."9").contains(first) {
                return .invalid
            }
            switch ch {
            case "&", "|":
                while cursor < chars.count, chars[cursor] == ch { cursor += 1 }
                return .symbol(ch)
            case "b", "B":
                let n = NCBProbe.readNumber(chars, cursor: &cursor)
                return .truth((0..<10_000).contains(n) && value(.bit(n)))
            case "o", "O": return .truth(value(.other("o", NCBProbe.readNumber(chars, cursor: &cursor))))
            case "e", "E": return .truth(value(.other("e", NCBProbe.readNumber(chars, cursor: &cursor))))
            case "p", "P": return .truth(value(.other("p", NCBProbe.readNumber(chars, cursor: &cursor))))
            case "g", "G": return .truth(value(.other("g", 0)))
            default: return .symbol(ch)
            }
        }
    }
}
