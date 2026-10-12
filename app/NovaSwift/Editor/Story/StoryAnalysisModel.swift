#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// One row of the bit index table.
struct StoryBitRow: Identifiable, Sendable {
    var id: Int { bit }
    let bit: Int
    let setters: Int
    let testers: Int
    let status: ControlBitIndex.Status
    let touched: Bool
}

/// Everything the Story & Bits tool derives from the effective collection:
/// the control-bit index, the mission flow graph (with layout) and the bit
/// table rows. Computed once per document revision, off the main actor and
/// debounced, so typing in an inspector never blocks on 1500 missions.
@MainActor
final class StoryAnalysisModel: ObservableObject {
    @Published private(set) var index = ControlBitIndex(ResourceCollection())
    @Published private(set) var graph = StoryGraph()
    @Published private(set) var rows: [StoryBitRow] = []
    @Published private(set) var notes = BitNotes()
    @Published private(set) var isComputing = false
    /// Increments each time a fresh result lands (graph view re-fits on the first one).
    @Published private(set) var generation = 0
    /// Storyline names present, sorted.
    @Published private(set) var storylines: [String] = []

    private var task: Task<Void, Never>?
    private var computedRevision = -1
    private(set) var lastComputeMillis = 0.0

    func refresh(_ model: EditorModel, immediate: Bool = false) {
        guard model.revision != computedRevision else { return }
        let rev = model.revision
        task?.cancel()
        isComputing = true
        let eff = model.effective
        var touched = Set<ResourceKey>()
        for (t, m) in model.document.layer.byType { for id in m.keys { touched.insert(ResourceKey(t, id)) } }
        notes = Self.loadNotes(eff)
        task = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(380)) }
            if Task.isCancelled { return }
            let t0 = Date()
            let result = await Task.detached(priority: .userInitiated) { () -> (ControlBitIndex, StoryGraph, [StoryBitRow], [String]) in
                let idx = ControlBitIndex(eff, touched: touched)
                let g = StoryGraph(collection: eff, index: idx, touched: touched)
                let rows = idx.usedBits.map { b -> StoryBitRow in
                    let refs = idx.references(bit: b)
                    return StoryBitRow(bit: b, setters: refs.filter { !$0.isTest }.count, testers: refs.filter(\.isTest).count,
                                  status: idx.status(of: b), touched: idx.pluginTouchedBits.contains(b))
                }
                let lines = Set(g.nodes.compactMap(\.storyline)).sorted()
                return (idx, g, rows, lines)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.index = result.0; self.graph = result.1; self.rows = result.2; self.storylines = result.3
            self.computedRevision = rev
            self.lastComputeMillis = Date().timeIntervalSince(t0) * 1000
            self.generation += 1
            self.isComputing = false
        }
    }

    static func loadNotes(_ c: ResourceCollection) -> BitNotes {
        c.resource(BitNotes.type, BitNotes.resourceID).map { BitNotes(data: $0.data) } ?? BitNotes()
    }

    func note(_ bit: Int) -> BitNotes.Note { notes[bit] }

    /// Name/note edits are one coalesced undo step per bit.
    func setNote(_ bit: Int, _ note: BitNotes.Note, model: EditorModel) {
        notes[bit] = note
        model.writeData(notes.encoded(), for: ResourceKey(BitNotes.type, BitNotes.resourceID),
                        name: "Bit notes", label: "Edit note for bit \(bit)", coalesce: "bitnote/\(bit)")
    }
}

/// Which side-panel the right region shows.
enum StoryInspect: Hashable {
    case none
    case bit(Int)
    case node(ResourceKey)
}

enum StoryColorMode: String, CaseIterable, Identifiable {
    case storyline = "Storyline", government = "Government", plugin = "Plug-in"
    var id: String { rawValue }
}

enum BitFilter: String, CaseIterable, Identifiable {
    case all = "All", deadGate = "Dead gates", unused = "Set, never tested", touched = "Plug-in"
    var id: String { rawValue }
}

enum NodeFilter: String, CaseIterable, Identifiable {
    case all = "All", missions = "Missions", crons = "Crons", touched = "Plug-in", unreachable = "Unreachable", deadEnd = "Dead ends"
    var id: String { rawValue }
}

/// Selection, filters and viewport shared by the three regions.
@MainActor
final class StoryUIState: ObservableObject {
    enum Left: String, CaseIterable, Identifiable { case bits = "Bits", missions = "Missions"; var id: String { rawValue } }

    @Published var left: Left = .bits
    @Published var inspect: StoryInspect = .none

    @Published var bitSearch = ""
    @Published var bitFilter: BitFilter = .all

    @Published var nodeSearch = ""
    @Published var nodeFilter: NodeFilter = .all
    @Published var storyline: String?          // nil = all

    // Graph
    @Published var colorMode: StoryColorMode = .storyline
    @Published var graphSearch = ""
    @Published var onlyComponent = false       // restrict to the selection's connected component
    @Published var showIsolated = false
    @Published var viewport = MapViewport()
    /// Node to centre next draw.
    @Published var focusKey: ResourceKey?
    @Published var fitTick = 0

    var selectedNode: ResourceKey? { if case let .node(k) = inspect { return k }; return nil }
    var selectedBit: Int? { if case let .bit(b) = inspect { return b }; return nil }

    func select(node k: ResourceKey, focus: Bool = false) {
        inspect = .node(k)
        if focus { focusKey = k }
    }
    func select(bit b: Int) { inspect = .bit(b) }
}
#endif
