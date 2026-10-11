import Foundation
import NovaSwiftEngine
#if os(iOS)
import UIKit
#endif

/// User-facing settings, persisted to `UserDefaults` as JSON. Read by the engine,
/// renderer and audio system at scene start (and live for volumes). Covers EV
/// Nova's original options plus modern graphics / audio / accessibility controls.
///
/// Decoding is resilient: every field decodes to its default when absent, so
/// adding options never invalidates a player's saved settings.
struct GameSettings: Codable, Equatable {

    // MARK: Enums

    enum ControlScheme: String, Codable, CaseIterable, Identifiable {
        case virtualCockpit  // turn zone + thrust/fire buttons
        case tapToTurn       // point toward tap
        case tilt            // tilt-to-turn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .virtualCockpit: return "On-screen Buttons"
            case .tapToTurn: return "Tap / Drag to Fly"
            case .tilt: return "Tilt to Turn"
            }
        }
    }

    enum Difficulty: String, Codable, CaseIterable, Identifiable {
        case veryEasy, easy, normal, hard
        var id: String { rawValue }
        var label: String {
            switch self {
            case .veryEasy: return "Very Easy"
            case .easy: return "Easy"
            case .normal: return "Normal"
            case .hard: return "Hard"
            }
        }
        /// Damage the player takes, scaled. Easy is more forgiving; hard, less.
        /// Very Easy halves Easy again, for players who want the story without
        /// the fights — still lethal if you ignore your shields entirely.
        var playerDamageScale: Double {
            switch self {
            case .veryEasy: return 0.3
            case .easy: return 0.6
            case .normal: return 1.0
            case .hard: return 1.5
            }
        }
    }

    /// How densely populated/landed-on systems feel — separate from combat
    /// `Difficulty`. `original` (the default) runs the original engine's
    /// spawning rules exactly (AI-09/AI-10); the others are Enhancement
    /// presets over the port's earlier traffic model: `authentic` quieter and
    /// more passing-through, `normal` the port's livelier mix, `bustling`
    /// busier still.
    enum SystemAliveness: String, Codable, CaseIterable, Identifiable {
        case original, authentic, normal, bustling
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Original"
            case .authentic: return "Quiet"
            case .normal: return "Normal"
            case .bustling: return "Bustling"
            }
        }
        var blurb: String {
            switch self {
            case .original: return "Exactly the original game's traffic: the system's average ship count, with arrivals trickling in."
            case .authentic: return "Fewer ships, more passing through, on the port's traffic model."
            case .normal: return "The port's livelier mix of traffic and landings."
            case .bustling: return "Even busier systems, with fleets and traffic on top of Normal."
            }
        }
        /// Multiplies `Spawner.targetPopulation`/`maxPopulation`/
        /// `maxConcurrentFleets`, and inversely scales `spawnInterval`/
        /// `fleetInterval` (so a lower population also arrives more slowly).
        /// The `Spawner` rules this setting runs.
        var spawnModel: Spawner.SpawnModel { self == .original ? .original : .port }
        var populationScale: Double {
            switch self {
            case .original, .normal: return 1.0
            case .authentic: return 0.55
            case .bustling: return 1.35
            }
        }
    }

    enum FrameRateCap: String, Codable, CaseIterable, Identifiable {
        case fps30, fps60, fps120, unlimited
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fps30: return "30 FPS"
            case .fps60: return "60 FPS"
            case .fps120: return "120 FPS"
            case .unlimited: return "Unlimited"
            }
        }
        /// Desktop has the headroom for 60fps by default; mobile defaults to
        /// 30fps for battery life (matches the original's own frame rate).
        static var platformDefault: FrameRateCap {
            #if os(macOS)
            return .fps60
            #else
            return .fps30
            #endif
        }
        var fps: Int? {
            switch self { case .fps30: return 30; case .fps60: return 60; case .fps120: return 120; case .unlimited: return nil }
        }
    }

    /// Overall simulation speed. `x1` (labelled "Authentic") is real time — the
    /// original ran a fixed
    /// 30fps sim and read acceleration/top-speed/weapon-reload straight off
    /// `shïp`/`wëap` data with no global time dilation, so real time *is* the
    /// faithful pace; the original's slow cruise feel comes entirely from those
    /// low stat values, not from an artificial slow-motion multiplier. The
    /// original also let you toggle Caps-Lock for a 2× "fast" mode that ticked
    /// the whole world twice per frame (including combat) and compensated the
    /// per-frame / wall-clock rules for it; `x0_5`…`x8` here apply those same
    /// rules at their own multiplier (`GameSpeedRules`), and Caps Lock doubles
    /// whichever is chosen. Applied as a multiplier on the physics timestep, so it
    /// uniformly scales acceleration, top speed, turning, travel time, weapon
    /// reload and shield/armor regen — leave it at `x1` for combat and travel
    /// pacing that matches the documented Bible formulas exactly.
    enum GameSpeed: String, Codable, CaseIterable, Identifiable {
        case x0_5, x1, x1_5, x2, x4, x8
        var id: String { rawValue }
        var label: String {
            switch self {
            case .x0_5: return "0.5×"
            case .x1: return "Authentic"
            case .x1_5: return "1.5×"
            case .x2: return "2×"
            case .x4: return "4×"
            case .x8: return "8×"
            }
        }
        /// Physics-timestep multiplier — `x1` is exactly real-time.
        var multiplier: Double {
            switch self {
            case .x0_5: return 0.5
            case .x1: return 1.0
            case .x1_5: return 1.5
            case .x2: return 2.0
            case .x4: return 4.0
            case .x8: return 8.0
            }
        }
    }

    /// Where the slim armor/shield bar sits relative to a ship (or off entirely).
    /// The original EV Nova didn't float bars over ships at all, so `off` is the
    /// faithful look — but `above`/`below` are offered for players who want them.
    enum ShipBarPosition: String, Codable, CaseIterable, Identifiable {
        case above, below, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .above: return "Above Ships"
            case .below: return "Below Ships"
            case .off:   return "Hidden"
            }
        }
    }

    enum ColorblindMode: String, Codable, CaseIterable, Identifiable {
        case none, protanopia, deuteranopia, tritanopia
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Off"
            case .protanopia: return "Protanopia (red-weak)"
            case .deuteranopia: return "Deuteranopia (green-weak)"
            case .tritanopia: return "Tritanopia (blue-weak)"
            }
        }
    }

    /// The overall presentation mode. A selector that drives which UI *paths*
    /// render — it does not touch the individual options below, which stay
    /// independently adjustable in every mode.
    ///
    /// - `classic`   — the faithful EV Nova presentation: the authentic
    ///                 (`ïntf`/PICT) HUD, main menu and dialogs, and the galaxy
    ///                 map shown inside its authentic dialog frame.
    /// - `enhanced`  — Classic, but the galaxy map goes full-screen (no dialog
    ///                 chrome) with its controls overlaid on the map.
    /// - `novaSwift` — Enhanced's full-screen map *plus* the port's own modern
    ///                 interface: a modern main menu, modern dialog chrome and
    ///                 the modern HUD, in place of the authentic PICT chrome.
    ///                 Presentation only — ships, systems, missions and the
    ///                 economy stay entirely data-driven.
    /// Presentation presets. `classic`/`enhanced`/`novaSwift` are one-tap templates
    /// that stamp the individual interface toggles below; `custom` is a display-only
    /// state shown when the current toggles don't match any preset.
    enum UIMode: String, Codable, CaseIterable, Identifiable {
        case classic, enhanced, novaSwift, custom
        var id: String { rawValue }
        /// The three stampable presets (excludes `custom`).
        static var presets: [UIMode] { [.classic, .enhanced, .novaSwift] }
        var label: String {
            switch self {
            case .classic:   return "Classic"
            case .enhanced:  return "Enhanced"
            case .novaSwift: return "Nova Swift"
            case .custom:    return "Custom"
            }
        }
        /// Blurb under the selector.
        var blurb: String {
            switch self {
            case .classic:   return "The faithful EV Nova look, rendered from your own game data."
            case .enhanced:  return "Classic, with the galaxy map opened up to full screen."
            case .novaSwift: return "The port's own modern interface — modern menu, dialogs and HUD."
            case .custom:    return "Your own mix of interface options."
            }
        }
    }

    // MARK: Gameplay

    var difficulty: Difficulty = .normal
    /// System traffic density/landing frequency (see `SystemAliveness`).
    /// Defaults to the closest to the original until an exact `.original`
    /// population model lands (FIDELITY_PLAN AI-09/AI-10).
    var systemAliveness: SystemAliveness = .original
    /// Overall simulation speed (see `GameSpeed`). Default `x1` ("Authentic") — real time,
    /// the faithful pace.
    var gameSpeed: GameSpeed = .x1
    /// After firing, auto-select the nearest hostile if nothing is targeted.
    var autoTargetAfterFiring: Bool = false
    /// Ask for confirmation before landing / departing.
    var confirmLanding: Bool = false
    /// Auto-landing: pressing Land flies the ship to the targeted (or nearest)
    /// landable stellar and sets down automatically, instead of requiring you to
    /// be in range and slow first.
    var autoLanding: Bool = false
    /// Show first-time tutorial hints.
    var tutorialHints: Bool = true
    /// Pause the simulation when the window/app loses focus.
    var pauseOnFocusLoss: Bool = true

    // MARK: Enhancements

    /// Opt-in behaviours the original game doesn't have, all off by default
    /// (see `GameplayEnhancements`). Carried into the engine's `World`.
    var enhancements = GameplayEnhancements()

    // MARK: Controls

    var controlScheme: ControlScheme = .virtualCockpit
    var invertTurn: Bool = false
    var tiltSensitivity: Double = 1.0
    /// Analog-stick / touch dead zone (0…0.5).
    var stickDeadzone: Double = 0.15
    /// Speed of the controller-driven UI cursor (0.4…2, ×~900 pt/s).
    var cursorSensitivity: Double = 1.0
    /// Haptic feedback on touch devices / controllers.
    var hapticsEnabled: Bool = true
    /// Aim toward the mouse cursor (macOS) — off keeps the original no-auto-follow feel.
    var mouseAiming: Bool = false

    // MARK: Graphics

    var starfieldDensity: Double = 1.0
    var showFPS: Bool = false
    /// Smooth (linear) vs. crisp (nearest) sprite scaling. EV Nova art is pixel
    /// art, so crisp is the faithful default.
    var smoothSprites: Bool = false
    /// Draw the HD art and 3D models that graphics packs (e.g. Nova Reimagined)
    /// supply in place of the original sprites. Presentation only — hit-boxes,
    /// frames and gameplay are the original's. Off by default: the original art.
    var hdGraphics: Bool = false
    /// HD texture detail, in pixels per original pixel (2 or 4). 4 is sharper
    /// up close but uses four times the memory per sprite.
    var hdDetail: Int = 2
    var frameRateCap: FrameRateCap = .platformDefault
    /// Engine exhaust / weapon glow effects.
    var engineGlow: Bool = true
    /// Hyperspace presentation. Off (default): the Mac build's ~1.5 s white fade
    /// in and out of a jump. On: the Windows CE build's look, whose fade is a
    /// no-op (0x00467e60), leaving only the one-frame boom flash. The jump's
    /// mechanics and timing are identical either way (FIDELITY_PLAN FL-04).
    var ceHyperspaceLook: Bool = false
    /// Where hull/shield bars appear over ships. Default `off`, as in the
    /// original, which never floated bars over ships; a saved choice is kept.
    var shipBarPosition: ShipBarPosition = .off
    /// Show the planet/station name under each stellar. The original never labelled
    /// planets in-flight, so this is off by default.
    var showPlanetLabels: Bool = false
    /// In-flight camera zoom: world units shown per screen point, as a
    /// multiplier on SpriteKit's native 1:1 scale (1 world pixel = 1 screen
    /// point) — the original's own zoom, since it never scaled the camera at
    /// all. Higher values zoom out (show more world, everything reads smaller
    /// and slower-moving); lower values zoom in.
    var cameraZoom: Double = Self.defaultCameraZoom

    /// 1.0 (the original's native scale) everywhere except iPhone. Zoom is a
    /// fixed world-units-per-*point* multiplier, and an iPhone's screen is far
    /// fewer points across than a Mac window or an iPad — at the same 1.0
    /// zoom that shows a much smaller slice of the world, reading as "way more
    /// zoomed in" than desktop even though the math is identical. iPad's point
    /// space is close enough to a typical desktop window that it keeps 1.0.
    static var defaultCameraZoom: Double {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 1.75 : 1.0
        #else
        1.0
        #endif
    }

    // MARK: Audio

    var masterVolume: Double = 1.0
    var musicVolume: Double = 0.7
    var sfxVolume: Double = 0.9
    var uiVolume: Double = 0.8
    var musicEnabled: Bool = true
    var muteAll: Bool = false

    // MARK: Interface

    /// Individual interface toggles. Independently adjustable; the `UIMode` presets
    /// are just one-tap templates that stamp these (see `applyPreset`). Each was
    /// previously derived from the single stored `uiMode`; they're now the source
    /// of truth so any combination can be mixed.
    ///
    /// Render the galaxy map full-screen with overlaid controls instead of inside
    /// the authentic dialog frame.
    var fullscreenGalaxyMap: Bool = false
    /// Use the port's own modern main menu instead of the authentic PICT menu.
    var modernMainMenu: Bool = false
    /// Use the port's own modern dialog chrome instead of the authentic PICT chrome.
    var modernDialogs: Bool = false
    /// Use the port's own modern HUD instead of the authentic status bar.
    var modernHUD: Bool = false
    /// Open the port's sidebar pause menu on pause instead of exiting straight to
    /// the authentic main menu. On by default; independent of the presentation
    /// presets. Always available on mobile via the ☰ button regardless of this.
    var sidebarPauseMenu: Bool = true
    /// Show a small storyline badge on missions (mission menu, Missions BBS,
    /// and offer dialogs) that belong to a reconstructed campaign, and let
    /// tapping it jump straight to that storyline in the Story Guide/Map.
    /// On by default — it's a pure "aftermarket" convenience the original
    /// game never had, so players who don't want the spoiler-y hint can
    /// switch it off.
    var showMissionStorylineTags: Bool = true

    /// Stamp the four presentation toggles from a preset. `.custom` is a no-op (a
    /// display-only state, not a stampable template). `sidebarPauseMenu` is *not*
    /// touched — it's an independent behavior toggle, not part of any preset.
    mutating func applyPreset(_ preset: UIMode) {
        switch preset {
        case .classic:
            fullscreenGalaxyMap = false; modernMainMenu = false
            modernDialogs = false; modernHUD = false
        case .enhanced:
            fullscreenGalaxyMap = true; modernMainMenu = false
            modernDialogs = false; modernHUD = false
        case .novaSwift:
            fullscreenGalaxyMap = true; modernMainMenu = true
            modernDialogs = true; modernHUD = true
        case .custom:
            break
        }
    }

    /// The preset whose stamp matches the current presentation toggles, or `.custom`
    /// if none do. `sidebarPauseMenu` is intentionally excluded (independent toggle).
    var matchedPreset: UIMode {
        for preset in UIMode.presets {
            var probe = self
            probe.applyPreset(preset)
            if probe.fullscreenGalaxyMap == fullscreenGalaxyMap,
               probe.modernMainMenu == modernMainMenu,
               probe.modernDialogs == modernDialogs,
               probe.modernHUD == modernHUD {
                return preset
            }
        }
        return .custom
    }

    var showRadar: Bool = true
    /// HUD panel opacity (0.2…1).
    var hudOpacity: Double = 1.0
    /// Master switch for the in-game **debug suite**: once on, an on-screen
    /// debug button appears during play, opening a panel of developer tools
    /// (the UI measurement overlay, a performance stress test, and whatever
    /// else we add as we build). Off by default; ships nothing visible until
    /// enabled from Settings ▸ Developer.
    var debugModeEnabled: Bool = false
    /// Developer UI debug overlay: draws the design-space measurement grid on
    /// every authentic (`NovaMenu`/`NovaCanvas`) screen and live-reads the
    /// `.novaPlace` coordinate under the pointer. Toggled from the debug suite
    /// (or live with ⇧⌘D).
    var uiDebugOverlay: Bool = false

    // MARK: Storage

    /// Store pilot saves in iCloud so they sync across the player's devices.
    /// When on but iCloud is unavailable (not signed in, or the entitlement
    /// isn't provisioned), the game transparently falls back to local storage —
    /// nothing is ever lost, it just doesn't sync. Default on so a signed-in
    /// player's pilots follow them from Mac to iPad without any setup.
    var iCloudSaves: Bool = true

    /// Keep a copy of the imported game data in the player's **private**
    /// iCloud so their other devices can restore it without re-importing
    /// (and tvOS can self-heal after a cache purge). Like `iCloudSaves`,
    /// unavailability is a transparent no-op — nothing depends on it.
    var iCloudGameData: Bool = true

    // MARK: Accessibility

    var largerHUD: Bool = false
    var highContrastHUD: Bool = false
    var colorblindMode: ColorblindMode = .none
    /// Reduce flashing / rapid motion (exhaust flicker, screen shake, jump flash).
    var reduceFlashing: Bool = false
    /// The original's "no hyperspace effects" preference (prefs +0x78, `g_nv_noHyperspaceEffects`
    /// 0x005914e0): the jump's white flash and streak build-up are skipped. Off by default.
    var noHyperspaceEffects: Bool = false
    /// Global UI scale factor (0.8…1.4).
    var uiScale: Double = 1.0

    // MARK: The original's Preferences dialog (DLOG/DITL 4003)
    // Defaults are NovaPrefs_ResetToDefaults 0x004b4320.

    /// "QuickTime Movies" (prefs +3 inverted, DAT_005914d3): dësc movies,
    /// docking/jump movies and the race clips all play. On by default.
    var playMovies: Bool = true
    /// "Intro Music" (DAT_005914d1).
    var introMusic: Bool = true
    /// "Smoke Trails" (DAT_005914d5 inverted).
    var smokeTrails: Bool = true
    /// "Ship Animations" (DAT_005914da).
    var shipAnimations: Bool = true
    /// "Running Lights" (DAT_005914dd).
    var runningLights: Bool = true
    /// "Weapon Effects" (DAT_005914dc).
    var weaponEffects: Bool = true
    /// "Parallax Starfield" (DAT_005914d7).
    var parallaxStarfield: Bool = true
    /// "Ambient Sounds" (DAT_005914de).
    var ambientSounds: Bool = true
    /// "Check For Updates" (DAT_005914e1 inverted): off by default.
    var checkForUpdates: Bool = false
    /// "Share Processor Time" (DAT_005914d6).
    var shareProcessorTime: Bool = true
    /// "Sound Volume" 0...8 (DAT_005914e2), default 5; labels STR# 136.
    var soundVolumeStep: Int = 5
    /// "Brightness" 0...6 (DAT_005914e4), default 3; labels STR# 139.
    var brightnessStep: Int = 3

    // MARK: Persistence

    // Kept at v1: the resilient decoder above fills any field a v1 blob lacks, so
    // existing players keep their saved volumes/controls when new options land.
    static let storageKey = "com.novaswift.settings.v1"

    static func load() -> GameSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Reset every option to its default.
    mutating func resetToDefaults() { self = GameSettings() }

    // MARK: Resilient decoding (missing keys → defaults)

    init() {}

    /// String-only coding key used to read the legacy `uiMode` value during
    /// migration (the property no longer exists, so it isn't in `CodingKeys`).
    private struct RawKey: CodingKey {
        var stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue s: String) { stringValue = s }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
        }
        difficulty            = v(.difficulty, d.difficulty)
        systemAliveness       = v(.systemAliveness, d.systemAliveness)
        gameSpeed             = v(.gameSpeed, d.gameSpeed)
        autoTargetAfterFiring = v(.autoTargetAfterFiring, d.autoTargetAfterFiring)
        confirmLanding        = v(.confirmLanding, d.confirmLanding)
        autoLanding           = v(.autoLanding, d.autoLanding)
        tutorialHints         = v(.tutorialHints, d.tutorialHints)
        pauseOnFocusLoss      = v(.pauseOnFocusLoss, d.pauseOnFocusLoss)
        enhancements          = v(.enhancements, d.enhancements)
        controlScheme         = v(.controlScheme, d.controlScheme)
        invertTurn            = v(.invertTurn, d.invertTurn)
        tiltSensitivity       = v(.tiltSensitivity, d.tiltSensitivity)
        stickDeadzone         = v(.stickDeadzone, d.stickDeadzone)
        cursorSensitivity     = v(.cursorSensitivity, d.cursorSensitivity)
        hapticsEnabled        = v(.hapticsEnabled, d.hapticsEnabled)
        mouseAiming           = v(.mouseAiming, d.mouseAiming)
        starfieldDensity      = v(.starfieldDensity, d.starfieldDensity)
        showFPS               = v(.showFPS, d.showFPS)
        smoothSprites         = v(.smoothSprites, d.smoothSprites)
        hdGraphics            = v(.hdGraphics, d.hdGraphics)
        hdDetail              = v(.hdDetail, d.hdDetail)
        frameRateCap          = v(.frameRateCap, d.frameRateCap)
        engineGlow            = v(.engineGlow, d.engineGlow)
        ceHyperspaceLook      = v(.ceHyperspaceLook, d.ceHyperspaceLook)
        shipBarPosition       = v(.shipBarPosition, d.shipBarPosition)
        showPlanetLabels      = v(.showPlanetLabels, d.showPlanetLabels)
        cameraZoom            = v(.cameraZoom, d.cameraZoom)
        masterVolume          = v(.masterVolume, d.masterVolume)
        musicVolume           = v(.musicVolume, d.musicVolume)
        sfxVolume             = v(.sfxVolume, d.sfxVolume)
        uiVolume              = v(.uiVolume, d.uiVolume)
        musicEnabled          = v(.musicEnabled, d.musicEnabled)
        muteAll               = v(.muteAll, d.muteAll)
        fullscreenGalaxyMap   = v(.fullscreenGalaxyMap, d.fullscreenGalaxyMap)
        modernMainMenu        = v(.modernMainMenu, d.modernMainMenu)
        modernDialogs         = v(.modernDialogs, d.modernDialogs)
        modernHUD             = v(.modernHUD, d.modernHUD)
        sidebarPauseMenu      = v(.sidebarPauseMenu, d.sidebarPauseMenu)
        showMissionStorylineTags = v(.showMissionStorylineTags, d.showMissionStorylineTags)
        // Migration: a pre-split blob has no `modernHUD` key but may carry the old
        // single `uiMode` preset. Stamp the toggles from it so existing pilots keep
        // their exact look (Classic→Classic, Nova Swift→modern menu/dialogs/HUD).
        if !c.contains(.modernHUD),
           let legacy = try? decoder.container(keyedBy: RawKey.self),
           let raw = try? legacy.decodeIfPresent(String.self, forKey: RawKey("uiMode")),
           let preset = UIMode(rawValue: raw) {
            applyPreset(preset)
        }
        showRadar             = v(.showRadar, d.showRadar)
        hudOpacity            = v(.hudOpacity, d.hudOpacity)
        debugModeEnabled      = v(.debugModeEnabled, d.debugModeEnabled)
        uiDebugOverlay        = v(.uiDebugOverlay, d.uiDebugOverlay)
        iCloudSaves           = v(.iCloudSaves, d.iCloudSaves)
        iCloudGameData        = v(.iCloudGameData, d.iCloudGameData)
        largerHUD             = v(.largerHUD, d.largerHUD)
        highContrastHUD       = v(.highContrastHUD, d.highContrastHUD)
        colorblindMode        = v(.colorblindMode, d.colorblindMode)
        reduceFlashing        = v(.reduceFlashing, d.reduceFlashing)
        noHyperspaceEffects   = v(.noHyperspaceEffects, d.noHyperspaceEffects)
        uiScale               = v(.uiScale, d.uiScale)
        playMovies            = v(.playMovies, d.playMovies)
        introMusic            = v(.introMusic, d.introMusic)
        smokeTrails           = v(.smokeTrails, d.smokeTrails)
        shipAnimations        = v(.shipAnimations, d.shipAnimations)
        runningLights         = v(.runningLights, d.runningLights)
        weaponEffects         = v(.weaponEffects, d.weaponEffects)
        parallaxStarfield     = v(.parallaxStarfield, d.parallaxStarfield)
        ambientSounds         = v(.ambientSounds, d.ambientSounds)
        checkForUpdates       = v(.checkForUpdates, d.checkForUpdates)
        shareProcessorTime    = v(.shareProcessorTime, d.shareProcessorTime)
        soundVolumeStep       = v(.soundVolumeStep, d.soundVolumeStep)
        brightnessStep        = v(.brightnessStep, d.brightnessStep)
    }
}
