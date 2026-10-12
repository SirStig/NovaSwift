import Foundation

/// Mission/cron flow graph built from a `ControlBitIndex`: an edge A → B means
/// "A sets bit b which B's availability tests" (or A starts B with an `S`/`A`/`F`
/// operator). Includes a layered ("Sugiyama-lite") layout so the editor can draw
/// the whole base game (~1500 nodes) from a single off-main computation.
public struct StoryGraph: Sendable {

    public struct Node: Sendable, Identifiable {
        public var id: Int
        public let key: ResourceKey
        public let name: String
        public let storyline: String?
        public let govt: Int?
        public let touched: Bool
        public let unreachable: Bool
        /// Raises bits that nothing tests and has no outgoing edges.
        public let deadEnd: Bool
        public var x: Float = 0
        public var y: Float = 0
        public var layer: Int = 0
        public var component: Int = 0
        public var isolated = false
        public var isCron: Bool { key.type != NovaType.mission }
    }

    public enum EdgeKind: Sendable { case enables, disables, starts }

    public struct Edge: Sendable {
        public let from: Int
        public let to: Int
        public let bit: Int
        public let kind: EdgeKind
        public let field: String
    }

    public private(set) var nodes: [Node] = []
    public private(set) var edges: [Edge] = []
    public private(set) var indexByKey: [ResourceKey: Int] = [:]
    public private(set) var outgoing: [[Int]] = []   // node → edge indices
    public private(set) var incoming: [[Int]] = []
    /// Bits whose setter×tester fan-out exceeds `hubThreshold`; their edges are not drawn.
    public private(set) var hubBits: Set<Int> = []
    public private(set) var componentCount = 0
    public private(set) var bounds: (width: Float, height: Float) = (0, 0)

    public static let hubThreshold = 150
    public static let xGap: Float = 230
    public static let yGap: Float = 54

    public init() {}

    public func edgesTouching(_ node: Int) -> [Edge] { (outgoing[node] + incoming[node]).map { edges[$0] } }

    /// Nodes in the connected component of `node` (over drawn edges).
    public func component(of node: Int) -> [Int] {
        let c = nodes[node].component
        return nodes.indices.filter { nodes[$0].component == c }
    }

    public init(collection: ResourceCollection, index: ControlBitIndex, touched: Set<ResourceKey>) {
        let cronType = FourCharCode("crön")!
        let schemaM = ResourceSchemas.schema(for: NovaType.mission)
        // Nodes.
        for type in [NovaType.mission, cronType] {
            for r in collection.resources(of: type) {
                let key = ResourceKey(type, r.id)
                var govt: Int?
                if type == NovaType.mission, case let .int(g)? = schemaM?.read("compGovt", from: schemaM!.padded(r.data)), g >= 128 { govt = g }
                let refs = index.references(of: key)
                let raised = refs.filter(\.raises)
                nodes.append(Node(id: nodes.count, key: key, name: r.name,
                                  storyline: type == NovaType.mission ? ControlBitIndex.storylineKey(ofMissionName: r.name) : nil,
                                  govt: govt, touched: touched.contains(key), unreachable: index.unreachable.contains(key),
                                  deadEnd: !raised.isEmpty && raised.allSatisfy { index.testers(of: $0.bit).isEmpty }))
                indexByKey[key] = nodes.count - 1
            }
        }
        // Edges via bits.
        var seen = Set<[Int]>()
        func add(_ f: Int, _ t: Int, _ bit: Int, _ kind: EdgeKind, _ field: String) {
            guard f != t else { return }
            let sig = [f, t, bit, kind == .enables ? 0 : kind == .disables ? 1 : 2]
            if seen.insert(sig).inserted { edges.append(Edge(from: f, to: t, bit: bit, kind: kind, field: field)) }
        }
        for bit in index.usedBits {
            let refs = index.references(bit: bit)
            let srcs = refs.filter { !$0.isTest && indexByKey[$0.key] != nil }
            let dsts = refs.filter { $0.isTest && ($0.fieldKey == "availBits" || $0.fieldKey == "enableOn") && indexByKey[$0.key] != nil }
            if srcs.isEmpty || dsts.isEmpty { continue }
            if srcs.count * dsts.count > Self.hubThreshold { hubBits.insert(bit); continue }
            for s in srcs {
                for d in dsts {
                    if s.role == .clear {
                        if d.negated { add(indexByKey[s.key]!, indexByKey[d.key]!, bit, .disables, s.fieldLabel) }
                    } else if !d.negated {
                        add(indexByKey[s.key]!, indexByKey[d.key]!, bit, .enables, s.fieldLabel)
                    }
                }
            }
        }
        for (target, starters) in index.startedBy {
            guard let t = indexByKey[target] else { continue }
            for s in starters { if let f = indexByKey[s] { add(f, t, -1, .starts, "Starts") } }
        }
        outgoing = Array(repeating: [], count: nodes.count)
        incoming = Array(repeating: [], count: nodes.count)
        for (i, e) in edges.enumerated() { outgoing[e.from].append(i); incoming[e.to].append(i) }
        layout()
    }

    // MARK: Layout

