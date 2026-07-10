import SwiftUI
import EVNovaStory

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
            .padding(28)
            .gesture(magnify)
        }
        .background(mapBackground)
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .bottom) { inspector }
        .animation(.easeInOut(duration: 0.18), value: selectedID)
    }

    private var mapBackground: some View {
        LinearGradient(colors: [Color(white: 0.05), Color(white: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var edgeLayer: some View {
        Canvas { ctx, _ in
            for edge in map.edges {
                guard let a = centers[edge.from], let b = centers[edge.to] else { continue }
                let unlocked = statusByID[edge.from] == .completed
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
        ForEach(map.nodes) { node in
            NodeCard(node: node, isSelected: node.id == selectedID)
                .frame(width: Layout.nodeWidth, height: Layout.nodeHeight)
                .position(center(node))
                .onTapGesture { selectedID = (selectedID == node.id) ? nil : node.id }
        }
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
    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.4), 1.75) }

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

    private var centers: [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, center($0)) })
    }
    private var statusByID: [Int: MissionStatus] {
        Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0.step.status) })
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
        .shadow(color: .black.opacity(0.35), radius: isSelected ? 8 : 3, y: 2)
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
