import SwiftUI
import NovaSwiftStory

/// The in-game **Story Guide** — one unified window (no more Guide/Map tabs)
/// that reconstructs every EV Nova campaign from the mission control-bit graph
/// and shows the pilot exactly where they stand and what unlocks the next step.
///
/// Pick a storyline (a sidebar on a wide macOS window, a header menu on a
/// phone) and its campaign draws as a scrollable vertical **flow** — a plain
/// chain reads as a straight column, real branches indent with a labeled
/// connector, and tapping any step expands its full detail (including, for a
/// locked step, how to unlock it). The whole graph is built off the main
/// thread and each flow is memoized, so opening the window never stalls and
/// scrolling never recomputes — the fixes for the old node-graph map that
/// crashed on iPhone and felt fiddly on Mac.
///
///     StoryGuideView(model: storyGuideModel, onClose: { … })
///
/// It also runs standalone in Xcode Previews via `StoryGuideModel.sample`.
struct StoryGuideView: View {
    @ObservedObject var model: StoryGuideModel
    var onClose: (() -> Void)?
    /// Abort an active mission (by mïsn id). Wired by the game to the live pilot;
    /// nil in previews / read-only contexts, where the Abort action hides.
    var onAbort: ((Int) -> Void)?

    @State private var selectedKey: String?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    /// - Parameter initialStorylineKey: pre-select this storyline on open (e.g.
    ///   when a mission's storyline badge opened the guide) instead of the
    ///   default "first in-progress lane" — `selectDefaultLane()` still runs
    ///   as a fallback if the key doesn't match any lane once the map loads.
    init(model: StoryGuideModel, onClose: (() -> Void)? = nil, onAbort: ((Int) -> Void)? = nil,
         initialStorylineKey: String? = nil) {
        self.model = model
        self.onClose = onClose
        self.onAbort = onAbort
        _selectedKey = State(initialValue: initialStorylineKey)
    }

    private var lanes: [StoryMapLane] { model.storyMap.lanes }
    private var selectedLane: StoryMapLane? { lanes.first { $0.key == selectedKey } }

