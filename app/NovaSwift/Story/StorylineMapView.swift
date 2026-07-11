import SwiftUI
import NovaSwiftStory

/// The **Story Map**: pick a storyline from the sidebar and see its full
/// branching tree — every outcome (accept/refuse/success/failure/abort/ship
/// objective) that can start a follow-up mission, colour-coded by the
/// pilot's live status and, per storyline, by its owning government's real
/// map colour. Storylines are grouped and filterable by which plug-in
/// contributed them. Tapping a node opens an inspector with its objective,
/// reward, and — for a locked node — exactly what to do to unlock it.
///
/// Showing one storyline at a time (rather than every campaign as parallel
/// lanes on one giant canvas) is what makes room to draw the *branches*: a
/// mission whose success/failure/refusal genuinely lead to different
/// follow-ups, or a `R(...)` 50/50 chance between two, instead of collapsing
/// everything to a single "next step" arrow.
struct StorylineMapView: View {
    @ObservedObject var model: StoryGuideModel
    var onClose: (() -> Void)?

    @State private var selectedKey: String?
    @State private var pluginFilter: String?
    @State private var selectedID: Int?
    @State private var zoom: CGFloat = 0.85
    @State private var zoomBase: CGFloat = 0.85
    /// The scroll content's frame relative to the scroll view's own bounds
    /// (i.e. how far it's been scrolled) and the scroll view's own on-screen
    /// size — together these give us the visible viewport. Tracked manually
    /// via `GeometryReader`/`PreferenceKey` since `onScrollGeometryChange`
    /// needs iOS 18/macOS 15, newer than this app's deployment target.
    ///
    /// Drives virtualized rendering: a campaign with heavy random-branch
    /// fan-out can still have plenty of nodes, so we only build cards and
    /// stroke edges that are actually (near) visible — the fix for a real
    /// memory/frame-rate crash on iPhone when this view drew everything.
    @State private var scrollContentFrame: CGRect = .zero
    @State private var scrollContainerSize: CGSize = .zero

    private enum Layout {
        static let columnWidth: CGFloat = 226
        static let columnGap: CGFloat = 44
        static let rowPitch: CGFloat = 164
        static let nodeWidth: CGFloat = 198
        static let nodeHeight: CGFloat = 118
        static let topInset: CGFloat = 32
        static let sideInset: CGFloat = 40
        static let bottomInset: CGFloat = 56
        static var columnPitch: CGFloat { columnWidth + columnGap }
        /// Extra invisible padding around every node's tap target, and how far
        /// zoomed-out the tree may go — both exist to keep nodes comfortably
        /// tappable on iPhone (Apple's 44pt minimum) instead of shrinking under
        /// a pinch until they're nearly impossible to hit accurately.
        static let nodeHitSlop: CGFloat = 10
        static let minZoom: CGFloat = 0.55
        static let maxZoom: CGFloat = 1.75
        /// Above this many simultaneously-visible nodes, switch from real
        /// `NodeCard` views to a cheap `Canvas`-drawn overview — a single
        /// storyline is usually far smaller than the old all-campaigns map,
        /// but a heavily-modded one could still hit this.
        static let maxDetailedNodes = 120
        /// How far outside the visible viewport to still build node/edge views,
        /// so scrolling doesn't visibly pop cards in at the edge.
        static let virtualizationMargin: CGFloat = rowPitch
        /// Symmetric padding wrapping the scaled tree inside the scroll view —
        /// needed to translate the ScrollView's reported visible rect back
        /// into unscaled map coordinates.
        static let contentPadding: CGFloat = 28
    }

