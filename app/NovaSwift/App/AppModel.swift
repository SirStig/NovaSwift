import SwiftUI
import Combine
import NovaSwiftKit
import NovaSwiftStory
import NovaSwiftNet
#if canImport(GameKit)
import GameKit
#endif

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

    /// Live multiplayer session (presence + chat now; simulation sync later).
    /// Inactive until a session is started; reached everywhere via `model.session`.
    let session = MultiplayerSession()

    #if canImport(GameKit)
    /// Game Center sign-in state for online co-op. Authentication is kicked off at
    /// launch (`RootView`); it gates the "Online Co-op" entry.
    let gameCenter = GameCenterManager()
    #endif

    /// The durable library of all saved pilots (many `.evpilot` files + backups).
    /// Backed by iCloud or local storage per `settings.iCloudSaves` — built in
    /// `init` (after `settings`) so it can honour that toggle from launch.
    let roster: PilotRoster

    /// Why a save is being written — drives whether a rotating backup is taken.
    enum SaveReason { case manual, land, jump, timer, periodic
        var wantsBackup: Bool { self == .land || self == .manual || self == .periodic }
    }

    /// Authentic-UI graphics (real button / frame / backdrop PICTs) for menus and
    /// dialogs presented outside a play session. Built lazily from the loaded data
    /// and invalidated when the data changes.
    private var _uiGraphics: SpaceportGraphics?
    var uiGraphics: SpaceportGraphics? {
        if _uiGraphics == nil, let game = data.game { _uiGraphics = SpaceportGraphics(game: game) }
        return _uiGraphics
    }

    /// The game-wide `cölr` interface theme (button/list/grid/progress colours +
    /// fonts), resolved once from the loaded data and reused by all native
    /// chrome via `\.novaTheme`. Rebuilt when the data changes (plug-in toggle,
    /// import), same as `uiGraphics`.
    private var _uiTheme: NovaUITheme?
    var uiTheme: NovaUITheme {
        if _uiTheme == nil { _uiTheme = NovaUITheme(colr: data.game?.colr()) }
        return _uiTheme ?? .fallback
    }

    private var dataObserver: AnyCancellable?
    private var rosterObserver: AnyCancellable?
    private var sessionObserver: AnyCancellable?
    #if canImport(GameKit)
    private var gameCenterObserver: AnyCancellable?
    private var sessionActiveObserver: AnyCancellable?
    #endif

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
            _uiTheme = nil                   // and the cölr interface theme
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
        // Forward the multiplayer session's changes (presence/chat/unread) up so
        // views observing AppModel refresh, same as `roster`/`data`.
        sessionObserver = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Co-op story (NCB) sync: let the session read our control-bit vector to
        // share bits we earn in a shared storyline, and union bits a partner earns
        // into ours — strictly non-destructive (see `MultiplayerSession`).
        session.playerBitsProvider = { [weak self] in self?.pilot.state.setBits ?? [] }
        // Plug-in compatibility: the session verifies a joiner runs the same
        // enabled plug-ins as the host (a mismatch would desync the shared galaxy).
        session.pluginManifestProvider = { [weak self] in self?.currentPluginManifest() ?? .empty }
        session.onRemoteBitsEarned = { [weak self] bits in
            guard let self else { return }
            let before = pilot.state.setBits
            pilot.state.setBits.formUnion(bits)      // union only — never removes
            if pilot.state.setBits != before { pilot.save() }
        }
        // Trade / hand-off: apply a committed trade to the pilot — remove what we
        // gave, add what we received (credits, cargo, outfits) — then save.
        session.onTradeCommitted = { [weak self] give, receive in
            guard let self else { return }
            var s = pilot.state
            s.credits = max(0, s.credits - give.credits) + receive.credits
            for (id, tons) in give.cargo {
                let left = (s.cargo[id] ?? 0) - tons
                s.cargo[id] = left > 0 ? left : nil
            }
            for (id, tons) in receive.cargo { s.cargo[id, default: 0] += tons }
            for (id, n) in give.outfits {
                let left = (s.outfits[id] ?? 0) - n
                s.outfits[id] = left > 0 ? left : nil
            }
            for (id, n) in receive.outfits { s.outfits[id, default: 0] += n }
            pilot.state = s
            pilot.save()
        }
        #if canImport(GameKit)
        // Forward Game Center sign-in changes so the "Online Co-op" entry updates.
        gameCenterObserver = gameCenter.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // An accepted invite can arrive at any time — in flight, on the main menu,
        // from the Game Center app — so the session starts from here rather than
        // from whichever screen happens to be up. `hostID` is the inviter (nil when
        // we initiated, i.e. we host).
        gameCenter.onMatch = { [weak self] match, hostID in
            self?.startOnlineSession(match: match, hostID: hostID)
        }
        gameCenter.playerGroupProvider = { [weak self] in
            self?.currentPluginManifest().groupID ?? 0
        }
        #endif
        #if canImport(CloudKit) && canImport(GameKit)
        wireLobbyDirectory()
        // Pull our advert the moment the session ends, however it ends — Leave, a
        // dropped match, a quit. A listed lobby that nobody is hosting is worse
        // than no listing: it's a join request that will never be answered.
        sessionActiveObserver = session.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                guard !active else { return }
                Task { await self?.lobbyDirectory.withdraw() }
            }
        #endif
        audio.apply(settings: settings)
        store.refresh(data: data)
    }

    /// Persist settings whenever they change materially, and push audio changes live.
    func commitSettings() {
        settings.save()
        audio.apply(settings: settings)
    }
    func commitBindings() { bindings.save() }

    // MARK: Online sessions

    /// Lobby name + stakes the player chose when hosting online. Held from the
    /// host-setup sheet until a match actually forms: matchmaking can take a while,
    /// and an invite accepted from outside the app has no sheet to read them from.
    /// Cleared once consumed; ignored when we join as a guest (the host owns rules).
    struct OnlineHostConfig: Equatable {
        var lobbyName: String
        var rules: SessionRules
        /// Advertise in the public lobby list. Off = invite-only.
        var listPublicly: Bool
    }
    @Published var onlineHostConfig: OnlineHostConfig?

    /// The name other players see. Local lobbies additionally tag secondary dev
    /// instances so two copies on one machine are tellable apart; online is always
    /// a real person, so it stays clean.
    var multiplayerDisplayName: String {
        let name = pilot.state.pilotName
        return name.isEmpty ? "Captain" : name
    }

    #if canImport(CloudKit) && canImport(GameKit)
    /// The public lobby list. Discovery only — it advertises a lobby and carries
    /// join requests; Game Center still forms and runs every match.
    let lobbyDirectory = OnlineLobbyDirectory()

    /// Keep our advert's roster count honest, and stop advertising a lobby that has
    /// filled up (`GKMatchRequest` caps a match at 4).
    private func wireLobbyDirectory() {
        lobbyDirectory.liveStateProvider = { [weak self] in
            guard let self else { return (playerCount: 1, isOpen: false) }
            let count = max(self.session.players.count, 1)
            return (playerCount: count, isOpen: self.session.isActive && count < 4)
        }
    }

    /// Approve a knock: invite them in, then clear the request so they stop waiting.
    /// The invite is what actually admits them — accepting in the directory alone
    /// does nothing, which is what keeps a lobby gated.
    func acceptJoinRequest(_ request: OnlineJoinRequest) async {
        await gameCenter.invite(playerID: request.playerID, into: session.gameCenterMatch)
        await lobbyDirectory.resolveJoinRequest(request)
    }

    func declineJoinRequest(_ request: OnlineJoinRequest) async {
        await lobbyDirectory.resolveJoinRequest(request)
    }

    /// Advertise the session we're hosting, once it exists and we know its name.
    private func publishLobbyIfHosting() async {
        guard session.isActive, session.isHost, session.gameCenterMatch != nil else { return }
        let manifest = currentPluginManifest()
        await lobbyDirectory.publish(OnlineLobby(
            hostPlayerID: session.localPlayerID,
            name: session.lobbyName,
            hostName: multiplayerDisplayName,
            playerCount: max(session.players.count, 1),
            maxPlayers: 4,
            pluginCount: manifest.count,
            pluginSignature: manifest.signature,
            allowPvP: session.rules.allowPvP))
    }
    #endif

    #if canImport(GameKit)
    /// Bring up an online session around a connected match, from wherever the
    /// player happens to be. `hostID` is the inviter, or nil when we initiated.
    ///
    /// Entering the game has to happen *before* the session starts: `startGameCenter`
    /// reads the pilot's current system, and `finishLoadingIntoGame` is what
    /// guarantees a pilot is started to read it from.
    func startOnlineSession(match: GKMatch, hostID: String?) {
        guard data.hasBaseData else {
            gameCenter.lastError = "Add your EV Nova data files before playing online."
            return
        }
        if screen != .game { finishLoadingIntoGame() }
        let config = hostID == nil ? onlineHostConfig : nil
        session.startGameCenter(
            match: match, displayName: multiplayerDisplayName,
            systemID: pilot.state.currentSystem,
            shipTypeID: pilot.state.shipType,
            hostID: hostID,
            lobbyName: config?.lobbyName ?? "",
            rules: config?.rules ?? .fullStakes)
        onlineHostConfig = nil
        #if canImport(CloudKit)
        if config?.listPublicly == true {
            Task { await publishLobbyIfHosting() }
        } else if hostID != nil {
            // We're in — stop waiting and take our knock back down. (Nothing to do
            // when we came from an invite we never asked for; it no-ops.)
            Task { await lobbyDirectory.clearMyJoinRequest(playerID: session.localPlayerID) }
        }
        #endif
    }
    #endif

    // MARK: Multiplayer plug-in compatibility

    /// Content hashes cached by a per-file stamp (id + size + mtime), so building
    /// the manifest only rehashes plug-ins whose files actually changed.
    private var pluginHashCache: [String: String] = [:]

    /// The local player's enabled-plug-in manifest, used to verify two players run
    /// the same content before playing together. Cheap after the first call (hashes
    /// are cached until a plug-in's files change).
    func currentPluginManifest() -> PluginManifest {
        let requirements = data.plugins.filter(\.isEnabled).map { bundle -> PluginRequirement in
            let stamp = pluginStamp(bundle)
            let hash = pluginHashCache[stamp] ?? {
                let h = GameLibrary.contentHash(of: bundle)
                pluginHashCache[stamp] = h
                return h
            }()
            return PluginRequirement(id: bundle.id, name: bundle.name, contentHash: hash)
        }
        return PluginManifest(requirements)
    }

    private func pluginStamp(_ bundle: PluginBundle) -> String {
        let fm = FileManager.default
        var parts = [bundle.id]
        for url in bundle.fileURLs.sorted(by: { $0.path < $1.path }) {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            parts.append("\(url.lastPathComponent)|\(size)|\(Int(mtime))")
        }
        return parts.joined(separator: ";")
    }

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