    var body: some View {
        Group {
            if model.isLoading && lanes.isEmpty {
                loadingState
            } else if lanes.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(minWidth: 300, idealWidth: 900, maxWidth: .infinity,
               minHeight: 380, maxHeight: .infinity)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
        .novaResponsive()
        .onAppear(perform: selectDefaultLane)
        .onChange(of: lanes.map(\.key)) { _, keys in
            guard !keys.isEmpty else { selectedKey = nil; return }
            if let k = selectedKey, keys.contains(k) { return }
            selectedKey = keys.first
        }
    }

    private func selectDefaultLane() {
        // Lanes are still empty while the background build is in flight (the
        // common case right on `.onAppear`, since `StoryGuideModel` kicks off
        // its rebuild in `init`) — bailing out here, rather than falling
        // through to `lanes.first?.key` (`nil`), keeps a caller-supplied
        // `initialStorylineKey` intact until the real lanes land; the
        // `onChange` below re-validates it once they do.
        guard !lanes.isEmpty else { return }
        if selectedKey == nil || !(lanes.contains { $0.key == selectedKey }) {
            selectedKey = lanes.first?.key
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if isCompact {
            VStack(spacing: 0) {
                compactHeader
                Divider().overlay(.white.opacity(0.12))
                overviewBar
                flow
            }
        } else {
            HStack(spacing: 0) {
                StorylineSidebar(lanes: lanes, untaggedCount: model.storyMap.untaggedCount,
                                 selectedKey: $selectedKey,
                                 pluginLabel: model.pluginLabel,
                                 governmentColor: model.governmentColor)
                Divider().overlay(.white.opacity(0.12))
                VStack(spacing: 0) {
                    regularHeader
                    Divider().overlay(.white.opacity(0.12))
                    overviewBar
                    flow
                }
            }
        }
    }

    @ViewBuilder private var flow: some View {
        if let key = selectedKey {
            StorylineFlowView(model: model, storylineKey: key,
                              onSwitchStoryline: { selectedKey = $0 }, onAbort: onAbort)
        } else {
            noSelectionState
        }
    }

    // MARK: Headers

    private var regularHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.pages.fill").foregroundStyle(EVTheme.accent).font(.title3)
            Text("Story Guide").novaFont(.heading, weight: .bold)
            if model.isLoading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            closeButton
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// On a phone the sidebar is gone, so the header itself is the storyline
    /// switcher.
    private var compactHeader: some View {
        HStack(spacing: 10) {
            if let lane = selectedLane {
                Circle().fill(model.governmentColor(lane.governmentID)).frame(width: 10, height: 10)
                Menu {
                    laneMenu
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lane.title).novaFont(.heading, weight: .bold).lineLimit(1)
                            Text(subtitle(lane)).novaFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.novaPlain).foregroundStyle(EVTheme.text)
            } else {
                Text("Story Guide").novaFont(.heading, weight: .bold)
            }
            Spacer(minLength: 6)
            closeButton
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var laneMenu: some View {
        ForEach(lanes) { lane in
            Button { selectedKey = lane.key } label: {
                if lane.key == selectedKey { Label(lane.title, systemImage: "checkmark") }
                else { Text(lane.title) }
            }
        }
    }

    @ViewBuilder private var closeButton: some View {
        if let onClose {
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.novaPlain).foregroundStyle(EVTheme.text.opacity(0.6))
        }
    }

    private func subtitle(_ lane: StoryMapLane) -> String {
        var parts = ["\(lane.completedCount)/\(lane.totalCount) steps", model.pluginLabel(lane.pluginID)]
        if let name = model.governmentName(lane.governmentID) { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    // MARK: Overview bar (progress + current objective)

    @ViewBuilder private var overviewBar: some View {
        if let lane = selectedLane {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !isCompact {
                        Text(lane.title).novaFont(.body, weight: .bold).lineLimit(1)
                        Text(model.pluginLabel(lane.pluginID)).novaFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if lane.isComplete {
                        Label("Complete", systemImage: "checkmark.seal.fill")
                            .novaFont(.caption, weight: .bold).foregroundStyle(.green)
                    } else {
                        Text("\(lane.completedCount) / \(lane.totalCount)")
                            .novaFont(.caption, weight: .bold).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: lane.totalCount == 0 ? 0 : Double(lane.completedCount) / Double(lane.totalCount))
                    .tint(lane.isComplete ? .green : EVTheme.accent)
                if let objective = currentObjective(lane) {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill").font(.caption2).foregroundStyle(EVTheme.accent)
                        Text(objective).novaFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            .background(Color.white.opacity(0.03))
        }
    }

    /// A one-line "here's your next objective" for the overview bar.
    private func currentObjective(_ lane: StoryMapLane) -> String? {
        guard let id = model.currentStepID(forKey: lane.key),
              let node = model.storyMap.nodes.first(where: { $0.id == id }) else { return nil }
        let verb = node.step.status == .available ? "Available" : "Next"
        return "\(verb): \(node.step.displayName)"
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 14) {
            closeRow
            Spacer()
            ProgressView().controlSize(.large)
            Text("Charting your story…").novaFont(.body).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            closeRow
            Spacer()
            Image(systemName: "book.closed").font(.system(size: 44)).foregroundStyle(.secondary)
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
            Text("Pick a storyline").novaFont(.heading).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeRow: some View {
        HStack { Spacer(); closeButton }
            .padding(.horizontal, 16).padding(.top, 12)
    }
}

// MARK: - Sidebar (wide layout only)

/// The storyline picker for the wide/macOS layout: one row per campaign, grouped
/// under a section per contributing plug-in ("Base Game" first), with a leading
/// government-color swatch and a source filter once more than one plug-in is in
/// play.
private struct StorylineSidebar: View {
    let lanes: [StoryMapLane]
    let untaggedCount: Int
    @Binding var selectedKey: String?
    let pluginLabel: (String) -> String
    let governmentColor: (Int?) -> Color

    @State private var pluginFilter: String?

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pluginLabel(group.id).uppercased())
                                .novaFont(.caption, weight: .bold).foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(group.lanes) { row($0) }
                        }
                    }
                    if untaggedCount > 0, pluginFilter == nil {
                        Text("+ \(untaggedCount) one-off jobs")
                            .novaFont(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.top, 2)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 250)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder private var filterControl: some View {
        if pluginIDs.count <= 4 {
            Picker("", selection: $pluginFilter) {
                Text("All").tag(String?.none)
                ForEach(pluginIDs, id: \.self) { Text(pluginLabel($0)).tag(String?.some($0)) }
            }
            .pickerStyle(.segmented).padding(10)
        } else {
            Menu {
                Button("All sources") { pluginFilter = nil }
                ForEach(pluginIDs, id: \.self) { id in Button(pluginLabel(id)) { pluginFilter = id } }
            } label: {
                HStack(spacing: 4) {
                    Text(pluginFilter.map(pluginLabel) ?? "All sources").novaFont(.caption, weight: .bold).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            }
            .buttonStyle(.novaPlain).padding(10)
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
                    ProgressView(value: lane.totalCount == 0 ? 0 : Double(lane.completedCount) / Double(lane.totalCount))
                        .tint(lane.isComplete ? .green : EVTheme.accent)
                    Text("\(lane.completedCount)/\(lane.totalCount) steps")
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(lane.key == selectedKey ? EVTheme.accent.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.novaPlain)
    }
}

// MARK: - Shared palette

/// A tiny self-contained palette so the Story UI stays visually consistent and
/// doesn't hard-depend on other agents' branding code.
enum EVTheme {
    static let panel = Color(white: 0.09)
    static let text = Color(white: 0.92)
    static let accent = Color(red: 0.98, green: 0.75, blue: 0.35)   // warm amber, matches the app icon
}

#Preview("Story Guide") { StoryGuideView(model: .sample) }