    var body: some View {
        HStack(spacing: 0) {
            StorylineSidebar(lanes: model.storyMap.lanes, untaggedCount: model.storyMap.untaggedCount,
                             selectedKey: $selectedKey, pluginFilter: $pluginFilter,
                             pluginLabel: model.pluginLabel, governmentColor: model.governmentColor)
            Divider().overlay(.white.opacity(0.12))
            VStack(spacing: 0) {
                detailHeader
                Divider().overlay(.white.opacity(0.12))
                if model.storyMap.isEmpty {
                    emptyState
                } else if selectedLane == nil {
                    noSelectionState
                } else {
                    detailCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
        .novaResponsive()
        .onAppear { if selectedKey == nil { selectedKey = model.storyMap.lanes.first?.key } }
        .onChange(of: model.storyMap.lanes.map(\.key)) { _, keys in
            guard !keys.isEmpty else { selectedKey = nil; return }
            if let k = selectedKey, !keys.contains(k) { selectedKey = keys.first }
            else if selectedKey == nil { selectedKey = keys.first }
        }
    }

    // MARK: Header

    private var selectedLane: StoryMapLane? {
        model.storyMap.lanes.first { $0.key == selectedKey }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            if let lane = selectedLane {
                Circle().fill(model.governmentColor(lane.governmentID)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.title).novaFont(.heading, weight: .bold)
                    Text(detailSubtitle(lane)).novaFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "map.circle.fill").foregroundStyle(EVTheme.accent).font(.title2)
                Text("Story Map").novaFont(.heading, weight: .bold)
            }
            Spacer()
            if selectedLane != nil { legend }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(EVTheme.text.opacity(0.6))
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func detailSubtitle(_ lane: StoryMapLane) -> String {
        var parts = ["\(lane.completedCount)/\(lane.totalCount) steps", model.pluginLabel(lane.pluginID)]
        if let name = model.governmentName(lane.governmentID) { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                legendDot(.green, "Done"); legendDot(.cyan, "Active")
                legendDot(.yellow, "Available"); legendDot(.gray, "Locked")
            }
            HStack(spacing: 10) {
                legendDash(EVTheme.accent, "On success"); legendDash(.red, "Fail/abort")
                legendDash(.orange, "On refuse"); Text("? = random").novaFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).novaFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func legendDash(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2)
            Text(label).novaFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Tree layout for the selected storyline

    private var selectedStorylineNodes: [StoryMapNode] {
        guard let key = selectedKey else { return [] }
        return model.storyMap.nodes.filter { $0.storylineKey == key }
    }

    private var placedNodes: [PlacedNode] {
        let nodes = selectedStorylineNodes
        guard !nodes.isEmpty else { return [] }
        let laidOut = layoutTree(steps: nodes.map(\.step), edges: model.storyMap.edges)
        let placement = Dictionary(uniqueKeysWithValues: laidOut.map { ($0.id, ($0.column, $0.row)) })
        return nodes.compactMap { n in
            guard let p = placement[n.id] else { return nil }
            return PlacedNode(node: n, column: p.0, row: p.1)
        }
    }

    /// Edges wholly inside the selected storyline — what the tree draws as
    /// curves. A link to/from a *different* storyline (the analyzer allows
    /// these) becomes a tappable chip on the node instead (see `crossLinksByNode`).
    private var internalEdges: [StoryMapEdge] {
        let ids = Set(selectedStorylineNodes.map(\.id))
        guard !ids.isEmpty else { return [] }
        return model.storyMap.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
    }

    private var nodeByID: [Int: StoryMapNode] {
        Dictionary(uniqueKeysWithValues: model.storyMap.nodes.map { ($0.id, $0) })
    }

    private var crossLinksByNode: [Int: [CrossLink]] {
        guard let key = selectedKey else { return [:] }
        var out: [Int: [CrossLink]] = [:]
        let byID = nodeByID
        for edge in model.storyMap.edges {
            guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
            if from.storylineKey == key, to.storylineKey != key {
                out[from.id, default: []].append(CrossLink(key: to.storylineKey, outgoing: true))
            } else if to.storylineKey == key, from.storylineKey != key {
                out[to.id, default: []].append(CrossLink(key: from.storylineKey, outgoing: false))
            }
        }
        return out
    }

    // MARK: Detail canvas

    private var detailCanvas: some View {
        GeometryReader { outerGeo in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edgeLayer
                    nodeLayer
                }
                .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: contentSize.width * zoom, height: contentSize.height * zoom,
                       alignment: .topLeading)
                .padding(Layout.contentPadding)
                .background(
                    GeometryReader { innerGeo in
                        Color.clear.preference(key: ScrollContentFramePreferenceKey.self,
                                                value: innerGeo.frame(in: .named(scrollSpace)))
                    }
                )
                // Simultaneous (not exclusive) so pinch-zoom doesn't fight the
                // ScrollView's own native pan recognizer for the gesture.
                .simultaneousGesture(magnify)
            }
            // A fresh identity per storyline resets scroll position cleanly
            // when switching — otherwise a shorter tree can open mid-scroll.
            .id(selectedKey)
            .coordinateSpace(name: scrollSpace)
            .onPreferenceChange(ScrollContentFramePreferenceKey.self) { scrollContentFrame = $0 }
            .onAppear { scrollContainerSize = outerGeo.size }
            .onChange(of: outerGeo.size) { _, newSize in scrollContainerSize = newSize }
        }
        .background(mapBackground)
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .bottom) { inspector }
        .animation(.easeInOut(duration: 0.18), value: selectedID)
    }

