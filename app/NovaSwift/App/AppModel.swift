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

    /// Where a flight-training session should hand off when it ends.
    enum TutorialExit: Equatable { case play, menu }
    /// A running flight-training session (nil = none). Presented full-screen at
    /// the `RootView` level, like `pendingIntro`.
    @Published var tutorial: TutorialExit?
    /// A new pilot has finished their intro and is being offered flight training
    /// before the game begins.
    @Published var pendingTutorialOffer = false

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
    private var rosterObserver: AnyCancellable?

    init() {
        // Build the roster honouring the saved iCloud preference. Read the
        // preference directly (not via `self.settings`, which the class-init
        // rule forbids touching before every stored property is set) — it's the
        // same persisted blob `settings`'s initializer loads. Falls back to
        // local storage transparently if iCloud isn't reachable.
        roster = PilotRoster(preferICloud: GameSettings.load().iCloudSaves)
        // Re-publish when the data controller changes so views observing AppModel refresh.
        dataObserver = data.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            _uiGraphics = nil                // rebuild authentic-UI art against new data
            store.refresh(data: data)
            objectWillChange.send()
        }
        // The roster is a nested ObservableObject reached through `model.roster`;
        // SwiftUI only re-renders on the *observed* object's change, so forward
        // its changes (pilot list, selection, iCloud/local state) up to AppModel
        // so the menus and Settings status update live.
        rosterObserver = roster.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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

    // MARK: Flight training

    /// After a new pilot's intro, offer flight training — but only the first time
    /// (until completed/skipped once) and only when the tutorial-hints preference
    /// is on. Otherwise go straight into the game. Replayable any time from the
    /// main menu regardless of this gate.
    func offerTutorialAfterNewPilot() {
        if settings.tutorialHints, !TutorialProgress.hasCompleted, data.game != nil {
            pendingTutorialOffer = true
        } else {
            beginPlay()
        }
    }

    /// Begin a flight-training session. `exit` decides what happens when it ends.
    func startTutorial(exit: TutorialExit) {
        pendingTutorialOffer = false
        tutorial = exit
    }

    /// The player declined training from the new-pilot offer — go straight to play.
    func skipTutorialOffer() {
        pendingTutorialOffer = false
        beginPlay()
    }

    /// End the current training session (finished or skipped). Records that it's
    /// been seen so it isn't auto-offered again, then hands off per its `exit`.
    func finishTutorial() {
        let exit = tutorial
        tutorial = nil
        TutorialProgress.hasCompleted = true
        if exit == .play { beginPlay() }
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
        roster.setSelected(save.id)                 // a new pilot becomes the loaded one
        pilot.begin(state: save.player, rosterID: save.id)
        return scenario
    }

    /// Resume a saved pilot from the roster and enter the game. Marks it as the
    /// loaded pilot so "Enter Ship" resumes *this* one next time (rather than
    /// whatever happens to be newest).
    func play(_ save: PilotSave) {
        prepareAudioAndData()
        roster.setSelected(save.id)
        pilot.begin(state: save.player, rosterID: save.id)
        beginPlay()
    }

    /// "Enter Ship" — resume the *selected* (loaded) pilot. Returns false when
    /// there's no unambiguous pilot to resume (none selected, or several exist
    /// and the player hasn't chosen one), so the menu opens the pilot picker
    /// instead of silently grabbing the newest save.
    @discardableResult
    func enterShip() -> Bool {
        guard let save = roster.selected else { return false }
        play(save)
        return true
    }

    /// Turn iCloud pilot syncing on or off: persist the preference and migrate
    /// existing pilots into the new store (local ⇄ iCloud). Falls back to local
    /// transparently if iCloud isn't reachable.
    func setICloudSaves(_ on: Bool) {
        settings.iCloudSaves = on
        commitSettings()
        roster.useICloud(on)
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
        audio.stopAllLoops()   // no beam/ambient loop bleeds from the game into the menu
        screen = data.hasBaseData ? .mainMenu : .launcher
    }

    /// All the way out to the port's native launcher.
    func exitToLauncher() {
        audio.stopAllLoops()
        screen = .launcher
    }
}
