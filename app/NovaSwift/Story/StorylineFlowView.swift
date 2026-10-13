import SwiftUI
import NovaSwiftStory

/// A request from the hero's "Show step" button (or any caller) to scroll to a
/// step and expand it. The nonce makes repeated requests for the same step fire.
struct StoryStepFocus: Equatable {
    let id: Int
    let nonce = UUID()
    init(id: Int) { self.id = id }
}

/// The heart of the redesigned Story Guide: one storyline drawn as a clean
/// **vertical timeline** — a spine that turns green along completed steps, state
/// nodes (check / target with a pulsing halo / sparkles / lock / checkered flag),
/// a red octagon on steps that can end the campaign, and real branches in
/// indented lanes with an elbow and a labeled connector pill. Tapping a step
/// expands its full detail inline (objective, reward, and — the killer feature —
/// for a locked step exactly what to do to unlock it).
///
/// Performance: the rows come from `StoryGuideModel.flow(for:)` (built once and
/// memoized), and they render in a `LazyVStack`, so only the handful of rows on
/// screen are ever instantiated. The only per-frame work is the single pulsing
/// halo on the current step.
struct StorylineFlowView: View {
    @ObservedObject var model: StoryGuideModel
    let storylineKey: String
    var focusRequest: StoryStepFocus?
    var onSwitchStoryline: (String) -> Void = { _ in }
    var onAbort: ((Int) -> Void)?

    @State private var expandedID: Int?

    private var rows: [StoryFlowRow] { model.flow(for: storylineKey) }

    var body: some View {
        let rows = self.rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        StoryFlowRowView(
                            row: row, model: model,
                            rail: railInfo(rows, index),
                            isExpanded: expandedID == row.id,
                            canAbort: canAbort(row),
                            onTap: { toggle(row.id) },
                            onJump: { id in jump(to: id, proxy: proxy) },
                            onSwitchStoryline: onSwitchStoryline,
                            onAbort: onAbort)
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: 820, alignment: .leading)   // don't stretch to full ultrawide
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .cursorScrollable()
            .onChange(of: storylineKey) { _, _ in expandedID = nil; scrollToCurrent(proxy) }
            .onChange(of: focusRequest) { _, req in
                if let req { jump(to: req.id, proxy: proxy) }
            }
            .onAppear { scrollToCurrent(proxy) }
        }
    }

    private func railInfo(_ rows: [StoryFlowRow], _ i: Int) -> StoryRailInfo {
        let row = rows[i]
        let last = i == rows.count - 1
        return StoryRailInfo(
            status: row.step.status, depth: row.depth, isCurrent: row.isCurrent,
            isFirst: i == 0, isLast: last,
            prevDepth: i > 0 ? rows[i - 1].depth : 0,
            nextDepth: last ? 0 : rows[i + 1].depth,
            prevDone: i > 0 && rows[i - 1].step.status == .completed,
            isFinal: last && row.depth == 0,
            canEnd: !row.node.deadEndOutcomes.isEmpty,
            elbow: row.connector.label == nil ? Color.white.opacity(0.2) : row.connector.tint)
    }

    /// Bring the pilot's current step into view when a storyline opens, so the
    /// flow lands on "where you are" rather than at the top of a finished
    /// campaign. Deferred a runloop tick so the lazy rows exist to scroll to.
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = model.currentStepID(forKey: storylineKey) else { return }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(current, anchor: .center) }
        }
    }

    private func toggle(_ id: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id) ? nil : id
        }
    }

    private func jump(to id: Int, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            expandedID = id
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Whether this step's active mission may be aborted (from the live pilot's
    /// mission list) — gates the inline Abort action so it never appears on a
    /// mission the game forbids aborting.
    private func canAbort(_ row: StoryFlowRow) -> Bool {
        guard row.step.status == .active, onAbort != nil else { return false }
        return model.pilot.activeMissions.first { $0.id == row.id }?.canAbort ?? false
    }
}

// MARK: - Timeline rail

/// Everything the gutter beside a card needs to draw its spine, elbow and node.
struct StoryRailInfo {
    let status: MissionStatus
    let depth: Int
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    let prevDepth: Int
    let nextDepth: Int
    let prevDone: Bool
    let isFinal: Bool
    let canEnd: Bool
    let elbow: Color
}

/// The gutter: lane lines, the progress-coloured spine, the branch elbow and the
/// state node (pulsing halo on the current step).
private struct StoryTimelineRail: View {
    let info: StoryRailInfo

