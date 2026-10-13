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
    @State private var query = ""
    @State private var focusRequest: StoryStepFocus?

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
        chrome
        .background { keyShortcuts }
        .frame(minWidth: 300, idealWidth: 900, maxWidth: .infinity,
               minHeight: 380, maxHeight: .infinity)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
        .novaResponsive()
        .cursorCancel(onClose)
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

    /// The whole window: header, body (sidebar + hero + timeline), input-hint footer.
    @ViewBuilder private var chrome: some View {
        VStack(spacing: 0) {
            if isCompact && selectedLane != nil { compactHeader } else { regularHeader }
            Divider().overlay(.white.opacity(0.12))
            if model.isLoading && lanes.isEmpty {
                loadingState
            } else if lanes.isEmpty {
                emptyState
            } else {
                content
            }
            StoryGuideFooter()
        }
    }

    @ViewBuilder private var content: some View {
        if isCompact {
            VStack(spacing: 0) {
                if !lanes.isEmpty { searchRow }
                StoryHero(model: model, lane: selectedLane, compact: true, onShowStep: showCurrentStep)
                StoryLegend()
                Divider().overlay(.white.opacity(0.12))
                flow
            }
        } else {
            HStack(spacing: 0) {
                StorylineSidebar(lanes: lanes, untaggedCount: model.storyMap.untaggedCount,
                                 selectedKey: $selectedKey, query: query, model: model)
                Divider().overlay(.white.opacity(0.12))
                VStack(spacing: 0) {
                    StoryHero(model: model, lane: selectedLane, compact: false, onShowStep: showCurrentStep)
                    StoryLegend()
                    Divider().overlay(.white.opacity(0.12))
                    flow
                }
            }
        }
    }

    @ViewBuilder private var flow: some View {
        if let key = selectedKey {
            StorylineFlowView(model: model, storylineKey: key, focusRequest: focusRequest,
                              onSwitchStoryline: { selectedKey = $0 }, onAbort: onAbort)
        } else {
            noSelectionState
        }
    }

    private func showCurrentStep() {
        guard let key = selectedKey, let id = model.currentStepID(forKey: key) else { return }
        focusRequest = StoryStepFocus(id: id)
    }

    /// PgUp / PgDn (and the compact switcher) step through storylines.
    private func cycleLane(by delta: Int) {
        guard !lanes.isEmpty else { return }
        let i = lanes.firstIndex { $0.key == selectedKey } ?? 0
        selectedKey = lanes[((i + delta) % lanes.count + lanes.count) % lanes.count].key
    }

    // MARK: Headers

    private var bookTile: some View {
        Image(systemName: "book.pages.fill")
            .font(.system(size: 20, weight: .semibold)).foregroundStyle(EVTheme.accent)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(EVTheme.accent.opacity(0.18)))
    }

    private var regularHeader: some View {
        HStack(spacing: 12) {
            bookTile
            VStack(alignment: .leading, spacing: 1) {
                Text("Story Guide").novaFont(.heading, weight: .bold)
                if model.isLoading {
                    Label("Charting your story...", systemImage: "clock")
                        .novaFont(.caption).foregroundStyle(EVTheme.dim)
                }
            }
            Spacer(minLength: 8)
            if !lanes.isEmpty && !isCompact { searchField.frame(maxWidth: 280) }
            closeButton
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.white.opacity(0.035))
    }

    /// On a phone the sidebar is gone, so the header itself is the storyline
    /// switcher.
    private var compactHeader: some View {
        HStack(spacing: 10) {
            if let lane = selectedLane {
                Circle().fill(model.governmentColor(lane.governmentID)).frame(width: 10, height: 10)
                PadCycleMenu(cycle: { cycleLane(by: 1) }) {
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
                .foregroundStyle(EVTheme.text)
            } else {
                Text("Story Guide").novaFont(.heading, weight: .bold)
            }
            Spacer(minLength: 6)
            closeButton
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var filteredLanes: [StoryMapLane] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? lanes : lanes.filter { $0.title.lowercased().contains(q) }
    }

    @ViewBuilder private var laneMenu: some View {
        ForEach(filteredLanes) { lane in
            Button { selectedKey = lane.key } label: {
                if lane.key == selectedKey { Label(lane.title, systemImage: "checkmark") }
                else { Text(lane.title) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(EVTheme.dim)
            TextField("Search storylines", text: $query)
                .textFieldStyle(.plain)
                .novaFont(.body)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.novaPlain).foregroundStyle(EVTheme.dim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
    }

    private var searchRow: some View {
        searchField.padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var closeButton: some View {
        if let onClose {
            let button = Button(action: onClose) {
                Label("Close", systemImage: "xmark").novaFont(.button, weight: .semibold)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.10)))
            }
            .buttonStyle(.novaPlain).foregroundStyle(EVTheme.text)
            #if os(tvOS)
            button
            #else
            button.keyboardShortcut(.cancelAction)
            #endif
        }
    }

    private func subtitle(_ lane: StoryMapLane) -> String {
        var parts = ["\(lane.completedCount)/\(lane.totalCount) steps", model.pluginLabel(lane.pluginID)]
        if let name = model.governmentName(lane.governmentID) { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "map").font(.system(size: 52)).foregroundStyle(.white.opacity(0.25))
            Text("Charting your story...").novaFont(.body, weight: .semibold).foregroundStyle(EVTheme.dim)
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
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

    /// Hidden PgUp / PgDn shortcuts (keyboard storyline cycling, like the Godot guide).
    @ViewBuilder private var keyShortcuts: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Group {
            Button("") { cycleLane(by: 1) }.keyboardShortcut(.pageDown, modifiers: [])
            Button("") { cycleLane(by: -1) }.keyboardShortcut(.pageUp, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        #endif
    }
}

// MARK: - Hero (progress ring, badges, next-up callout)

private struct StoryHero: View {
    @ObservedObject var model: StoryGuideModel
    let lane: StoryMapLane?
    let compact: Bool
    var onShowStep: () -> Void

    var body: some View {
        if let lane {
            let state = model.laneState(lane)
            let tag = model.governmentColor(lane.governmentID)
            let fraction = lane.totalCount == 0 ? 0 : Double(lane.completedCount) / Double(lane.totalCount)
            let barTint = state == .complete ? EVTheme.done : EVTheme.accent
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    StoryProgressRing(fraction: fraction, tint: barTint, complete: state == .complete)
                        .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lane.title).novaFont(.heading, weight: .bold).lineLimit(1)
                        FlowLayout(spacing: 6) {
                            StoryPill(text: model.pluginLabel(lane.pluginID), tint: EVTheme.dim,
                                      symbol: lane.pluginID.isEmpty ? "star.fill" : "square.stack.3d.up")
                            if let name = model.governmentName(lane.governmentID) {
                                StoryPill(text: name, tint: tag, symbol: "person.2.fill")
                            }
                            StoryPill(text: state.label, tint: state.tint, symbol: state.symbol)
                        }
                    }
                    Spacer(minLength: 4)
                    Text("\(lane.completedCount) / \(lane.totalCount) steps")
                        .novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.dim)
                        .fixedSize()
                }
                StoryCapsuleBar(fraction: fraction, tint: barTint, height: 8)
                if let node = model.currentNode(forKey: lane.key) { callout(node) }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(tag.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tag.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, compact ? 12 : 18).padding(.top, compact ? 6 : 14).padding(.bottom, 8)
        }
    }

    private func callout(_ node: StoryMapNode) -> some View {
        let available = node.step.status == .available
        let tint = available ? EVTheme.avail : EVTheme.active
        return HStack(spacing: 10) {
            Image(systemName: "location.fill").font(.system(size: 16)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(available ? "AVAILABLE NOW" : "NEXT UP")
                    .novaFont(.caption, weight: .bold).foregroundStyle(tint)
                TokenText(node.step.displayName).novaFont(.body, weight: .semibold).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button(action: onShowStep) {
                Label("Show step", systemImage: "arrow.right").novaFont(.caption, weight: .bold)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.10)))
            }
            .buttonStyle(.novaPlain).foregroundStyle(EVTheme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

/// "Done / You are here / Available / Locked / Possible ending" key.
private struct StoryLegend: View {
    var body: some View {
        FlowLayout(spacing: 16) {
            item("checkmark.circle.fill", "Done", EVTheme.done)
            item("target", "You are here", EVTheme.active)
            item("sparkles", "Available", EVTheme.avail)
            item("lock.fill", "Locked", EVTheme.lock)
            item("xmark.octagon.fill", "Possible ending", EVTheme.fail)
        }
        .padding(.horizontal, 18).padding(.bottom, 8).padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ symbol: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            Text(label).novaFont(.caption).foregroundStyle(EVTheme.dim)
        }
    }
}

// MARK: - Footer (input hints that follow the connected device)

private struct StoryGuideFooter: View {
    @ObservedObject private var padState = PadState.shared

    private var show: Bool {
        #if os(macOS)
        return true
        #else
        return padState.isConnected
        #endif
    }

    var body: some View {
        if show {
            VStack(spacing: 0) {
                Divider().overlay(.white.opacity(0.10))
                FlowLayout(spacing: 18) {
                    if padState.isConnected {
                        hint(padKey(.buttonA), "open / close")
                        hint(padKey(.buttonB), "back")
                        hint(cap("R-Stick"), "scroll")
                    } else {
                        hint(cap("Click"), "open / close")
                        hint(cap("Esc"), "back")
                        hint(cap("Wheel"), "scroll")
                        hint(cap("PgUp / PgDn"), "storyline")
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hint(_ key: some View, _ what: String) -> some View {
        HStack(spacing: 6) {
            key
            Text(what).novaFont(.caption).foregroundStyle(EVTheme.dim)
        }
    }

    private func cap(_ text: String) -> some View {
        Text(text).novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.10)))
    }

    /// The connected pad's own glyph for a button (Ⓐ on Xbox, ✕ on DualSense), else its name.
    @ViewBuilder private func padKey(_ button: PadButton) -> some View {
        if let name = button.symbolName(on: padState.pad) {
            Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(EVTheme.accent)
        } else {
            cap(button.displayName(on: padState.pad))
        }
    }
}

// MARK: - Sidebar (wide layout only)

/// The storyline picker for the wide/macOS layout: one row per campaign (tag
/// stripe, capsule progress, "n/N steps", status badge), grouped under a section
/// per contributing plug-in ("Base Game" first) with a source filter once more
/// than one plug-in is in play. `query` filters by title.
private struct StorylineSidebar: View {
    let lanes: [StoryMapLane]
    let untaggedCount: Int
    @Binding var selectedKey: String?
    let query: String
    @ObservedObject var model: StoryGuideModel

    @State private var pluginFilter: String?

    private func pluginLabel(_ id: String) -> String { model.pluginLabel(id) }

    private var pluginIDs: [String] {
        Array(Set(lanes.map(\.pluginID))).sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }   // Base Game always first
            return pluginLabel(a) < pluginLabel(b)
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var groups: [(id: String, lanes: [StoryMapLane])] {
        let ids = pluginFilter.map { [$0] } ?? pluginIDs
        let q = trimmedQuery
        return ids.compactMap { id in
            let ls = lanes.filter { $0.pluginID == id && (q.isEmpty || $0.title.lowercased().contains(q)) }
            return ls.isEmpty ? nil : (id, ls)
        }
    }

    var body: some View {
        let groups = self.groups
        VStack(spacing: 0) {
            if pluginIDs.count > 1 { filterControl }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: group.id.isEmpty ? "star.fill" : "square.stack.3d.up")
                                    .font(.system(size: 11)).foregroundStyle(EVTheme.dim)
                                Text(pluginLabel(group.id).uppercased())
                                    .novaFont(.caption, weight: .bold).foregroundStyle(EVTheme.dim)
                                Text("\(group.lanes.count)")
                                    .novaFont(.caption).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 4)
                            ForEach(group.lanes) { row($0) }
                        }
                    }
                    if groups.isEmpty {
                        Text("No storylines match.").novaFont(.caption).foregroundStyle(EVTheme.dim)
                            .padding(.horizontal, 4)
                    }
                    if untaggedCount > 0, pluginFilter == nil, trimmedQuery.isEmpty {
                        Text("+ \(untaggedCount) one-off jobs")
                            .novaFont(.caption).foregroundStyle(EVTheme.dim)
                            .padding(.horizontal, 4).padding(.top, 2)
                    }
                }
                .padding(10)
            }
            .cursorScrollable()
        }
        .frame(width: 280)
        .background(EVTheme.side)
    }

    @ViewBuilder private var filterControl: some View {
        if pluginIDs.count <= 4 {
            NovaSegmentedPicker(selection: $pluginFilter,
                                options: [String?.none] + pluginIDs.map { String?.some($0) }) {
                $0.map(pluginLabel) ?? "All"
            }
            .padding(10)
        } else {
            PadCycleMenu(cycle: cycleFilter) {
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
            .padding(10)
        }
    }

    /// Ⓐ steps All → each source → All (the system menu isn't cursor-operable).
    private func cycleFilter() {
        guard let current = pluginFilter, let i = pluginIDs.firstIndex(of: current) else {
            pluginFilter = pluginIDs.first
            return
        }
        pluginFilter = i + 1 < pluginIDs.count ? pluginIDs[i + 1] : nil
    }

    private func row(_ lane: StoryMapLane) -> some View {
        let state = model.laneState(lane)
        let selected = lane.key == selectedKey
        let fraction = lane.totalCount == 0 ? 0 : Double(lane.completedCount) / Double(lane.totalCount)
        return Button { selectedKey = lane.key } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(model.governmentColor(lane.governmentID)).frame(width: 4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lane.title).novaFont(.body, weight: .bold).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    StoryCapsuleBar(fraction: fraction, tint: state == .complete ? EVTheme.done : EVTheme.accent, height: 5)
                    HStack {
                        Text("\(lane.completedCount)/\(lane.totalCount) steps")
                            .novaFont(.caption).foregroundStyle(EVTheme.dim)
                        Spacer(minLength: 4)
                        StoryPill(text: state.label, tint: state.tint, symbol: state.symbol)
                    }
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? EVTheme.accent.opacity(0.15) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? EVTheme.accent.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.novaPlain)
    }
}

/// A `Menu` for touch/mouse that a controller can still drive: system menus
/// aren't cursor targets, so Ⓐ runs `cycle` (step to the next option) instead.
/// tvOS has no usable `Menu` under the cursor, so it's just the label there.
private struct PadCycleMenu<Items: View, Label: View>: View {
    let cycle: () -> Void
    @ViewBuilder let items: () -> Items
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(tvOS)
        label().contentShape(Rectangle()).cursorClickable(cycle)
        #else
        Menu(content: items, label: label)
            .buttonStyle(.plain)
            .cursorClickable(cycle)
        #endif
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
