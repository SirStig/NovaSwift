import SwiftUI
import Combine
import EVNovaKit

/// Top-level app state: current screen, settings, and the game data library
/// (base data + plug-in catalog with enabled state).
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable { case launcher, loading, game }

    @Published var screen: Screen = .launcher
    @Published var settings: GameSettings = .load()
    @Published var bindings: KeyBindings = .load()
    @Published var data = GameDataController()

    /// Shared audio system: SFX + music, driven by `settings`. Used by the game
    /// scene (flight/combat SFX) and the launcher (UI clicks, music, sound test).
    let audio = GameAudio()

    private var dataObserver: AnyCancellable?

    init() {
        // Re-publish when the data controller changes so views observing AppModel refresh.
        dataObserver = data.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        audio.apply(settings: settings)
    }

    /// Persist settings whenever they change materially, and push audio changes live.
    func commitSettings() {
        settings.save()
        audio.apply(settings: settings)
    }
    func commitBindings() { bindings.save() }

    /// Make sure data is loaded and the audio system is wired to it (music track +
    /// decoded SFX). Safe to call repeatedly.
    func prepareAudioAndData() {
        data.reloadIfNeeded()
        audio.attach(game: data.game)
        audio.setMusic(url: data.musicTrackURL())
        audio.apply(settings: settings)
        audio.startMusicIfEnabled()
    }

    /// Enter the game via a brief loading screen (loads/merges data off the main flow).
    func startGame() {
        screen = .loading
    }

    func finishLoadingIntoGame() {
        prepareAudioAndData()
        screen = .game
    }

    func exitToLauncher() { screen = .launcher }
}
