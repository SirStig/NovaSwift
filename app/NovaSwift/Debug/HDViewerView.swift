import SwiftUI
import SpriteKit
import ImageIO
import UniformTypeIdentifiers
import NovaSwiftKit

/// HD / 3D tester: every sprite the game uses (or, by default, just those the
/// loaded graphics packs enhance), named after what draws it — hull, planet,
/// weapon, explosion — with its HD state and memory, and a turntable showing
/// the classic sprite against its HD replacement: scrub, spin or step the
/// frames, fire the engines, light the running lights, flip / crossfade the
/// two versions at matched scale — plus "Spawn…" to see a hull in flight.
/// Opened from the dev console's HD / 3D section (or `hd view`).
struct HDViewerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var debug: DebugController
    @Environment(\.dismiss) private var dismiss

    @State private var status = HDGraphics.shared.status()
    @State private var index: SpriteOwnerIndex?
    @State private var allRows: [Row] = []
    @State private var selected: Int?
    @State private var search = ""
    @State private var category: SpriteOwnerIndex.Category?
    @State private var stateFilter = StateFilter.any
    @State private var coverage = false
    @State private var dragStart: Int?
    @State private var exporting = false
    @State private var exportDoc = PNGDocument(data: Data())
    @State private var exportName = "sprite"
    @StateObject private var stage = HDViewerStage()

    /// One list row, built once per index/status change so typing in the
    /// search field only filters.
    struct Row: Identifiable {
        let id: Int
        let category: SpriteOwnerIndex.Category
        let title: String
        let subtitle: String
        let state: HDGraphics.EntryStatus.State?
        let search: String
        var hasHD: Bool { state != nil }
    }

    enum StateFilter: String, CaseIterable, Identifiable {
        case any = "Any HD state", ready = "Ready", pending = "Pending", failed = "Failed"
        case notPrepared = "Not prepared", noHD = "No HD"
        var id: String { rawValue }
        func matches(_ s: HDGraphics.EntryStatus.State?) -> Bool {
            switch self {
            case .any: return true
            case .ready: return s == .ready
            case .pending: return s == .pending
            case .failed: return s == .failed
            case .notPrepared: return s == .notPrepared
            case .noHD: return s == nil
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .navigationTitle("HD / 3D Viewer")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("Refresh") { refresh(); load() } }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 540)
        #endif
        #if !os(tvOS)
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .png,
                      defaultFilename: exportName) { _ in }
        #endif
        .task { await buildIndex() }
        .onAppear {
            refresh()
            if selected == nil { selected = rows.first?.id }
            load()
        }
        .onChange(of: selected) { _, _ in load() }
        .onDisappear { stage.stop() }
    }

    // MARK: Data

    private func refresh() {
        status = HDGraphics.shared.status()
        rebuildRows()
    }

    private func load() {
        guard let id = selected, let game = model.data.game else { return }
        stage.load(spriteID: id, entry: index?[id], game: game)
    }

    /// The owner index walks every resource table, so it is built once per
    /// loaded game (cached by a cheap fingerprint of the tables it reads) and
    /// off the main thread.
    private func buildIndex() async {
        guard index == nil, let game = model.data.game else { return }
        let key = HDViewerIndexCache.fingerprint(game)
        if let hit = HDViewerIndexCache.cached, hit.key == key {
            index = hit.index
        } else {
            let built = await Task.detached(priority: .userInitiated) { SpriteOwnerIndex(game: game) }.value
            HDViewerIndexCache.cached = (key, built)
            index = built
        }
        rebuildRows()
        if selected == nil { selected = rows.first?.id }
        load()
    }

    private func rebuildRows() {
        let byID = Dictionary(status.entries.map { ($0.spriteID, $0) }, uniquingKeysWith: { a, _ in a })
        func detail(_ spriteID: Int, _ kindFallback: String, _ st: HDGraphics.EntryStatus?) -> String {
            var s = "sprite #\(spriteID) · \(st?.kind.rawValue ?? kindFallback) · \(st?.origin ?? "no HD")"
            if let st {
                if let scale = st.pixelScale { s += String(format: " · %.0f×", scale) }
                if st.bytes > 0 { s += String(format: " · %.1f MB", Double(st.bytes) / 1_048_576) }
                if !st.layers.isEmpty { s += " · " + st.layers.joined(separator: ", ") }
            }
            return s
        }
        var rows: [Row] = []
        var seen = Set<Int>()
        for e in index?.sorted ?? [] {
            let st = byID[e.spriteID]
            rows.append(Row(id: e.spriteID, category: e.category, title: e.title,
                            subtitle: detail(e.spriteID, e.category.rawValue.lowercased(), st),
                            state: st?.state, search: e.searchText + " " + (st?.origin.lowercased() ?? "")))
            seen.insert(e.spriteID)
        }
        // Enhancements for sprite ids nothing in the data names (or while the index is still building).
        for st in status.entries where !seen.contains(st.spriteID) {
            rows.append(Row(id: st.spriteID, category: .other, title: "Sprite #\(st.spriteID)",
                            subtitle: detail(st.spriteID, "other", st), state: st.state,
                            search: "\(st.spriteID) #\(st.spriteID) \(st.origin.lowercased())"))
        }
        allRows = rows
    }

    /// The rows the search and filters leave.
    private var rows: [Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows.filter { r in
            (coverage || r.hasHD || stateFilter == .noHD)
                && (category == nil || r.category == category)
                && stateFilter.matches(r.state)
                && (q.isEmpty || r.search.contains(q))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let visible = rows
        return List(selection: $selected) {
            Section {
                LabeledContent("HD graphics", value: status.enabled ? "on" : "off")
                LabeledContent("Detail", value: "\(Int(status.maxScale))×")
                LabeledContent("Texture memory", value: String(format: "%.1f MB", Double(status.totalBytes) / 1_048_576))
                if !status.enabled {
                    Text("HD is off, so the HD side stays empty until you turn it on (dev tools ▸ HD / 3D).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Filter") {
                Picker("Category", selection: $category) {
                    Text("All categories").tag(SpriteOwnerIndex.Category?.none)
                    ForEach(SpriteOwnerIndex.Category.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                Picker("HD state", selection: $stateFilter) {
                    ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Coverage (every sprite the game uses)", isOn: $coverage)
                if coverage { coverageSummary }
            }
            if index == nil {
                HStack { ProgressView().controlSize(.small); Text("Indexing sprite owners…").font(.caption) }
            }
            ForEach(SpriteOwnerIndex.Category.allCases) { cat in
                let inCat = visible.filter { $0.category == cat }
                if !inCat.isEmpty {
                    Section("\(cat.rawValue) (\(inCat.count))") {
                        ForEach(inCat) { rowView($0).tag($0.id) }
                    }
                }
            }
            if visible.isEmpty && index != nil {
                Text(coverage ? "Nothing matches." : "Nothing matches — turn on Coverage to include sprites with no HD art.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.problems.isEmpty {
                Section("Problems") {
                    ForEach(status.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .searchable(text: $search, prompt: "Name, sprite id, system")
    }

    /// "Ships: 112/170 enhanced" per category — what a pack author still has to make.
    private var coverageSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SpriteOwnerIndex.Category.allCases) { cat in
                let all = allRows.filter { $0.category == cat }
                if !all.isEmpty {
                    Text("\(cat.rawValue): \(all.filter(\.hasHD).count)/\(all.count) enhanced")
                }
            }
            Text("Total: \(allRows.filter(\.hasHD).count)/\(allRows.count) enhanced").bold()
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private func rowView(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(r.title.isEmpty ? "Sprite #\(r.id)" : r.title).lineLimit(1)
                Spacer()
                Text(r.state?.rawValue ?? "no HD")
                    .font(.caption.bold())
                    .foregroundStyle(r.state == .ready ? .green : r.state == .failed ? .red : .secondary)
            }
            Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = selected {
            let entry = index?[id]
            let st = status.entries.first { $0.spriteID == id }
            VStack(spacing: 0) {
                ZStack {
                    SpriteView(scene: stage.scene)
                    #if !os(tvOS)
                    // Drag horizontally to rotate; the overlay keeps the gesture off SpriteView's own event handling.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if dragStart == nil { dragStart = stage.heading; stage.spinning = false }
                                stage.scrub(from: dragStart ?? 0, dx: v.translation.width)
                            }
                            .onEnded { _ in dragStart = nil })
                    #endif
                }
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                // Key handlers run inside a view update; defer the @Published
                // writes to the next main-actor turn.
                .onKeyPress(.leftArrow) { deferred { stage.step(-1) } }
                .onKeyPress(.rightArrow) { deferred { stage.step(1) } }
                .onKeyPress(.upArrow) { deferred { stage.stepSet(1) } }
                .onKeyPress(.downArrow) { deferred { stage.stepSet(-1) } }
                .onKeyPress(.space) { deferred { stage.togglePlay() } }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        controls
                        infoPanel(id: id, entry: entry, status: st)
                    }
                    .padding()
                }
                .frame(maxHeight: 320)
            }
            .navigationTitle(entry?.title ?? "Sprite #\(id)")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let entry, !entry.shipIDs.isEmpty { spawnMenu(entry) }
                    #if !os(tvOS)
                    exportMenu(id: id, entry: entry)
                    #endif
                }
            }
        } else {
            ContentUnavailableView("Select a sprite", systemImage: "cube.transparent")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stage.caption).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if stage.framesPerSet > 1 {
                HStack {
                    Button { stage.step(-1) } label: { Image(systemName: "chevron.left") }
                    Button { stage.step(1) } label: { Image(systemName: "chevron.right") }
                    Toggle(stage.isShip ? "Spin" : "Play", isOn: $stage.spinning)
                        #if !os(tvOS)
                        .toggleStyle(.switch)
                        #endif
                        .fixedSize()
                    Slider(value: Binding(get: { Double(stage.heading) },
                                          set: { stage.spinning = false; stage.heading = Int($0) }),
                           in: 0...Double(max(1, stage.framesPerSet - 1)), step: 1)
                    Text("\(stage.isShip ? "heading" : "frame") \(stage.heading + 1)/\(stage.framesPerSet)")
                        .font(.caption.monospacedDigit()).frame(width: 110)
                }
                if stage.isShip {
                    Picker("Bank", selection: $stage.set) {
                        ForEach(0..<max(1, stage.setCount), id: \.self) { i in
                            Text(i == 0 ? "Level" : i == 1 ? "Bank left" : i == 2 ? "Bank right" : "Set \(i)").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(stage.setCount < 2)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading) {
                if stage.isShip {
                    Toggle("Thrust", isOn: $stage.thrust).disabled(!stage.hasEngine)
                    Toggle("Lights", isOn: $stage.lights).disabled(!stage.hasLights)
                    Toggle("Weapons", isOn: $stage.weaponGlow).disabled(!stage.hasWeaponGlow)
                    Toggle("Shield", isOn: $stage.shield).disabled(!stage.hasShield)
                } else if stage.framesPerSet > 1 {
                    Toggle("Loop", isOn: $stage.loop)
                }
                if stage.compare == .sideBySide { Toggle("Classic side", isOn: $stage.showClassic) }
            }
            Picker("Compare", selection: $stage.compare) {
                ForEach(HDViewerStage.Compare.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch stage.compare {
            case .sideBySide: EmptyView()
            case .flip:
                Picker("Showing", selection: $stage.flipHD) {
                    Text("A · Classic").tag(false)
                    Text("B · HD / 3D").tag(true)
                }
                .pickerStyle(.segmented)
            case .crossfade:
                HStack {
                    Text("Classic").font(.caption)
                    Slider(value: $stage.mix, in: 0...1)
                    Text("HD").font(.caption)
                }
            }
            HStack(spacing: 16) {
                Picker("Background", selection: $stage.background) {
                    ForEach(HDViewerStage.Background.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                HStack {
                    Text("Zoom")
                    Slider(value: $stage.zoom, in: 1...8).frame(minWidth: 80, maxWidth: 160)
                    Text(String(format: "%.1f×", stage.zoom)).font(.caption.monospacedDigit()).frame(width: 36)
                }
            }
            Text("Arrows: ←/→ heading, ↑/↓ bank set, space: spin. Click the stage first. Drag to rotate.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func infoPanel(id: Int, entry: SpriteOwnerIndex.Entry?, status st: HDGraphics.EntryStatus?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Info").font(.headline)
            LabeledContent("Sprite", value: "#\(id)" + (entry.map { " · \($0.category.rawValue.lowercased())" } ?? ""))
            if stage.frameCount > 0 {
                LabeledContent("Classic frame", value: "\(stage.frameWidth)×\(stage.frameHeight) px")
                LabeledContent("Frames", value: stage.isShip
                               ? "\(stage.frameCount) (\(stage.setCount) set\(stage.setCount == 1 ? "" : "s") × \(stage.framesPerSet))"
                               : "\(stage.frameCount)")
            }
            if let st {
                LabeledContent("HD", value: st.state.rawValue + " · " + st.kind.rawValue)
                if let scale = st.pixelScale {
                    LabeledContent("Pixel scale", value: String(format: "%.0f× (%d×%d px)", scale,
                                                                Int(Double(stage.frameWidth) * scale), Int(Double(stage.frameHeight) * scale)))
                }
                LabeledContent("Memory", value: st.bytes > 0 ? String(format: "%.2f MB", Double(st.bytes) / 1_048_576) : "—")
                LabeledContent("Pack origin", value: st.origin)
                if !st.layers.isEmpty { LabeledContent("HD layers", value: st.layers.joined(separator: ", ")) }
            } else {
                LabeledContent("HD", value: "no enhancement for this sprite")
            }
            if !stage.shipLayers.isEmpty {
                LabeledContent("Hull layers", value: stage.shipLayers.joined(separator: ", "))
            }
            if let entry {
                if !entry.systems.isEmpty {
                    LabeledContent("Systems", value: entry.systems.prefix(8).map(\.name).joined(separator: ", ")
                                   + (entry.systems.count > 8 ? " (+\(entry.systems.count - 8) more)" : ""))
                }
                #if os(tvOS)
                Text("Owners (\(entry.owners.count))")
                ownerList(entry)
                #else
                DisclosureGroup("Owners (\(entry.owners.count))") { ownerList(entry) }
                #endif
            }
        }
    }

    private func ownerList(_ entry: SpriteOwnerIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(entry.owners.enumerated()), id: \.offset) { _, o in
                Text(ownerLine(o)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deferred(_ action: @escaping @MainActor () -> Void) -> KeyPress.Result {
        Task { @MainActor in action() }
        return .handled
    }

    private func ownerLine(_ o: SpriteOwnerIndex.Owner) -> String {
        var s = "\(o.name) · \(o.category.rawValue.dropLast()) #\(o.resourceID)"
        if let l = o.layer { s += " · \(l.rawValue) layer" }
        if let spin = o.spinID { s += " · spïn #\(spin)" }
        if !o.systems.isEmpty { s += " · " + o.systems.prefix(3).map(\.name).joined(separator: ", ") }
        return s
    }

    // MARK: Actions

    /// One menu for every hull that uses the sprite, each with the three
    /// dispositions `debugSpawnShip(hull:as:)` offers.
    private func spawnMenu(_ entry: SpriteOwnerIndex.Entry) -> some View {
        Menu {
            ForEach(entry.shipIDs, id: \.self) { hull in
                Menu(entry.owners.first { $0.category == .ships && $0.resourceID == hull }?.name ?? "Ship \(hull)") {
                    Button("Neutral") { _ = debug.scene?.debugSpawnShip(hull: hull, as: .neutral) }
                    Button("Escort") { _ = debug.scene?.debugSpawnShip(hull: hull, as: .escort) }
                    Button("Hostile") { _ = debug.scene?.debugSpawnShip(hull: hull, as: .hostile) }
                }
            }
        } label: {
            Label("Spawn…", systemImage: "plus.circle")
        }
        .disabled(debug.scene == nil)
        .help(debug.scene == nil ? "Fly into a system first" : "Spawn a hull that uses this sprite in the current system")
    }

    private func exportMenu(id: Int, entry: SpriteOwnerIndex.Entry?) -> some View {
        Menu {
            Button("Classic frame (PNG)") { export(hd: false, id: id, entry: entry) }
                .disabled(!stage.canExport(hd: false))
            Button("HD frame (PNG)") { export(hd: true, id: id, entry: entry) }
                .disabled(!stage.canExport(hd: true))
        } label: {
            Label("Export PNG", systemImage: "square.and.arrow.up")
        }
    }

    private func export(hd: Bool, id: Int, entry: SpriteOwnerIndex.Entry?) {
        guard let image = stage.currentImage(hd: hd), let data = HDViewerStage.pngData(image) else { return }
        let base = (entry?.title.isEmpty == false ? entry!.title : "sprite")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        exportName = "\(base)-\(id)-\(hd ? "hd" : "classic")-f\(stage.currentFrame)"
        exportDoc = PNGDocument(data: data)
        exporting = true
    }
}

/// The owner index for the loaded game, kept across viewer openings.
@MainActor
enum HDViewerIndexCache {
    static var cached: (key: String, index: SpriteOwnerIndex)?

    /// Table sizes and id sums of everything the index reads: changes whenever
    /// a different game or plug-in set is loaded.
    static func fingerprint(_ game: NovaGame) -> String {
        [NovaType.ship, NovaType.shan, NovaType.spob, NovaType.syst, NovaType.weapon,
         NovaType.boom, NovaType.roid, NovaType.spin].map { t -> String in
            let r = game.resources.resources(of: t)
            return "\(r.count):\(r.reduce(0) { $0 &+ $1.id &+ $1.data.count })"
        }.joined(separator: "|")
    }
}

/// A PNG for `fileExporter` (save panel on macOS, Files on iOS; tvOS has no
/// document export, so there it is just the bytes).
#if os(tvOS)
struct PNGDocument {
    var data: Data
}
#else
struct PNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif

private final class ViewerScene: SKScene {
    var onResize: (() -> Void)?
    override func didChangeSize(_ oldSize: CGSize) { onResize?() }
}

/// The viewer's turntable: classic frame on the left, HD on the right (or
/// flipped / crossfaded in one spot), both with the hull's effect layers
/// stacked the way the game stacks them.
@MainActor
final class HDViewerStage: ObservableObject {
    enum Compare: String, CaseIterable, Identifiable {
        case sideBySide = "Side by side", flip = "A/B flip", crossfade = "Crossfade"
        var id: String { rawValue }
    }
    enum Background: String, CaseIterable, Identifiable {
        case black = "Black", grey = "Grey", checker = "Checkerboard", stars = "Starfield"
        var id: String { rawValue }
    }

    private let viewerScene: ViewerScene = {
        let s = ViewerScene(size: CGSize(width: 800, height: 420))
        s.scaleMode = .resizeFill
        s.backgroundColor = .black
        s.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return s
    }()
    var scene: SKScene { viewerScene }

    @Published var heading = 0 { didSet { apply() } }
    @Published var set = 0 { didSet { apply() } }
    @Published var thrust = false { didSet { apply() } }
    @Published var lights = true { didSet { apply() } }
    @Published var weaponGlow = false { didSet { apply() } }
    @Published var shield = false { didSet { apply() } }
    @Published var showClassic = true { didSet { apply() } }
    @Published var zoom = 3.0 { didSet { apply() } }
    @Published var spinning = true { didSet { updateSpin() } }
    @Published var loop = true { didSet { apply() } }
    @Published var compare = Compare.sideBySide { didSet { apply() } }
    @Published var flipHD = true { didSet { apply() } }
    @Published var mix = 0.5 { didSet { apply() } }
    @Published var background = Background.black { didSet { applyBackground() } }
    @Published private(set) var framesPerSet = 1
    @Published private(set) var setCount = 1
    @Published private(set) var frameCount = 0
    @Published private(set) var frameWidth = 0
    @Published private(set) var frameHeight = 0
    @Published private(set) var isShip = false
    @Published private(set) var hasEngine = false
    @Published private(set) var hasLights = false
    @Published private(set) var hasWeaponGlow = false
    @Published private(set) var hasShield = false
    @Published private(set) var shipLayers: [String] = []
    @Published private(set) var caption = ""

    private struct Side {
        var base: [SKTexture] = []
        var engine: [SKTexture] = []
        var lights: [SKTexture] = []
        var weapons: [SKTexture] = []
        var shield: [SKTexture] = []
    }
    private var classic = Side(), hd = Side()
    private var classicSheet: SpriteSheet?
    private var spriteID = 0
    private var nodes: [String: SKSpriteNode] = [:]
    private var labels: [SKLabelNode] = []
    private var backdrop: SKSpriteNode?
    private var timer: Timer?

    init() {
        viewerScene.onResize = { [weak self] in self?.apply() }
    }

    func load(spriteID: Int, entry: SpriteOwnerIndex.Entry?, game: NovaGame) {
        self.spriteID = spriteID
        // The sheet the way the game draws this sprite: a hull's shän base,
        // else the spïn that reaches it, else the bare id (rlëD / PICT).
        let hull = entry?.owners.first { $0.category == .ships && $0.layer == .base }
        let shan = hull.flatMap { game.shan($0.resourceID) }
        var sheet: SpriteSheet?
        if let hull, shan != nil { sheet = game.shipSprite(hull.resourceID) }
        else if let spin = entry?.spinID { sheet = game.spinSheet(spin) }
        if sheet == nil { sheet = game.spriteSheet(spriteID: spriteID, maskID: 0, frameWidth: 0, frameHeight: 0, frameCount: 0) }
        guard let sheet else {
            classicSheet = nil; classic = Side(); hd = Side()
            frameCount = 0; framesPerSet = 1; setCount = 1; isShip = false
            hasEngine = false; hasLights = false; hasWeaponGlow = false; hasShield = false; shipLayers = []
            caption = "sprite \(spriteID): no classic sheet could be built"
            buildNodes(); apply()
            return
        }
        classicSheet = sheet
        frameWidth = sheet.frameWidth; frameHeight = sheet.frameHeight; frameCount = sheet.frameCount
        isShip = shan != nil
        if let shan {
            framesPerSet = max(1, min(shan.framesPerSet, sheet.frameCount))
            setCount = max(1, sheet.frameCount / framesPerSet)
        } else {
            framesPerSet = sheet.frameCount; setCount = 1
        }
        func classicFrames(_ s: SpriteSheet?) -> [SKTexture] {
            guard let s else { return [] }
            return s.frameCGImages(0..<s.frameCount).map { let t = SKTexture(cgImage: $0.image); t.filteringMode = .nearest; return t }
        }
        func layer(_ id: Int, _ mask: Int, _ w: Int, _ h: Int) -> SpriteSheet? {
            id > 0 ? game.spriteSheet(spriteID: id, maskID: mask, frameWidth: w, frameHeight: h, frameCount: sheet.frameCount) : nil
        }
        var engine: SpriteSheet?, light: SpriteSheet?, weap: SpriteSheet?, shieldSheet: SpriteSheet?
        if let hull, let shan {
            engine = game.engineGlowSprite(hull.resourceID)
            light = layer(shan.lightSpriteID, shan.lightMaskID, shan.lightWidth, shan.lightHeight)
            weap = layer(shan.weaponGlowSpriteID, shan.weaponGlowMaskID, shan.weaponGlowWidth, shan.weaponGlowHeight)
            shieldSheet = game.shieldSprite(hull.resourceID)
            shipLayers = entry!.owners.filter { $0.resourceID == hull.resourceID }.compactMap { $0.layer?.rawValue }
        } else {
            shipLayers = []
        }
        classic = Side(base: classicFrames(sheet), engine: classicFrames(engine), lights: classicFrames(light),
                       weapons: classicFrames(weap), shield: classicFrames(shieldSheet))
        let hdr = HDGraphics.shared
        hd = Side(base: hdr.frames(for: sheet) ?? [],
                  engine: engine.flatMap { hdr.frames(for: $0) } ?? [],
                  lights: light.flatMap { hdr.frames(for: $0) } ?? [],
                  weapons: weap.flatMap { hdr.frames(for: $0) } ?? [],
                  shield: (isShip ? hdr.shieldFrames(baseSpriteID: spriteID) : nil) ?? [])
        hasEngine = !classic.engine.isEmpty || !hd.engine.isEmpty
        hasLights = !classic.lights.isEmpty || !hd.lights.isEmpty
        hasWeaponGlow = !classic.weapons.isEmpty || !hd.weapons.isEmpty
        hasShield = !classic.shield.isEmpty || !hd.shield.isEmpty
        // Explosions play once; everything else loops.
        loop = entry?.category != .explosions
        thrust = false; weaponGlow = false; shield = false
        heading = 0; set = 0
        caption = "sprite \(spriteID) · \(sheet.frameWidth)×\(sheet.frameHeight) · \(sheet.frameCount) frames"
            + (hd.base.isEmpty ? " · HD not ready or off" : "")
        buildNodes()
        spinning = true
        updateSpin()
        apply()
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Playback

    func step(_ delta: Int) {
        spinning = false
        let n = max(1, framesPerSet)
        heading = ((heading + delta) % n + n) % n
    }

    func stepSet(_ delta: Int) {
        guard isShip, setCount > 1 else { return }
        set = ((set + delta) % setCount + setCount) % setCount
    }

    func togglePlay() {
        if !spinning, !isShip, !loop, heading >= framesPerSet - 1 { heading = 0 }
        spinning.toggle()
    }

    /// Drag-to-rotate: about 6 points per frame, from the heading at drag start.
    func scrub(from start: Int, dx: CGFloat) {
        let n = max(1, framesPerSet)
        heading = ((start + Int((dx / 6).rounded())) % n + n) % n
    }

    private func updateSpin() {
        timer?.invalidate(); timer = nil
        guard spinning, framesPerSet > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / (isShip ? 12 : 15), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let next = heading + 1
        if next < framesPerSet { heading = next }
        else if isShip || loop { heading = 0 }
        else { spinning = false }
    }

    // MARK: Export

    var currentFrame: Int { min(max(0, frameCount - 1), set * framesPerSet + heading) }

    func canExport(hd wantHD: Bool) -> Bool {
        classicSheet != nil && (!wantHD || HDGraphics.shared.isReady(spriteID))
    }

    func currentImage(hd wantHD: Bool) -> CGImage? {
        guard let sheet = classicSheet else { return nil }
        return wantHD ? HDGraphics.shared.frameImage(for: sheet, frame: currentFrame)
                      : sheet.frameCGImages([currentFrame]).first?.image
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Scene

    private func buildNodes() {
        scene.removeAllChildren()
        nodes = [:]; labels = []; backdrop = nil
        for side in ["classic", "hd"] {
            for (i, layer) in ["base", "engine", "lights", "weapons", "shield"].enumerated() {
                let n = SKSpriteNode()
                n.blendMode = layer == "base" ? .alpha : .add
                n.zPosition = CGFloat(i == 0 ? 0 : i)
                scene.addChild(n)
                nodes["\(side).\(layer)"] = n
            }
            let label = SKLabelNode(fontNamed: "Menlo-Bold")
            label.fontSize = 12
            label.fontColor = side == "hd" ? SKColor(red: 0.3, green: 1, blue: 0.55, alpha: 1) : SKColor(white: 0.75, alpha: 1)
            label.zPosition = 20
            scene.addChild(label)
            labels.append(label)
        }
        applyBackground()
    }

    private func applyBackground() {
        backdrop?.removeFromParent(); backdrop = nil
        switch background {
        case .black: scene.backgroundColor = .black
        case .grey: scene.backgroundColor = SKColor(white: 0.42, alpha: 1)
        case .checker, .stars:
            scene.backgroundColor = .black
            guard let image = Self.backdropImage(background) else { return }
            let t = SKTexture(cgImage: image)
            t.filteringMode = .nearest
            let n = SKSpriteNode(texture: t)
            n.zPosition = -100
            backdrop = n
            scene.addChild(n)
            layoutBackdrop()
        }
    }

    private func layoutBackdrop() {
        // The bitmap is drawn at half size and doubled, so cells / stars are 2 pt.
        backdrop?.size = CGSize(width: max(2048, scene.size.width + 64), height: max(1536, scene.size.height + 64))
        backdrop?.position = .zero
    }

    private static func backdropImage(_ kind: Background) -> CGImage? {
        let w = 1024, h = 768
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if kind == .checker {
            let cell = 8
            for y in 0..<(h / cell) {
                for x in 0..<(w / cell) {
                    ctx.setFillColor(gray: (x + y) % 2 == 0 ? 0.30 : 0.42, alpha: 1)
                    ctx.fill(CGRect(x: x * cell, y: y * cell, width: cell, height: cell))
                }
            }
        } else {
            ctx.setFillColor(red: 0.01, green: 0.012, blue: 0.03, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<700 {
                let b = 0.25 + 0.75 * next() * next()
                ctx.setFillColor(red: b * 0.85, green: b * 0.9, blue: b, alpha: 1)
                ctx.fill(CGRect(x: Int(next() * Double(w)), y: Int(next() * Double(h)), width: 1, height: 1))
            }
        }
        return ctx.makeImage()
    }

    private func apply() {
        layoutBackdrop()
        let frame = set * framesPerSet + heading
        let spacing = scene.size.width / 4
        // Where each side sits, whether it shows, and how opaque it is.
        let sides: [(name: String, data: Side, x: CGFloat, visible: Bool, alpha: CGFloat)]
        switch compare {
        case .sideBySide:
            let sp = showClassic ? spacing : 0
            sides = [("classic", classic, -sp, showClassic, 1), ("hd", hd, sp, true, 1)]
        case .flip:
            sides = [("classic", classic, 0, !flipHD, 1), ("hd", hd, 0, flipHD, 1)]
        case .crossfade:
            sides = [("classic", classic, 0, true, 1 - mix), ("hd", hd, 0, true, mix)]
        }
        for s in sides {
            let layers: [(String, [SKTexture], Bool)] = [
                ("base", s.data.base, true), ("engine", s.data.engine, thrust), ("lights", s.data.lights, lights),
                ("weapons", s.data.weapons, weaponGlow), ("shield", s.data.shield, shield),
            ]
            for (layer, frames, on) in layers {
                guard let n = nodes["\(s.name).\(layer)"] else { continue }
                guard s.visible, on, !frames.isEmpty else { n.isHidden = true; continue }
                // Shield bubbles hold one frame per heading, whatever the bank set.
                let t = frames[OriginalRendering.wrappedFrame(layer == "shield" ? heading : frame, count: frames.count)]
                n.texture = t
                n.size = t.size()
                n.setScale(zoom)
                n.position = CGPoint(x: s.x, y: 10)
                n.alpha = s.alpha
                n.isHidden = false
            }
        }
        guard labels.count == 2 else { return }
        let y = -scene.size.height / 2 + 14
        switch compare {
        case .sideBySide:
            labels[0].text = "Classic"; labels[1].text = hd.base.isEmpty ? "HD / 3D (none)" : "HD / 3D"
            labels[0].isHidden = !showClassic; labels[1].isHidden = false
            labels[0].position = CGPoint(x: showClassic ? -spacing : 0, y: y)
            labels[1].position = CGPoint(x: showClassic ? spacing : 0, y: y)
        case .flip:
            labels[0].text = "A · Classic"; labels[1].text = hd.base.isEmpty ? "B · HD / 3D (none)" : "B · HD / 3D"
            labels[0].isHidden = flipHD; labels[1].isHidden = !flipHD
            labels[0].position = CGPoint(x: 0, y: y); labels[1].position = CGPoint(x: 0, y: y)
        case .crossfade:
            labels[0].isHidden = true; labels[1].isHidden = false
            labels[1].text = "Classic \(Int(((1 - mix) * 100).rounded()))% · HD \(Int((mix * 100).rounded()))%"
            labels[1].position = CGPoint(x: 0, y: y)
        }
    }

    deinit { timer?.invalidate() }
}
