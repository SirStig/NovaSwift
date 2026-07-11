import SwiftUI
import EVNovaKit
import EVNovaStory

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
    static func over(_ game: NovaGame, player: PlayerState? = nil) -> StoryGuideModel {
        let pilot = player ?? StoryGuideModel.starterPilot(for: game)
        return StoryGuideModel(game: game, player: pilot)
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
    /// Present the Pilot / Story Guide window as a sheet.
    func storyGuideSheet(isPresented: Binding<Bool>, model: StoryGuideModel) -> some View {
        sheet(isPresented: isPresented) {
            StoryGuideView(model: model, onClose: { isPresented.wrappedValue = false })
        }
    }
}
