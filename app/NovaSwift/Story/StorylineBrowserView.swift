import SwiftUI
import NovaSwiftStory

/// The aftermarket **Story Guide**: a master/detail browser over every
/// reconstructed campaign. The left column lists storylines with progress; the
/// detail shows each step's status and — crucially — for the pilot's current
/// locked step, *what to do to unlock it* (the mission or event that sets the
/// missing control bit). This is the EV-Bible-in-game feature.
struct StorylineBrowserView: View {
    let storylines: [Storyline]
    var untaggedCount: Int = 0
    @State private var selectedKey: String?

    // On a phone the fixed 200pt master column beside the detail leaves the
    // step text cramped and oversized-looking; there the list collapses into a
    // top selector menu and the detail takes the full width. iOS-only API.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private var selected: Storyline? {
        storylines.first { $0.key == selectedKey } ?? storylines.first
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    selectorBar
                    Divider().opacity(0.3)
                    detail
                }
            } else {
                HStack(spacing: 0) {
                    list
                    Divider().opacity(0.3)
                    detail
                }
            }
        }
        .novaResponsive()
    }

    /// Compact-width storyline picker, replacing the master list a phone has no
    /// room for.
    private var selectorBar: some View {
        Menu {
            ForEach(storylines) { line in
                Button { selectedKey = line.key } label: {
                    if line.key == selected?.key { Label(line.title, systemImage: "checkmark") }
                    else { Text(line.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected?.title ?? "Storylines").novaFont(.body, weight: .bold).lineLimit(1)
                    if let line = selected {
                        Text("\(line.completedCount)/\(line.totalCount) steps")
                            .novaFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(EVTheme.text)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(storylines) { line in
                    Button { selectedKey = line.key } label: { row(line) }
                        .buttonStyle(.plain)
                }
                if untaggedCount > 0 {
                    Text("+ \(untaggedCount) one-off jobs")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 6)
                }
            }
            .padding(8)
        }
        .frame(width: 200)
    }

    private func row(_ line: Storyline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(line.title).novaFont(.body, weight: .bold).lineLimit(1)
                Spacer()
                if line.isComplete { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption) }
            }
            ProgressView(value: line.progressFraction).tint(EVTheme.accent)
            Text("\(line.completedCount)/\(line.totalCount) steps")
                .novaFont(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(line.key == (selected?.key) ? EVTheme.accent.opacity(0.18) : Color.clear))
    }

    @ViewBuilder private var detail: some View {
        if let line = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(line.title).novaFont(.heading, weight: .bold)
                    ForEach(line.steps) { step in
                        StepRow(step: step, isCurrent: step.missionID == line.currentStepID)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack { Spacer(); Text("No storylines found.").novaFont(.body).foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }
}

/// One step in a storyline, with status, objective, reward, and (when locked)
/// the "how to unlock" guidance derived from the control-bit graph.
private struct StepRow: View {
    let step: StorylineStep
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.status.symbolName)
                .foregroundStyle(step.status.tint)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(step.stepNumber). \(step.displayName)")
                        .novaFont(.body, weight: .bold)
                        .strikethrough(step.status == .completed, color: .secondary)
                    if isCurrent {
                        Text("YOU ARE HERE").novaFont(.caption, weight: .bold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(EVTheme.accent.opacity(0.25), in: Capsule())
                    }
                }
                Text(step.status.label).novaFont(.caption).foregroundStyle(step.status.tint)

                if step.status == .available {
                    detailLine("Get it at", step.offeredAt)
                    detailLine("Objective", step.objective)
                    detailLine("Reward", step.reward)
                } else if step.status == .active {
                    detailLine("Objective", step.objective)
                    detailLine("Reward", step.reward)
                } else if step.status == .locked {
                    if step.blockers.isEmpty {
                        Text("Prerequisites not yet met.").novaFont(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(step.blockers, id: \.bit) { b in
                            unlockHint(b)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isCurrent ? EVTheme.accent.opacity(0.10) : EVTheme.text.opacity(0.04)))
    }

    private func unlockHint(_ b: BlockingBit) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(EVTheme.accent)
            if let src = b.unlockedBy.first {
                Text("To unlock: **\(src.hint)**\(b.unlockedBy.count > 1 ? " (or others)" : "")")
                    .novaFont(.caption)
            } else {
                Text("To unlock: needs bit \(b.bit) \(b.needsSet ? "set" : "cleared") — source unknown (may be a plug-in).")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").font(.custom(NovaFontRole.caption.family, size: NovaFontRole.caption.baseSize).bold()).foregroundStyle(.secondary)
            + Text(value).font(.custom(NovaFontRole.caption.family, size: NovaFontRole.caption.baseSize)))
    }
}

/// A tiny self-contained palette so the Story UI stays visually consistent and
/// doesn't hard-depend on other agents' branding code.
enum EVTheme {
    static let panel = Color(white: 0.09)
    static let text = Color(white: 0.92)
    static let accent = Color(red: 0.98, green: 0.75, blue: 0.35)   // warm amber, matches the app icon
}

#Preview("Story Guide") {
    StorylineBrowserView(storylines: StoryGuideModel.sample.storylines, untaggedCount: 537)
        .frame(width: 640, height: 560)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
}
