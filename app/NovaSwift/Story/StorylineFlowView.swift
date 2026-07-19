import SwiftUI
import NovaSwiftStory

/// The heart of the redesigned Story Guide: one storyline drawn as a clean
/// **vertical flow** — a timeline you scroll, where a plain campaign reads as a
/// straight column and real branches indent with a labeled connector. Tapping a
/// step expands its full detail inline (objective, reward, and — the killer
/// feature — for a locked step exactly what to do to unlock it).
///
/// Performance: the rows come from `StoryGuideModel.flow(for:)` (built once and
/// memoized), and they render in a `LazyVStack`, so only the handful of rows on
/// screen are ever instantiated. There is no Canvas, no pan/zoom, and nothing
/// recomputed per frame — the whole class of iPhone stalls the old node-graph
/// map suffered simply cannot happen here.
struct StorylineFlowView: View {
    @ObservedObject var model: StoryGuideModel
    let storylineKey: String
    var onSwitchStoryline: (String) -> Void = { _ in }
    var onAbort: ((Int) -> Void)?

    @State private var expandedID: Int?

    private var rows: [StoryFlowRow] { model.flow(for: storylineKey) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        StoryFlowRowView(
                            row: row, model: model,
                            isExpanded: expandedID == row.id,
                            isFirst: index == 0, isLast: index == rows.count - 1,
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
                .frame(maxWidth: 760, alignment: .leading)   // don't stretch to full ultrawide
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: storylineKey) { _, _ in expandedID = nil; scrollToCurrent(proxy) }
            .onAppear { scrollToCurrent(proxy) }
        }
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

// MARK: - Row

private struct StoryFlowRowView: View {
    let row: StoryFlowRow
    @ObservedObject var model: StoryGuideModel
    let isExpanded: Bool
    let isFirst: Bool
    let isLast: Bool
    let canAbort: Bool
    var onTap: () -> Void
    var onJump: (Int) -> Void
    var onSwitchStoryline: (String) -> Void
    var onAbort: ((Int) -> Void)?

    private var step: StorylineStep { row.step }
    private let indentPerLevel: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.depth > 0 { Spacer().frame(width: CGFloat(row.depth) * indentPerLevel) }
            rail
            card
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The timeline spine + status node. The node sits at the header's height; a
    // segment runs down to the next row (skipped on the last row) so the column
    // reads continuously.
    private var rail: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(isFirst ? 0 : 0.14)).frame(width: 2, height: 14)
                Rectangle().fill(.white.opacity(isLast ? 0 : 0.14)).frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Circle()
                .fill(EVTheme.panel)
                .overlay(Circle().fill(step.status.tint.opacity(step.status == .locked ? 0.5 : 0.9)))
                .overlay(Circle().strokeBorder(step.status.tint, lineWidth: row.isCurrent ? 2.5 : 1.5))
                .frame(width: row.isCurrent ? 16 : 12, height: row.isCurrent ? 16 : 12)
                .padding(.top, row.isCurrent ? 6 : 8)
        }
        .frame(width: 26)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let label = row.connector.label { ConnectorPill(connector: row.connector, text: label) }

            HStack(spacing: 6) {
                Text("Step \(step.stepNumber)").novaFont(.caption, weight: .bold).foregroundStyle(.secondary)
                if row.isCurrent {
                    Text("YOU ARE HERE").novaFont(.caption, weight: .bold)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(EVTheme.accent.opacity(0.25), in: Capsule())
                        .foregroundStyle(EVTheme.accent)
                }
                Spacer(minLength: 4)
                StatusBadge(status: step.status)
            }

            Text(step.displayName)
                .novaFont(.body, weight: .bold)
                .foregroundStyle(EVTheme.text)
                .strikethrough(step.status == .completed, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(summaryLine)
                .novaFont(.caption)
                .foregroundStyle(.secondary)
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
                .strokeBorder(step.status.tint.opacity(isExpanded ? 0.85 : (row.isCurrent ? 0.6 : 0.28)),
                              lineWidth: isExpanded || row.isCurrent ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.bottom, 10)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(step.status == .locked ? Color(white: 0.11)
                                         : step.status.tint.opacity(isExpanded ? 0.16 : 0.10))
    }

    // MARK: Summary + detail

    private var summaryLine: String {
        switch step.status {
        case .locked:    return step.blockers.isEmpty ? "Prerequisites not yet met."
                                                       : "Locked — tap to see how to unlock."
        case .available: return "Available now · \(step.offeredAt)"
        case .active:    return step.objective
        case .completed: return step.objective
        }
    }

    @ViewBuilder private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 2)

            if step.status != .locked { field("Objective", step.objective) }
            field("Reward", step.reward)
            if step.status == .available { field("Get it at", step.offeredAt) }
            if let govt = model.governmentName(step.governmentID) { field("Government", govt) }

            if step.status == .locked {
                Text("HOW TO UNLOCK").novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.accent).padding(.top, 2)
                if step.blockers.isEmpty {
                    Text("Prerequisites not yet met.").novaFont(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(step.blockers, id: \.bit) { unlockHint($0) }
                }
            }

            if !step.synopsis.isEmpty {
                Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)
                Text(step.synopsis).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canAbort, let onAbort {
                Button(role: .destructive) { onAbort(row.id) } label: {
                    Label("Abort mission", systemImage: "xmark.octagon.fill").novaFont(.caption, weight: .bold)
                }
                .buttonStyle(.novaPlain).foregroundStyle(.red).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unlockHint(_ b: BlockingBit) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(EVTheme.accent)
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
         + Text(value).font(.custom(NovaFontRole.caption.family, size: NovaFontRole.caption.baseSize)))
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
                staticChip("Can end here · \(outcomes)", systemImage: "xmark.octagon", tint: .red))))
        }
        for jump in row.jumps {
            out.append(Chip(id: "jump-\(jump.targetID)", view: AnyView(
                tapChip("\(jump.connector.label ?? "Leads to") → \(jump.targetName)",
                        systemImage: "arrow.turn.down.right", tint: jump.connector.tint) {
                    onJump(jump.targetID)
                })))
        }
        for link in row.crossLinks {
            let text = link.outgoing ? "Leads into \(link.key)" : "From \(link.key)"
            out.append(Chip(id: "cross-\(link.id)", view: AnyView(
                tapChip(text, systemImage: link.outgoing ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left",
                        tint: EVTheme.accent) { onSwitchStoryline(link.key) })))
        }
        return out
    }

    private func staticChip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .novaFont(.caption, weight: .bold).foregroundStyle(tint.opacity(0.9)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func tapChip(_ text: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .novaFont(.caption, weight: .bold).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.novaPlain)
    }
}

// MARK: - Small components

/// The branch label ("On refuse", "50/50 chance", …) that heads a non-linear
/// step, so the reader sees at a glance why the flow forked here.
private struct ConnectorPill: View {
    let connector: StoryConnector
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = connector.symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text.uppercased()).novaFont(.caption, weight: .bold)
        }
        .foregroundStyle(connector.tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(connector.tint.opacity(0.16)))
    }
}

private struct StatusBadge: View {
    let status: MissionStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName).font(.system(size: 10, weight: .semibold))
            Text(status.label.uppercased()).novaFont(.caption, weight: .bold)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(status.tint.opacity(0.14)))
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