    private let scrollSpace = "storyMapScroll"

    private var mapBackground: some View {
        LinearGradient(colors: [Color(white: 0.05), Color(white: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var edgeLayer: some View {
        let centers = Dictionary(uniqueKeysWithValues: placedNodes.map { ($0.id, center($0)) })
        let unlockedByID = Dictionary(uniqueKeysWithValues: placedNodes.map { ($0.id, $0.node.step.status == .completed) })
        let edges = internalEdges
        let rect = logicalVisibleRect
        return Canvas { ctx, _ in
            for edge in edges {
                guard let a = centers[edge.from], let b = centers[edge.to] else { continue }
                let span = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
                guard rect.intersects(span) else { continue }
                let unlocked = unlockedByID[edge.from] ?? false
                var path = Path()
                path.move(to: a)
                let midY = (a.y + b.y) / 2
                path.addCurve(to: b, control1: CGPoint(x: a.x, y: midY), control2: CGPoint(x: b.x, y: midY))
                let style = edgeStyle(edge, unlocked: unlocked)
                ctx.stroke(path, with: .color(style.color), style: StrokeStyle(lineWidth: style.width, dash: style.dash))
                if edge.isRandom {
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: midY)
                    ctx.draw(Text("?").font(.caption2.bold()).foregroundColor(style.color), at: mid)
                }
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .allowsHitTesting(false)
    }

    private func edgeStyle(_ edge: StoryMapEdge, unlocked: Bool) -> (color: Color, dash: [CGFloat], width: CGFloat) {
        if unlocked { return (Color.green.opacity(0.5), [], 2) }
        switch edge.outcome {
        case .failure, .abort: return (Color.red.opacity(0.55), [6, 3], 1.3)
        case .refuse: return (Color.orange.opacity(0.55), [6, 3], 1.3)
        case .accept, .success, .shipDone: return (EVTheme.accent.opacity(0.32), [], 1.3)
        case nil: return (Color.white.opacity(0.14), edge.kind == .unlocks ? [5, 5] : [], 1.3)
        }
    }

    /// Past this many simultaneously-visible missions, stop building a real
    /// `NodeCard` (SF Symbols, wrapped `Text`, a shadow) per node in favour of
    /// a cheap `Canvas`-drawn overview — the fix for an iPhone crash when a
    /// large enough tree is zoomed far enough out to see most of it at once.
    private var isLowDetail: Bool { visiblePlacedNodes.count > Layout.maxDetailedNodes }

    private var nodeLayer: some View {
        Group {
            if isLowDetail { lowDetailNodeCanvas } else { detailedNodeLayer }
        }
    }

    private var detailedNodeLayer: some View {
        let links = crossLinksByNode
        return ForEach(visiblePlacedNodes) { p in
            NodeCard(node: p.node, isSelected: p.node.id == selectedID,
                    govtColor: model.governmentColor(p.node.step.governmentID),
                    crossLinks: links[p.node.id] ?? [],
                    onCrossLink: { key in selectedKey = key; selectedID = nil })
                .frame(width: Layout.nodeWidth, height: Layout.nodeHeight)
                .contentShape(Rectangle())
                // Grow the tappable area beyond the visual card (symmetric,
                // transparent padding) so nodes stay comfortably tappable on
                // iPhone even when the map is pinched down toward `minZoom`.
                .padding(Layout.nodeHitSlop)
                .contentShape(Rectangle())
                .position(center(p))
                .onTapGesture { selectedID = (selectedID == p.id) ? nil : p.id }
        }
    }

    private var lowDetailNodeCanvas: some View {
        let nodes = visiblePlacedNodes
        let selected = selectedID
        return Canvas { ctx, _ in
            for p in nodes {
                let rect = nodeFrame(p)
                let tint = p.node.step.status.tint
                let path = Path(roundedRect: rect, cornerRadius: 6)
                ctx.fill(path, with: .color(tint.opacity(p.node.step.status == .locked ? 0.3 : 0.55)))
                let isSelected = p.id == selected
                ctx.stroke(path, with: .color(isSelected ? .white : tint.opacity(0.8)),
                           lineWidth: isSelected ? 2 : 1)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                let slop = Layout.nodeHitSlop
                guard let hit = nodes.first(where: {
                    nodeFrame($0).insetBy(dx: -slop, dy: -slop).contains(value.location)
                }) else { return }
                selectedID = (selectedID == hit.id) ? nil : hit.id
            }
        )
    }

    /// The visible viewport translated back into unscaled map coordinates
    /// (undoing the scroll offset, the content padding, and the pinch-zoom
    /// scale), outset by a margin so nodes are already built just before
    /// they'd scroll into view. Falls back to the whole tree before the first
    /// layout pass reports real geometry.
    private var logicalVisibleRect: CGRect {
        guard scrollContainerSize != .zero else {
            return CGRect(origin: .zero, size: contentSize)
        }
        let visibleInContent = CGRect(x: -scrollContentFrame.minX, y: -scrollContentFrame.minY,
                                       width: scrollContainerSize.width, height: scrollContainerSize.height)
        let pad = Layout.contentPadding
        let unscaled = CGRect(x: (visibleInContent.minX - pad) / zoom,
                               y: (visibleInContent.minY - pad) / zoom,
                               width: visibleInContent.width / zoom,
                               height: visibleInContent.height / zoom)
        return unscaled.insetBy(dx: -Layout.virtualizationMargin, dy: -Layout.virtualizationMargin)
    }

    private var visiblePlacedNodes: [PlacedNode] {
        let rect = logicalVisibleRect
        return placedNodes.filter { rect.intersects(nodeFrame($0)) }
    }

    private func nodeFrame(_ p: PlacedNode) -> CGRect {
        let c = center(p)
        return CGRect(x: c.x - Layout.nodeWidth / 2, y: c.y - Layout.nodeHeight / 2,
                      width: Layout.nodeWidth, height: Layout.nodeHeight)
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let id = selectedID, let node = model.storyMap.nodes.first(where: { $0.id == id }) {
            NodeInspector(node: node, govtName: model.governmentName(node.step.governmentID),
                         crossLinks: crossLinksByNode[id] ?? [],
                         onJump: { key in selectedKey = key; selectedID = nil },
                         onClose: { selectedID = nil })
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Zoom

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass") { setZoom(zoom - 0.15) }
            Divider().frame(height: 18).overlay(.white.opacity(0.15))
            Button { setZoom(0.85) } label: {
                Text("\(Int(zoom * 100))%").novaFont(.caption, weight: .bold)
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            Divider().frame(height: 18).overlay(.white.opacity(0.15))
            zoomButton("plus.magnifyingglass") { setZoom(zoom + 0.15) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(16)
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body).frame(width: 30, height: 22)
        }
        .buttonStyle(.plain)
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { v in zoom = clampZoom(zoomBase * v) }
            .onEnded { _ in zoomBase = zoom }
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { zoom = clampZoom(z) }
        zoomBase = zoom
    }
    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, Layout.minZoom), Layout.maxZoom) }

    // MARK: Geometry

    private func columnCenterX(_ i: Int) -> CGFloat {
        Layout.sideInset + Layout.columnWidth / 2 + CGFloat(i) * Layout.columnPitch
    }
    private func rowCenterY(_ r: Int) -> CGFloat {
        Layout.topInset + Layout.nodeHeight / 2 + CGFloat(r) * Layout.rowPitch
    }
    private func center(_ p: PlacedNode) -> CGPoint {
        CGPoint(x: columnCenterX(p.column), y: rowCenterY(p.row))
    }

    private var contentSize: CGSize {
        let nodes = placedNodes
        let cols = max((nodes.map(\.column).max() ?? -1) + 1, 1)
        let rows = max((nodes.map(\.row).max() ?? -1) + 1, 1)
        let w = Layout.sideInset * 2 + CGFloat(cols) * Layout.columnWidth
              + CGFloat(max(cols - 1, 0)) * Layout.columnGap
        let h = Layout.topInset + CGFloat(rows) * Layout.rowPitch + Layout.bottomInset
        return CGSize(width: w, height: h)
    }

    // MARK: Empty / no-selection states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "map").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No storylines found").novaFont(.heading)
            Text("Load your EV Nova data (or a plug-in with campaigns) to chart the story.")
                .novaFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelectionState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "list.bullet.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(pluginFilter == nil ? "Pick a storyline" : "No storylines match this filter")
                .novaFont(.heading).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A mission positioned in the selected storyline's tree (`StoryTreeLayout`'s
/// column/row) paired back with its full `StoryMapNode` (status, blockers,
/// dead ends) for rendering.
private struct PlacedNode: Identifiable {
    let node: StoryMapNode
    let column: Int
    let row: Int
    var id: Int { node.id }
}

/// A `.starts`/`.unlocks` edge that crosses out of the selected storyline —
/// rendered as a tappable chip on the node instead of an off-canvas curve,
/// since only one storyline's tree is on screen at a time.
struct CrossLink: Identifiable, Hashable {
    let key: String        // the other storyline's key
    let outgoing: Bool      // true = this node leads into `key`; false = started from it
    var id: String { "\(key)-\(outgoing)" }
}

// MARK: - Scroll geometry tracking

private struct ScrollContentFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Sidebar

/// The storyline picker: one row per campaign, grouped under a section per
/// contributing plug-in ("Base Game" first), with a leading government-color
/// swatch and a source filter once more than one plug-in is in play.
private struct StorylineSidebar: View {
    let lanes: [StoryMapLane]
    let untaggedCount: Int
    @Binding var selectedKey: String?
    @Binding var pluginFilter: String?
    let pluginLabel: (String) -> String
    let governmentColor: (Int?) -> Color

    private var pluginIDs: [String] {
        Array(Set(lanes.map(\.pluginID))).sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }   // Base Game always first
            return pluginLabel(a) < pluginLabel(b)
        }
    }

    private var groups: [(id: String, lanes: [StoryMapLane])] {
        let ids = pluginFilter.map { [$0] } ?? pluginIDs
        return ids.compactMap { id in
            let ls = lanes.filter { $0.pluginID == id }
            return ls.isEmpty ? nil : (id, ls)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if pluginIDs.count > 1 { filterControl }
            if groups.isEmpty {
                Spacer()
                Text("No storylines match this filter.")
                    .novaFont(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.id) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pluginLabel(group.id).uppercased())
                                    .novaFont(.caption, weight: .bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                ForEach(group.lanes) { lane in row(lane) }
                            }
                        }
                        if untaggedCount > 0, pluginFilter == nil {
                            Text("+ \(untaggedCount) one-off jobs")
                                .novaFont(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.top, 2)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 240)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder private var filterControl: some View {
        if pluginIDs.count <= 4 {
            Picker("", selection: $pluginFilter) {
                Text("All").tag(String?.none)
                ForEach(pluginIDs, id: \.self) { id in Text(pluginLabel(id)).tag(String?.some(id)) }
            }
            .pickerStyle(.segmented)
            .padding(10)
        } else {
            Menu {
                Button("All sources") { pluginFilter = nil }
                ForEach(pluginIDs, id: \.self) { id in
                    Button(pluginLabel(id)) { pluginFilter = id }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(pluginFilter.map(pluginLabel) ?? "All sources")
                        .novaFont(.caption, weight: .bold).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    private func row(_ lane: StoryMapLane) -> some View {
        Button { selectedKey = lane.key } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(governmentColor(lane.governmentID)).frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lane.title).novaFont(.body, weight: .bold).lineLimit(1)
                        Spacer()
                        if lane.isComplete {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                        }
                    }
                    ProgressView(value: lane.totalCount == 0 ? 0
                                 : Double(lane.completedCount) / Double(lane.totalCount))
                        .tint(EVTheme.accent)
                    Text("\(lane.completedCount)/\(lane.totalCount) steps")
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(lane.key == selectedKey ? EVTheme.accent.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Node card

private struct NodeCard: View {
    let node: StoryMapNode
    let isSelected: Bool
    let govtColor: Color
    let crossLinks: [CrossLink]
    var onCrossLink: (String) -> Void = { _ in }

    private var step: StorylineStep { node.step }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(govtColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: step.status.symbolName)
                        .foregroundStyle(step.status.tint)
                    Text("Step \(step.stepNumber)").novaFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(step.status.label.uppercased())
                        .novaFont(.caption, weight: .bold)
                        .foregroundStyle(step.status.tint)
                }
                Text(step.displayName)
                    .novaFont(.body, weight: .bold)
                    .foregroundStyle(EVTheme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(shortObjective)
                    .novaFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if !crossLinks.isEmpty || !node.deadEndOutcomes.isEmpty { footer }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(bgColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(step.status.tint.opacity(isSelected ? 1 : 0.55),
                              lineWidth: isSelected ? 2.5 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // A drop shadow forces an offscreen render pass per view; with
        // potentially many cards on screen at once that compositing cost is a
        // real contributor to lag on iPhone, so only the selected card pays.
        .shadow(color: isSelected ? .black.opacity(0.35) : .clear, radius: isSelected ? 8 : 0, y: 2)
        .opacity(step.status == .locked && !isSelected ? 0.82 : 1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let link = crossLinks.first {
                Button { onCrossLink(link.key) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: link.outgoing ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left")
                        Text(link.key)
                    }
                }
                .buttonStyle(.plain)
                .novaFont(.caption, weight: .bold)
                .foregroundStyle(EVTheme.accent)
                .lineLimit(1)
            }
            if !node.deadEndOutcomes.isEmpty {
                Label("Dead end", systemImage: "xmark.octagon")
                    .novaFont(.caption).foregroundStyle(.red.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var bgColor: Color {
        step.status == .locked ? Color(white: 0.11) : step.status.tint.opacity(0.12)
    }

    private var shortObjective: String {
        switch step.status {
        case .locked:    return step.blockers.isEmpty ? "Prerequisites not met" : "Locked — tap to see how to unlock"
        case .available: return step.offeredAt
        default:         return step.objective
        }
    }
}

// MARK: - Node inspector

private struct NodeInspector: View {
    let node: StoryMapNode
    let govtName: String?
    let crossLinks: [CrossLink]
    var onJump: (String) -> Void = { _ in }
    var onClose: () -> Void

    private var step: StorylineStep { node.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: step.status.symbolName).foregroundStyle(step.status.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.displayName).novaFont(.body, weight: .bold)
                    Text("\(node.storylineKey) · Step \(step.stepNumber) · \(step.status.label)")
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(EVTheme.text.opacity(0.6))
            }

            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    field("Objective", step.objective)
                    field("Reward", step.reward)
                    if step.status == .available { field("Get it at", step.offeredAt) }
                    if let govtName { field("Government", govtName) }

                    if step.status == .locked {
                        Text("How to unlock").novaFont(.caption, weight: .bold)
                            .foregroundStyle(EVTheme.accent).padding(.top, 2)
                        if step.blockers.isEmpty {
                            Text("Prerequisites not yet met.").novaFont(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(step.blockers, id: \.bit) { b in unlockHint(b) }
                        }
                    }

                    if !node.deadEndOutcomes.isEmpty {
                        Text("Can end the story here").novaFont(.caption, weight: .bold)
                            .foregroundStyle(.red.opacity(0.85)).padding(.top, 2)
                        Text("On \(node.deadEndOutcomes.map(\.rawValue).joined(separator: " or ")), this line may end rather than continue.")
                            .novaFont(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(crossLinks) { link in
                        Button { onJump(link.key) } label: {
                            Text(link.outgoing ? "→ Leads into the \(link.key) campaign"
                                               : "← Started from the \(link.key) campaign")
                                .novaFont(.caption, weight: .bold)
                        }
                        .buttonStyle(.plain).foregroundStyle(EVTheme.accent).padding(.top, 2)
                    }

                    if !step.synopsis.isEmpty {
                        Divider().opacity(0.2).padding(.vertical, 2)
                        Text(step.synopsis).novaFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    private func unlockHint(_ b: BlockingBit) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(EVTheme.accent)
            if let src = b.unlockedBy.first {
                Text("\(src.hint)\(b.unlockedBy.count > 1 ? " (or others)" : "")").novaFont(.caption)
            } else {
                Text("Needs bit \(b.bit) \(b.needsSet ? "set" : "cleared") — source unknown (may be a plug-in).")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        (Text("\(label): ")
            .font(.custom(NovaFontRole.caption.family, size: NovaFontRole.caption.baseSize).bold())
            .foregroundColor(.secondary)
         + Text(value)
            .font(.custom(NovaFontRole.caption.family, size: NovaFontRole.caption.baseSize)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Story Map") {
    StorylineMapView(model: .sample)
        .frame(width: 900, height: 620)
}
