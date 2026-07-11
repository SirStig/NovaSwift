import SwiftUI
import NovaSwiftStory

/// The **Story Map**: a full-screen, pannable/zoomable graph of the entire
/// campaign — every storyline is a column of mission nodes, colour-coded by the
/// pilot's live status (completed / in progress / available now / locked), with
/// edges linking *what unlocks what* (including across campaigns). Tapping a
/// node opens an inspector showing its objective, reward, where it's offered,
/// and — for a locked node — exactly what to do to unlock it.
///
/// This is the "see every single thing at once" view the list-style Story Guide
/// can't give: the shape of the whole game, and where the pilot sits in it.
struct StorylineMapView: View {
    let map: StoryMap
    var onClose: (() -> Void)?

    @State private var selectedID: Int?
    @State private var zoom: CGFloat = 0.85
    @State private var zoomBase: CGFloat = 0.85
    /// The scroll content's frame relative to the scroll view's own bounds
    /// (i.e. how far it's been scrolled) and the scroll view's own on-screen
    /// size — together these give us the visible viewport. Tracked manually
    /// via `GeometryReader`/`PreferenceKey` since `onScrollGeometryChange`
    /// needs iOS 18/macOS 15, newer than this app's deployment target.
    ///
    /// Drives virtualized rendering: with hundreds of missions on the map,
    /// building/shadowing a `NodeCard` for every one of them regardless of
    /// scroll position is what was driving the memory/frame-rate problems
    /// (and outright crashes on iPhone). We now only build cards and stroke
    /// edges that are actually (near) visible.
    @State private var scrollContentFrame: CGRect = .zero
    @State private var scrollContainerSize: CGSize = .zero

