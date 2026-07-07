import SwiftUI
import EVNovaKit

/// Tracks the player's location in the galaxy and handles hyperspace jumps along
/// `sÿst` links. Drives the galaxy map. (Where you *start* comes from the data;
/// jumping is restricted to directly-linked systems, as in EV Nova.)
@MainActor
final class NavigationModel: ObservableObject {
    private(set) var game: NovaGame?
    @Published var currentSystemID: Int
    @Published var showingMap = false

    init(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
    }

    /// Set the resolved game + starting system once data has loaded.
    func configure(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
    }

    var current: SystRes? { game?.system(currentSystemID) }
    func systems() -> [SystRes] { game?.systems() ?? [] }
    func system(_ id: Int) -> SystRes? { game?.system(id) }

    /// Systems reachable in one jump from the current system.
    func neighbors() -> [SystRes] {
        (current?.links ?? []).compactMap { game?.system($0) }
    }

    func canJump(to id: Int) -> Bool { current?.links.contains(id) ?? false }

    /// Jump to a directly-linked system. Returns true if the jump happened.
    @discardableResult
    func jump(to id: Int) -> Bool {
        guard canJump(to: id) else { return false }
        currentSystemID = id
        showingMap = false
        return true
    }
}
