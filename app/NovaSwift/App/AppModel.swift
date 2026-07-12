import SwiftUI
import Combine
import NovaSwiftKit
import NovaSwiftStory

/// Top-level app state: current screen, settings, and the game data library
/// (base data + plug-in catalog with enabled state).
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable { case launcher, mainMenu, loading, game }

    @Published var screen: Screen = .launcher {
        didSet { audio.setMusicAllowed(screen == .mainMenu) }
    }

    /// A newly-created pilot whose scenario intro is playing. Presented
    /// full-screen at the `RootView` level (not nested in any dialog sheet) so
    /// the intro slideshow always covers the whole window.
    @Published var pendingIntro: CharRes?
    @Published var settings: GameSettings = .load()
    @Published var bindings: KeyBindings = .load()
    @Published var data = GameDataController()

    /// Catalog browse/install state for the plug-in store (see `Store/`).
    let store = PluginStoreModel()

    /// Shared audio system: SFX + music, driven by `settings`. Used by the game
    /// scene (flight/combat SFX) and the launcher (UI clicks, music, sound test).
    let audio = GameAudio()

    /// The persistent player pilot (credits, cargo, outfits, hull, location). The
    /// spaceport shops against it; it saves/resumes to disk. This is the live
    /// in-session pilot.
    let pilot = PilotStore()

    /// The durable library of all saved pilots (many `.evpilot` files + backups).
    /// Backed by iCloud or local storage per `settings.iCloudSaves` — built in
    /// `init` (after `settings`) so it can honour that toggle from launch.
    let roster: PilotRoster

    /// Why a save is being written — drives whether a rotating backup is taken.
    enum SaveReason { case manual, land, jump, timer
        var wantsBackup: Bool { self == .land || self == .manual }
    }

    /// Authentic-UI graphics (real button / frame / backdrop PICTs) for menus and
    /// dialogs presented outside a play session. Built lazily from the loaded data
    /// and invalidated when the data changes.
    private var _uiGraphics: SpaceportGraphics?
    var uiGraphics: SpaceportGraphics? {
        if _uiGraphics == nil, let game = data.game { _uiGraphics = SpaceportGraphics(game: game) }
        return _uiGraphics
    }

    private var dataObserver: AnyCancellable?

    init() {
        // Build the roster honouring the saved iCloud preference. `settings` is
        // already initialized (stored-property initializer runs before this
        // body), so its toggle is available here. Falls back to local storage
        // transparently if iCloud isn't reachable.
        roster = PilotRoster(preferICloud: settings.iCloudSaves)
        // Re-publish when the data controller changes so views observing AppModel refresh.
        dataObserver = data.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            _uiGraphics = nil                // rebuild authentic-UI art against new data
            store.refresh(data: data)
            objectWillChange.send()
        }
        audio.apply(settings: settings)
        store.refresh(data: data)
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

    /// From the port's native launcher, opens the authentic EV Nova main menu.
    /// The launcher only offers this once game data is present — there is no
    /// data-less "demo" to fall back to — but guard it anyway since `screen`
    /// is otherwise settable from anywhere.
    func startGame() {
        guard data.hasBaseData else { return }
        screen = .mainMenu
    }

    /// From the authentic main menu, New Pilot / Enter Ship begins play.
    func beginPlay() {
        screen = .loading
    }

    func finishLoadingIntoGame() {
        prepareAudioAndData()
        if let game = data.game { pilot.ensureStarted(game: game) }
        screen = .game
    }

    /// Begin a fresh pilot from the scenario `chär`, discarding any prior save.
    func startNewPilot() {
        prepareAudioAndData()
        if let game = data.game { pilot.reset(); pilot.newGame(game: game) }
    }

    // MARK: Multi-pilot flow (roster + scenarios)

    /// Create a new pilot from a chosen starting scenario and adopt it as the
    /// live pilot. Does not change the screen — the new-pilot UI shows the intro
    /// and then calls `beginPlay()`.
    @discardableResult
    func createPilot(name: String, isMale: Bool, scenario: CharRes) -> CharRes? {
        prepareAudioAndData()
        guard let game = data.game else { return nil }
        let save = roster.create(name: name, isMale: isMale, scenario: scenario, game: game)
        pilot.begin(state: save.player, rosterID: save.id)
        return scenario
    }

    /// Resume a saved pilot from the roster and enter the game.
    func play(_ save: PilotSave) {
        prepareAudioAndData()
        pilot.begin(state: save.player, rosterID: save.id)
        beginPlay()
    }

    /// "Enter Ship" — continue the most recently played pilot, if any.
    func continueMostRecent() {
        if let recent = roster.mostRecent { play(recent) }
        else { beginPlay() }   // no roster pilot yet: fall back to the default start
    }

    /// Persist the live pilot into its durable roster file (+ backup on land /
    /// manual save). A session that never went through `createPilot`/`play`
    /// (a dev autoplay run) has no roster id yet — adopt it into the roster
    /// now instead of leaving it un-persisted for the whole session.
    func autosave(reason: SaveReason) {
        let id = pilot.rosterID ?? roster.adopt(state: pilot.state, game: data.game).id
        if pilot.rosterID == nil { pilot.bind(rosterID: id) }
        roster.persist(id: id, state: pilot.state, game: data.game, backup: reason.wantsBackup)
    }

    /// Back to the authentic EV Nova main menu (e.g. from the in-game pause menu).
    func returnToMainMenu() {
        screen = data.hasBaseData ? .mainMenu : .launcher
    }

    /// All the way out to the port's native launcher.
    func exitToLauncher() { screen = .launcher }
}