    private enum Layout {
        static let laneWidth: CGFloat = 226
        static let laneGap: CGFloat = 44
        static let rowPitch: CGFloat = 150
        static let nodeWidth: CGFloat = 198
        static let nodeHeight: CGFloat = 106
        static let topInset: CGFloat = 92     // room for the lane headers
        static let sideInset: CGFloat = 40
        static let bottomInset: CGFloat = 56
        static var lanePitch: CGFloat { laneWidth + laneGap }
        /// Extra invisible padding around every node's tap target, and how far
        /// zoomed-out the map may go — both exist to keep nodes comfortably
        /// tappable on iPhone (Apple's 44pt minimum) instead of shrinking under
        /// a pinch until they're nearly impossible to hit accurately.
        static let nodeHitSlop: CGFloat = 10
        static let minZoom: CGFloat = 0.55
        static let maxZoom: CGFloat = 1.75
        /// How far outside the visible viewport to still build node/edge views,
        /// so scrolling doesn't visibly pop cards in at the edge.
        static let virtualizationMargin: CGFloat = rowPitch
        /// Symmetric padding wrapping the scaled map content inside the scroll
        /// view (see `mapArea`) — needed to translate the ScrollView's reported
        /// visible rect back into unscaled map coordinates.
        static let contentPadding: CGFloat = 28
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            if map.isEmpty {
                emptyState
            } else {
                mapArea
            }
        }
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
        .novaResponsive()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.circle.fill").foregroundStyle(EVTheme.accent).font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Story Map").novaFont(.heading, weight: .bold)
                Text(subtitle).novaFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            legend
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(EVTheme.text.opacity(0.6))
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var subtitle: String {
        guard !map.isEmpty else { return "No campaigns found in this data" }
        let campaigns = map.lanes.count
        let steps = map.nodes.count
        var s = "\(campaigns) campaign\(campaigns == 1 ? "" : "s") · \(steps) missions"
        if map.untaggedCount > 0 { s += " · +\(map.untaggedCount) one-off jobs" }
        return s
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(.green, "Done")
            legendDot(.cyan, "Active")
            legendDot(.yellow, "Available")
            legendDot(.gray, "Locked")
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

    // MARK: Map canvas

    private var mapArea: some View {
        GeometryReader { outerGeo in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edgeLayer
                    laneHeaders
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
                .gesture(magnify)
            }
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
        // One dictionary build (not two), and every edge is culled against the
        // visible viewport before we bother stroking a curve for it — with a
        // large campaign graph this is the difference between drawing dozens
        // of curves and drawing hundreds.
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        let rect = logicalVisibleRect
        return Canvas { ctx, _ in
            for edge in map.edges {
                guard let fromNode = nodeByID[edge.from], let toNode = nodeByID[edge.to] else { continue }
                let a = center(fromNode)
                let b = center(toNode)
                let span = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                   width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
                guard rect.intersects(span) else { continue }
                let unlocked = fromNode.step.status == .completed
                var path = Path()
                path.move(to: a)
                let midY = (a.y + b.y) / 2
                path.addCurve(to: b,
                              control1: CGPoint(x: a.x, y: midY),
                              control2: CGPoint(x: b.x, y: midY))
                let color = unlocked ? Color.green.opacity(0.5)
                                     : (edge.kind == .starts ? EVTheme.accent.opacity(0.28)
                                                             : Color.white.opacity(0.14))
                let dash: [CGFloat] = unlocked ? [] : (edge.kind == .starts ? [] : [5, 5])
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: unlocked ? 2 : 1.3, dash: dash))
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .allowsHitTesting(false)
    }

    private var laneHeaders: some View {
        ForEach(map.lanes) { lane in
            LaneHeader(lane: lane)
                .frame(width: Layout.laneWidth - 8)
                .position(x: laneCenterX(lane.index), y: 40)
        }
    }

    private var nodeLayer: some View {
        ForEach(visibleNodes) { node in
            NodeCard(node: node, isSelected: node.id == selectedID)
                .frame(width: Layout.nodeWidth, height: Layout.nodeHeight)
                .contentShape(Rectangle())
                // Grow the tappable area beyond the visual card (symmetric,
                // transparent padding) so nodes stay comfortably tappable on
                // iPhone even when the map is pinched down toward `minZoom`.
                .padding(Layout.nodeHitSlop)
                .contentShape(Rectangle())
                .position(center(node))
                .onTapGesture { selectedID = (selectedID == node.id) ? nil : node.id }
        }
    }

    /// The visible viewport translated back into unscaled map coordinates
    /// (undoing the scroll offset, the content padding, and the pinch-zoom
    /// scale), outset by a margin so nodes are already built just before
    /// they'd scroll into view. Falls back to the whole map before the first
    /// layout pass reports real geometry.
    private var logicalVisibleRect: CGRect {
        guard scrollContainerSize != .zero else {
            return CGRect(origin: .zero, size: contentSize)
        }
        // `scrollContentFrame.origin` is how far the (padded, scaled) content
        // has been scrolled — negative as the user scrolls down/right — so the
        // visible window in that content's own coordinate space starts here.
        let visibleInContent = CGRect(x: -scrollContentFrame.minX, y: -scrollContentFrame.minY,
                                       width: scrollContainerSize.width, height: scrollContainerSize.height)
        let pad = Layout.contentPadding
        let unscaled = CGRect(x: (visibleInContent.minX - pad) / zoom,
                               y: (visibleInContent.minY - pad) / zoom,
                               width: visibleInContent.width / zoom,
                               height: visibleInContent.height / zoom)
        return unscaled.insetBy(dx: -Layout.virtualizationMargin, dy: -Layout.virtualizationMargin)
    }

    private var visibleNodes: [StoryMapNode] {
        let rect = logicalVisibleRect
        return map.nodes.filter { rect.intersects(nodeFrame($0)) }
    }

    private func nodeFrame(_ node: StoryMapNode) -> CGRect {
        let c = center(node)
        return CGRect(x: c.x - Layout.nodeWidth / 2, y: c.y - Layout.nodeHeight / 2,
                      width: Layout.nodeWidth, height: Layout.nodeHeight)
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let id = selectedID, let node = map.nodes.first(where: { $0.id == id }) {
            NodeInspector(node: node, onClose: { selectedID = nil })
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

    private func laneCenterX(_ i: Int) -> CGFloat {
        Layout.sideInset + Layout.laneWidth / 2 + CGFloat(i) * Layout.lanePitch
    }
    private func rowCenterY(_ r: Int) -> CGFloat {
        Layout.topInset + Layout.nodeHeight / 2 + CGFloat(r) * Layout.rowPitch
    }
    private func center(_ node: StoryMapNode) -> CGPoint {
        CGPoint(x: laneCenterX(node.laneIndex), y: rowCenterY(node.rowIndex))
    }

    private var contentSize: CGSize {
        let lanes = max(map.lanes.count, 1)
        let w = Layout.sideInset * 2 + CGFloat(lanes) * Layout.laneWidth
              + CGFloat(max(lanes - 1, 0)) * Layout.laneGap
        let rows = max(map.maxRows, 1)
        let h = Layout.topInset + CGFloat(rows) * Layout.rowPitch + Layout.bottomInset
        return CGSize(width: w, height: h)
    }

    // MARK: Empty state

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
}

// MARK: - Scroll geometry tracking

private struct ScrollContentFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Lane header

private struct LaneHeader: View {
    let lane: StoryMapLane

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(lane.title).novaFont(.body, weight: .bold).lineLimit(1)
                Spacer(minLength: 0)
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: - Node card

private struct NodeCard: View {
    let node: StoryMapNode
    let isSelected: Bool

    private var step: StorylineStep { node.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            Spacer(minLength: 0)
            Text(shortObjective)
                .novaFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(bgColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(step.status.tint.opacity(isSelected ? 1 : 0.55),
                              lineWidth: isSelected ? 2.5 : 1.5)
        )
        // A drop shadow forces an offscreen render pass per view; with
        // potentially hundreds of cards on screen at once that compositing
        // cost was a real contributor to the map's lag/crashes on iPhone, so
        // only the selected card pays for one.
        .shadow(color: isSelected ? .black.opacity(0.35) : .clear, radius: isSelected ? 8 : 0, y: 2)
        .opacity(step.status == .locked && !isSelected ? 0.82 : 1)
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
                    if step.status == .available {
                        field("Get it at", step.offeredAt)
                        field("Objective", step.objective)
                        field("Reward", step.reward)
                    } else if step.status == .active {
                        field("Objective", step.objective)
                        field("Reward", step.reward)
                    } else if step.status == .completed {
                        field("Objective", step.objective)
                        field("Reward", step.reward)
                    } else { // locked
                        field("Objective", step.objective)
                        field("Reward", step.reward)
                        Text("How to unlock").novaFont(.caption, weight: .bold)
                            .foregroundStyle(EVTheme.accent).padding(.top, 2)
                        if step.blockers.isEmpty {
                            Text("Prerequisites not yet met.").novaFont(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(step.blockers, id: \.bit) { b in unlockHint(b) }
                        }
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
    StorylineMapView(map: StoryGuideModel.sample.storyMap)
        .frame(width: 900, height: 620)
}
