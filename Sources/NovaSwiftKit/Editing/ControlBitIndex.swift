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
        computeReachability(collection)
    }

    private static func shortLabel(_ s: String) -> String {
        if let i = s.firstIndex(of: "(") { return s[..<i].trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// Growing fixpoint: a mission/cron is reachable when it has no non-negated
    /// bit tests, or at least one tested bit is live, or a reachable resource
    /// starts it (`S`/`A`/`F`, përs link). A bit is live when any non-mission
    /// source (outfit, spöb, chär, …) or a reachable mission/cron can raise it.
    /// An over-approximation for `|`/`&` mixes (never reports a satisfiable mission).
    private mutating func computeReachability(_ c: ResourceCollection) {
        let gatedTypes: [FourCharCode] = [NovaType.mission, FourCharCode("crön")!]
        var candidates: [ResourceKey] = []
        for type in gatedTypes { for r in c.resources(of: type) { candidates.append(ResourceKey(r.type, r.id)) } }
        let candSet = Set(candidates)
        var reachable = Set<ResourceKey>()
        var live = Set<Int>()
        func needBits(_ k: ResourceKey) -> [Int] {
            (byResource[k] ?? []).filter { $0.isTest && !$0.negated && ($0.fieldKey == "availBits" || $0.fieldKey == "enableOn") }.map(\.bit)
        }
        // Bits raised by sources that are not gated missions/crons are live from the start.
        for (bit, rs) in byBit { if rs.contains(where: { $0.raises && !candSet.contains($0.key) }) { live.insert(bit) } }
        var changed = true
        while changed {
            changed = false
            for k in candidates where !reachable.contains(k) {
                let need = needBits(k)
                let ok = need.isEmpty || need.contains(where: live.contains)
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
