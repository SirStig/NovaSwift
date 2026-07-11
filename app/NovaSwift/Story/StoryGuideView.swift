import SwiftUI
import NovaSwiftStory

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
    @State private var tab: Tab
    var onClose: (() -> Void)?
    /// Abort an active mission (by mïsn id). Wired by the game to the live pilot;
    /// nil in previews / read-only contexts, where the Abort buttons hide.
    var onAbort: ((Int) -> Void)?

    // Pilot status/cargo/equipment/honors lives in the authentic 4-tab player
    // info dialog (`PlayerInfoView`, DITL #1017), not here — this window is the
    // story companion only.
    enum Tab: String, CaseIterable { case story = "Story Guide", map = "Story Map" }

    init(model: StoryGuideModel, initialTab: Tab = .story,
         onClose: (() -> Void)? = nil, onAbort: ((Int) -> Void)? = nil) {
        self.model = model
        self._tab = State(initialValue: initialTab)
        self.onClose = onClose
        self.onAbort = onAbort
    }

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
            case .story: StorylineBrowserView(storylines: model.storylines,
                                              untaggedCount: model.untaggedCount)
            case .map:   StorylineMapView(map: model.storyMap)
            }
        }
        // Fill whatever container presents us (a sheet on iOS, the sized sheet
        // on macOS) instead of forcing a 460-wide floor that overflows a compact
        // iPhone. `idealWidth` keeps the macOS sheet comfortably wide.
        .frame(minWidth: 300, idealWidth: 900, maxWidth: .infinity,
               minHeight: 380, maxHeight: .infinity)
        .background(EVTheme.panel)
        .foregroundStyle(EVTheme.text)
        .novaResponsive()
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(EVTheme.accent)
            Text("Pilot Log").novaFont(.heading)
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

#Preview("Story Guide") { StoryGuideView(model: .sample) }
