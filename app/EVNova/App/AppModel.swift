import SwiftUI
import Combine
import EVNovaKit

/// Top-level app state: current screen, settings, and the game data library
/// (base data + plug-in catalog with enabled state).
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case launcher
        case game
    }

    @Published var screen: Screen = .launcher
    @Published var settings: GameSettings = .load()
    @Published var data = GameDataController()

    private var dataObserver: AnyCancellable?

    init() {
        // Re-publish when the data controller changes so views observing AppModel refresh.
        dataObserver = data.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Persist settings whenever they change materially.
    func commitSettings() { settings.save() }

    func startGame() {
        data.reloadIfNeeded()
        screen = .game
    }

    func exitToLauncher() { screen = .launcher }
}
