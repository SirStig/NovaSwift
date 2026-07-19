import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

// A small "this mission continues a storyline" indicator — an aftermarket
// hint EV Nova never had, added across every mission surface (Mission Info,
// Missions BBS/bar offers, in-flight pêrs offers) so a player deciding
// whether to accept a job can see it leads somewhere (e.g. "continues the
// Vellos storyline") before committing. Gated by
// `GameSettings.showMissionStorylineTags` (on by default) at each call site;
// this view itself renders unconditionally once given a tag, so callers
// decide visibility.

/// A tappable badge for one mission's storyline tag. Purely presentational —
/// callers resolve the tag (via `StorylineAnalyzer.storylineTag(forMissionID:)`)
/// and supply the open action.
struct StorylineTagBadge: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.35))
        }
        .buttonStyle(.novaPlain)
        .accessibilityLabel("Continues the \(title) storyline")
        .help("Continues the \(title) storyline — open in Story Guide")
    }
}

extension View {
    /// Presents the Story Guide focused on `storylineKey` when `isPresented`
    /// flips true, building its `StoryGuideModel` lazily (once) from `game`/
    /// `player` rather than rebuilding on every render. Shared by every
    /// mission-surface call site that offers a storyline badge.
    func storylineGuideSheet(isPresented: Binding<Bool>, game: NovaGame,
                             player: @escaping () -> PlayerState, storylineKey: String?) -> some View {
        modifier(StorylineGuideSheetModifier(isPresented: isPresented, game: game,
                                             player: player, storylineKey: storylineKey))
    }
}

private struct StorylineGuideSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let game: NovaGame
    let player: () -> PlayerState
    let storylineKey: String?

    @State private var model: StoryGuideModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                if presented, model == nil { model = StoryGuideModel.over(game, player: player()) }
            }
            .background {
                if let model {
                    Color.clear
                        .storyGuideSheet(isPresented: $isPresented, model: model,
                                         initialStorylineKey: storylineKey)
                }
            }
    }
}