    private mutating func layout() {
        let n = nodes.count
        guard n > 0 else { return }
        // Components (union-find).
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for e in edges { let a = find(e.from), b = find(e.to); if a != b { parent[a] = b } }
        var compMembers: [Int: [Int]] = [:]
        for i in 0..<n where !(outgoing[i].isEmpty && incoming[i].isEmpty) { compMembers[find(i), default: []].append(i) }
        for i in 0..<n where outgoing[i].isEmpty && incoming[i].isEmpty { nodes[i].isolated = true }

        // Break cycles: iterative DFS, back edges ignored for layering.
        var state = [UInt8](repeating: 0, count: n)   // 0 new, 1 open, 2 done
        var dagOut = [[Int]](repeating: [], count: n)
        var indeg = [Int](repeating: 0, count: n)
        for root in 0..<n where state[root] == 0 {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while !stack.isEmpty {
                let (v, k) = stack[stack.count - 1]
                if k < outgoing[v].count {
                    stack[stack.count - 1].next += 1
                    let to = edges[outgoing[v][k]].to
                    if state[to] == 1 { continue }          // back edge
                    dagOut[v].append(to); indeg[to] += 1
                    if state[to] == 0 { state[to] = 1; stack.append((to, 0)) }
                } else { state[v] = 2; stack.removeLast() }
            }
        }
        // Longest-path layering (Kahn).
        var layer = [Int](repeating: 0, count: n)
        var queue = (0..<n).filter { indeg[$0] == 0 }
        var qi = 0
        while qi < queue.count {
            let v = queue[qi]; qi += 1
            for t in dagOut[v] {
                layer[t] = max(layer[t], layer[v] + 1)
                indeg[t] -= 1
                if indeg[t] == 0 { queue.append(t) }
            }
        }
        for i in 0..<n { nodes[i].layer = layer[i] }

        // Neighbours for barycentres.
        var nbr = [[Int]](repeating: [], count: n)
        for e in edges { nbr[e.from].append(e.to); nbr[e.to].append(e.from) }

        // Per component: order within layers, then place.
        let comps = compMembers.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        componentCount = comps.count
        var pos = [Float](repeating: 0, count: n)
        struct Placed { var members: [Int]; var w: Float; var h: Float }
        var placed: [Placed] = []
        for (ci, members) in comps.enumerated() {
            let maxLayer = members.map { layer[$0] }.max() ?? 0
            var layers = [[Int]](repeating: [], count: maxLayer + 1)
            // Initial order: storyline, then id, so related chains start adjacent.
            for m in members.sorted(by: { (nodes[$0].storyline ?? "~", nodes[$0].key.id) < (nodes[$1].storyline ?? "~", nodes[$1].key.id) }) {
                layers[layer[m]].append(m)
            }
            for l in layers { for (i, m) in l.enumerated() { pos[m] = Float(i) } }
            func sweep(_ order: [Int]) {
                for li in order {
                    var keyed: [(Int, Float)] = []
                    for m in layers[li] {
                        let ns = nbr[m].filter { layer[$0] != li }
                        let near = ns.filter { abs(layer[$0] - li) == 1 }
                        let use = near.isEmpty ? ns : near
                        keyed.append((m, use.isEmpty ? pos[m] : use.reduce(0) { $0 + pos[$1] } / Float(use.count)))
                    }
                    keyed.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
                    layers[li] = keyed.map(\.0)
                    for (i, m) in layers[li].enumerated() { pos[m] = Float(i) }
                }
            }
            if maxLayer > 0 {
                for _ in 0..<4 {
                    sweep(Array(0...maxLayer)); sweep(Array((0...maxLayer).reversed()))
                }
            }
            let tallest = layers.map(\.count).max() ?? 1
            for (li, l) in layers.enumerated() {
                let offset = Float(tallest - l.count) / 2
                for (i, m) in l.enumerated() {
                    nodes[m].x = Float(li) * Self.xGap
                    nodes[m].y = (Float(i) + offset) * Self.yGap
                    nodes[m].component = ci
                }
            }
            placed.append(Placed(members: members, w: Float(maxLayer + 1) * Self.xGap, h: Float(tallest) * Self.yGap))
        }
        // Shelf-pack components.
        let rowWidth = max(placed.first?.w ?? 0, 5200)
        var cx: Float = 0, cy: Float = 0, rowH: Float = 0, maxX: Float = 0
        for p in placed {
            if cx > 0, cx + p.w > rowWidth { cx = 0; cy += rowH + 80; rowH = 0 }
            for m in p.members { nodes[m].x += cx; nodes[m].y += cy }
            cx += p.w + 60; rowH = max(rowH, p.h); maxX = max(maxX, cx)
        }
        // Isolated nodes: grid beneath.
        var gy = cy + rowH + 140
        let iso = nodes.indices.filter { nodes[$0].isolated }
        let cols = 24
        for (i, m) in iso.enumerated() {
            nodes[m].x = Float(i % cols) * 190
            nodes[m].y = gy + Float(i / cols) * Self.yGap
            nodes[m].component = componentCount
        }
        if !iso.isEmpty { gy += Float((iso.count + cols - 1) / cols) * Self.yGap }
        bounds = (max(maxX, Float(min(cols, iso.count)) * 190), gy + 60)
    }
}