    private let lane: CGFloat = 24
    private let nodeY: CGFloat = 24
    private func x(_ level: Int) -> CGFloat { 22 + CGFloat(level) * lane }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let faint = Color.white.opacity(0.13)
                let good = EVTheme.done.opacity(0.55)
                func line(_ a: CGPoint, _ b: CGPoint, _ color: Color) {
                    var p = Path(); p.move(to: a); p.addLine(to: b)
                    ctx.stroke(p, with: .color(color), lineWidth: 2)
                }
                for l in 0..<info.depth {
                    line(CGPoint(x: x(l), y: 0), CGPoint(x: x(l), y: size.height), faint)
                }
                let cx = x(info.depth)
                if !info.isFirst && info.prevDepth >= info.depth {
                    line(CGPoint(x: cx, y: 0), CGPoint(x: cx, y: nodeY), info.prevDone ? good : faint)
                }
                if !info.isLast && info.nextDepth >= info.depth {
                    line(CGPoint(x: cx, y: nodeY), CGPoint(x: cx, y: size.height),
                         info.status == .completed ? good : faint)
                }
                if info.depth > 0 && (info.isFirst || info.prevDepth < info.depth) {
                    line(CGPoint(x: x(info.depth - 1), y: nodeY), CGPoint(x: cx, y: nodeY), info.elbow)
                }
            }
            node.position(x: x(info.depth), y: nodeY)
        }
        .frame(width: 44 + CGFloat(info.depth) * lane)
        .frame(maxHeight: .infinity)
    }

    private var tint: Color { info.status.tint }

    @ViewBuilder private var node: some View {
        ZStack {
            Circle().fill(EVTheme.panel).frame(width: 30, height: 30)
            if info.isCurrent { StoryPulseHalo(tint: tint) }
            if info.status == .locked {
                Circle().fill(Color(white: 0.14)).frame(width: 22, height: 22)
                Circle().strokeBorder(tint.opacity(0.4), lineWidth: 1.5).frame(width: 22, height: 22)
                Image(systemName: info.isFinal ? "flag.checkered" : "lock.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint.opacity(0.85))
            } else {
                Image(systemName: info.status.symbolName)
                    .font(.system(size: info.isCurrent ? 18 : 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            if info.canEnd && info.status != .completed {
                ZStack {
                    Circle().fill(EVTheme.panel).frame(width: 15, height: 15)
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(EVTheme.fail)
                }
                .offset(x: 10, y: 10)
            }
        }
    }
}

// MARK: - Row

private struct StoryFlowRowView: View {
    let row: StoryFlowRow
    @ObservedObject var model: StoryGuideModel
    let rail: StoryRailInfo
    let isExpanded: Bool
    let canAbort: Bool
    var onTap: () -> Void
    var onJump: (Int) -> Void
    var onSwitchStoryline: (String) -> Void
    var onAbort: ((Int) -> Void)?

    private var step: StorylineStep { row.step }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            StoryTimelineRail(info: rail)
            card
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            FlowLayout(spacing: 7) {
                if let label = row.connector.label { ConnectorPill(connector: row.connector, text: label) }
                Text("Step \(step.stepNumber)").novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.dim)
                if row.isCurrent {
                    StoryPill(text: "YOU ARE HERE", tint: EVTheme.accent, symbol: "location.fill")
                }
                if step.status == .locked {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(EVTheme.lock.opacity(0.8))
                } else {
                    StatusBadge(status: step.status)
                }
            }

            TokenText(step.displayName)
                .novaFont(.body, weight: .bold)
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)

            TokenText(summaryLine)
                .novaFont(.caption)
                .foregroundStyle(EVTheme.dim)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if isExpanded { expandedDetail }

            if !chips.isEmpty {
                FlowLayout(spacing: 6) { ForEach(chips) { $0.view } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(step.status.tint.opacity(isExpanded ? 0.85 : (row.isCurrent ? 0.65 : (step.status == .locked ? 0.18 : 0.3))),
                              lineWidth: isExpanded || row.isCurrent ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .cursorClickable(onTap)
        .padding(.bottom, 12)
    }

    private var titleColor: Color {
        switch step.status {
        case .completed: return Color(red: 0.8, green: 0.88, blue: 0.8)
        case .locked:    return EVTheme.dim
        default:         return EVTheme.text
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(step.status == .locked
                  ? EVTheme.card
                  : EVTheme.card.blended(with: step.status.tint, by: isExpanded ? 0.16 : (row.isCurrent ? 0.11 : 0.06)))
    }

    // MARK: Summary + detail

    private var summaryLine: String {
        switch step.status {
        case .locked:
            if step.blockers.isEmpty { return "Prerequisites not yet met." }
            if let hint = step.blockers.compactMap({ $0.unlockedBy.first?.hint }).first {
                return "Unlocks after: \(hint)"
            }
            return "Select to see what is needed."
        case .available: return "Available now - \(step.offeredAt)"
        case .active, .completed: return step.objective
        }
    }

    @ViewBuilder private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 2)

            if step.status != .locked { field("target", "Objective", step.objective) }
            field("gift.fill", "Reward", step.reward)
            if step.status == .available { field("mappin.circle.fill", "Get it at", step.offeredAt) }
            if let govt = model.governmentName(step.governmentID) { field("person.2.fill", "Government", govt) }

            if step.status == .locked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open.fill").font(.caption).foregroundStyle(EVTheme.accent)
                    Text("HOW TO UNLOCK").novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.accent)
                }
                .padding(.top, 2)
                if step.blockers.isEmpty {
                    Text("Prerequisites not yet met.").novaFont(.caption).foregroundStyle(EVTheme.dim)
                } else {
                    ForEach(step.blockers, id: \.bit) { unlockHint($0) }
                }
            }

            if !step.synopsis.isEmpty {
                TokenText(step.synopsis).novaFont(.caption).foregroundStyle(EVTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
            }

            if canAbort, let onAbort {
                Button(role: .destructive) { onAbort(row.id) } label: {
                    Label("Abort mission", systemImage: "xmark.octagon.fill")
                        .novaFont(.caption, weight: .bold)
                        .foregroundStyle(EVTheme.fail)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(EVTheme.fail.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(EVTheme.fail.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.novaPlain).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unlockHint(_ b: BlockingBit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                .foregroundStyle(b.unlockedBy.isEmpty ? EVTheme.dim : EVTheme.accent).padding(.top, 3)
            if let src = b.unlockedBy.first {
                TokenText("\(src.hint)\(b.unlockedBy.count > 1 ? " (or others)" : "")").novaFont(.caption)
            } else {
                Text("Needs bit \(b.bit) \(b.needsSet ? "set" : "cleared") - source unknown (may be a plug-in).")
                    .novaFont(.caption).foregroundStyle(EVTheme.dim)
            }
        }
    }

    private func field(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(EVTheme.accent)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased()).novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.dim)
                TokenText(value).novaFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chips (dead-ends, jumps, cross-links)

    private struct Chip: Identifiable {
        let id: String
        let view: AnyView
    }

    private var chips: [Chip] {
        var out: [Chip] = []
        if !row.node.deadEndOutcomes.isEmpty {
            let outcomes = row.node.deadEndOutcomes.map(\.rawValue).joined(separator: " / ")
            out.append(Chip(id: "deadend", view: AnyView(
                StoryPill(text: "Can end here - \(outcomes)", tint: EVTheme.fail, symbol: "xmark.octagon.fill"))))
        }
        for jump in row.jumps {
            let label = jump.connector.label ?? "Leads to"
            out.append(Chip(id: "jump-\(jump.targetID)", view: AnyView(
                tapChip("\(label) -> \(StoryTokens.plain(jump.targetName))",
                        systemImage: jump.connector.label == nil ? "arrow.triangle.merge" : (jump.connector.symbol ?? "arrow.triangle.merge"),
                        tint: jump.connector.tint) {
                    onJump(jump.targetID)
                })))
        }
        for link in row.crossLinks {
            let text = link.outgoing ? "Leads into \(link.key)" : "From \(link.key)"
            out.append(Chip(id: "cross-\(link.id)", view: AnyView(
                tapChip(text, systemImage: link.outgoing ? "book.fill" : "arrow.triangle.branch",
                        tint: EVTheme.accent) { onSwitchStoryline(link.key) })))
        }
        return out
    }

    private func tapChip(_ text: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .novaFont(.caption, weight: .bold).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.novaPlain)
    }
}

// MARK: - Small components

/// The branch label ("On refuse", "50/50 chance", ...) that heads a non-linear
/// step, so the reader sees at a glance why the flow forked here.
private struct ConnectorPill: View {
    let connector: StoryConnector
    let text: String

    var body: some View {
        StoryPill(text: text.uppercased(), tint: connector.tint, symbol: connector.symbol)
    }
}

/// The state badge on a step card (replaces repeating "LOCKED" text).
private struct StatusBadge: View {
    let status: MissionStatus
    var body: some View {
        StoryPill(text: status.label, tint: status.tint, symbol: status.symbolName)
    }
}

private extension Color {
    /// Linear blend toward `other` (Color.mix needs iOS 18 / macOS 15; we target 17 / 14).
    func blended(with other: Color, by amount: Double) -> Color {
        #if canImport(UIKit)
        let a = UIColor(self), b = UIColor(other)
        #else
        let a = NSColor(self), b = NSColor(other)
        #endif
        var (r1, g1, b1, a1) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        #if canImport(UIKit)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        #else
        (a.usingColorSpace(.sRGB) ?? a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        (b.usingColorSpace(.sRGB) ?? b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        #endif
        let t = CGFloat(amount)
        return Color(red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t), blue: Double(b1 + (b2 - b1) * t))
    }
}

/// A minimal wrapping HStack for the chip row — wraps to the next line when it
/// runs out of width, so a step with several jump/cross-link chips never
/// clips or forces horizontal scrolling.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Story Flow") {
    StorylineFlowView(model: .sample, storylineKey: "Vellos")
        .frame(width: 460, height: 620)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
}
