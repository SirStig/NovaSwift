import SwiftUI
import EVNovaStory

/// The in-game info window: the pilot's dossier (credits, ship, ranks, standings,
/// active missions) plus an aftermarket **Story Guide** — an EV-Bible-style
/// browser over every storyline showing where the pilot is and what unlocks the
/// next step. Present it as a sheet/overlay from the HUD.
///
///     StoryGuideView(model: storyGuideModel)   // model built from the live game
///
/// It also runs standalone in Xcode Previews via `StoryGuideModel.sample`.
struct StoryGuideView: View {
    @ObservedObject var model: StoryGuideModel
    @State private var tab: Tab = .pilot
    var onClose: (() -> Void)?

    enum Tab: String, CaseIterable { case pilot = "Pilot", story = "Story Guide" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider().opacity(0.3)

            switch tab {
            case .pilot: PilotInfoView(pilot: model.pilot)
            case .story: StorylineBrowserView(storylines: model.storylines,
                                              untaggedCount: model.untaggedCount)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(EVTheme.accent)
            Text("Pilot Log").font(.headline)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(EVTheme.text.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

// MARK: - Pilot dossier

struct PilotInfoView: View {
    let pilot: PilotSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Headline stats
                VStack(alignment: .leading, spacing: 6) {
                    Text(pilot.name).font(.title2.bold())
                    HStack(spacing: 16) {
                        stat("Credits", "\(pilot.credits.formatted()) cr")
                        stat("Ship", pilot.shipName)
                    }
                    HStack(spacing: 16) {
                        stat("System", pilot.currentSystem)
                        stat("Date", pilot.date)
                        stat("Combat", ratingName(pilot.combatRating))
                    }
                }

                if !pilot.ranks.isEmpty {
                    section("Ranks & Titles") {
                        ForEach(pilot.ranks, id: \.self) { r in
                            Label(r, systemImage: "rosette").font(.callout)
                        }
                    }
                }

                section("Standings") {
                    if pilot.relations.isEmpty {
                        Text("No notable reputations yet.").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(pilot.relations) { rel in
                            HStack {
                                Text(rel.govt)
                                Spacer()
                                Text(standingText(rel.standing))
                                    .foregroundStyle(rel.standing >= 0 ? .green : .red)
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }

                section("Active Missions") {
                    if pilot.activeMissions.isEmpty {
                        Text("No active missions.").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(pilot.activeMissions) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.callout.bold())
                                Text(m.objective).font(.caption).foregroundStyle(.secondary)
                                Text("Reward: \(m.reward)").font(.caption2).foregroundStyle(EVTheme.accent)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                section("Escorts") {
                    Text("No escorts hired.").foregroundStyle(.secondary).font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.bold())
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(EVTheme.accent)
            content()
        }
    }

    private func standingText(_ n: Int) -> String {
        switch n {
        case ..<(-200): return "Hunted (\(n))"
        case ..<0:      return "Wanted (\(n))"
        case 0:         return "Neutral"
        case 1..<200:   return "Liked (+\(n))"
        default:        return "Honored (+\(n))"
        }
    }

    private func ratingName(_ r: Int) -> String {
        let names = ["Harmless", "Mostly Harmless", "Poor", "Average", "Above Average",
                     "Competent", "Dangerous", "Deadly", "Elite"]
        return names[min(max(r, 0), names.count - 1)]
    }
}

#Preview("Pilot") { StoryGuideView(model: .sample) }
