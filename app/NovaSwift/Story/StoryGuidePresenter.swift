import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

// One-line integration for the in-game Pilot / Story Guide window. Whichever
// view owns the interactive in-game menu bar adds a button that flips a
// @State Bool and attaches `.storyGuideSheet(isPresented:model:)`. Kept separate
// from the (non-interactive, other-agent-owned) HUD overlay so it doesn't
// collide with parallel UI work.
//
//   @State private var showGuide = false
//   ...
//   Button("Pilot Log") { showGuide = true }
//   .storyGuideSheet(isPresented: $showGuide, model: guideModel)

extension StoryGuideModel {
    /// Build a guide over the real loaded game with a fresh starter pilot. Useful
    /// until the running game owns a live `PlayerState` (mission/landing flow).
    /// Pass the pilot's actual save once it exists.
    static func over(_ game: NovaGame, player: PlayerState? = nil, plugins: [PluginBundle] = []) -> StoryGuideModel {
        let pilot = player ?? StoryGuideModel.starterPilot(for: game)
        return StoryGuideModel(game: game, player: pilot, plugins: plugins)
    }

    /// A reasonable "new pilot" so the guide has something to show over real data:
    /// starts in the most-populated system in a stock starter ship.
    static func starterPilot(for game: NovaGame) -> PlayerState {
        let startSystem = game.startingSystem()?.id ?? 128
        let ship = game.ships().first?.id ?? 128
        return PlayerState(pilotName: "New Pilot", shipType: ship,
                           credits: 10_000, currentSystem: startSystem)
    }
}

extension View {
    /// Present the Pilot / Story Guide window: a true full-screen cover on iPhone
    /// (the Story Map wants the whole screen), a centred sheet on macOS.
    ///
    /// - Parameter initialStorylineKey: pre-select this storyline on open — set
    ///   from a mission's storyline badge so tapping it jumps straight to that
    ///   campaign instead of the default "first in-progress lane".
    func storyGuideSheet(isPresented: Binding<Bool>, model: StoryGuideModel,
                         initialStorylineKey: String? = nil) -> some View {
        #if os(iOS)
        return fullScreenCover(isPresented: isPresented) {
            StoryGuideView(model: model, onClose: { isPresented.wrappedValue = false },
                          initialStorylineKey: initialStorylineKey)
                .preferredColorScheme(.dark)
        }
        #else
        return sheet(isPresented: isPresented) {
            StoryGuideView(model: model, onClose: { isPresented.wrappedValue = false },
                          initialStorylineKey: initialStorylineKey)
                .frame(minWidth: 900, minHeight: 620)
        }
        #endif
    }
}
