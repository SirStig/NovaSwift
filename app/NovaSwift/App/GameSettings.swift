import Foundation
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
    /// `Difficulty`. The engine's untuned defaults (`normal`) already read as
    /// "alive"; `authentic` dials that back toward the original game's
    /// quieter, more-passing-through traffic, and `bustling` pushes further
    /// past `normal` for players who want even busier systems.
    enum SystemAliveness: String, Codable, CaseIterable, Identifiable {
        case authentic, normal, bustling
        var id: String { rawValue }
        var label: String {
            switch self {
            case .authentic: return "Authentic"
            case .normal: return "Normal"
            case .bustling: return "Bustling"
            }
        }
        var blurb: String {
            switch self {
            case .authentic: return "Fewer ships, more passing through — closer to the original game's pace."
            case .normal: return "The port's default: a lively mix of traffic and landings."
            case .bustling: return "Even busier systems, with fleets and traffic on top of Normal."
            }
        }
        /// Multiplies `Spawner.targetPopulation`/`maxPopulation`/
        /// `maxConcurrentFleets`, and inversely scales `spawnInterval`/
        /// `fleetInterval` (so a lower population also arrives more slowly).
        var populationScale: Double {
            switch self {
            case .authentic: return 0.55
            case .normal: return 1.0
            case .bustling: return 1.35
            }
        }
        /// Odds (0...1) an ambient trader skips landing and just cruises
        /// through the system instead — this is the main lever against
        /// planets feeling crowded, since every landing trader used to dock
        /// unconditionally.
        var passThroughChance: Double {
            switch self {
            case .authentic: return 0.55
            case .normal: return 0.0
            case .bustling: return 0.0
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

    /// Overall simulation speed. `x1` is real time — the original ran a fixed
    /// 30fps sim and read acceleration/top-speed/weapon-reload straight off
    /// `shïp`/`wëap` data with no global time dilation, so real time *is* the
    /// faithful pace; the original's slow cruise feel comes entirely from those
    /// low stat values, not from an artificial slow-motion multiplier. The
    /// original also let you toggle Caps-Lock for a ~2× "fast" mode that sped
    /// the whole engine up uniformly (including combat); `x2`/`x4`/`x8` here
    /// generalise that into a proper option, and `x0_5` extends it the other
    /// way into slow motion for players who want more reaction time in a
    /// dogfight. Applied as a multiplier on the physics timestep, so it
    /// uniformly scales acceleration, top speed, turning, travel time, weapon
    /// reload and shield/armor regen — leave it at `x1` for combat and travel
    /// pacing that matches the documented Bible formulas exactly.
    enum GameSpeed: String, Codable, CaseIterable, Identifiable {
        case x0_5, x1, x2, x4, x8
        var id: String { rawValue }
        var label: String {
            switch self {
            case .x0_5: return "0.5×"
            case .x1: return "1×"
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
    var systemAliveness: SystemAliveness = .normal
    /// Overall simulation speed (see `GameSpeed`). Default `x1` — real time,
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

    // MARK: Controls

    var controlScheme: ControlScheme = .virtualCockpit
    var controlSensitivity: Double = 1.0
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
    var frameRateCap: FrameRateCap = .platformDefault
    /// Engine exhaust / weapon glow effects.
    var engineGlow: Bool = true
    /// Camera shake on impacts / explosions.
    var screenShake: Bool = true
    /// Where hull/shield bars appear over ships. Default `above` (the current
    /// look); `off` matches the original, which never floated bars over ships.
    var shipBarPosition: ShipBarPosition = .above
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
    /// Global UI scale factor (0.8…1.4).
    var uiScale: Double = 1.0

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
        controlScheme         = v(.controlScheme, d.controlScheme)
        controlSensitivity    = v(.controlSensitivity, d.controlSensitivity)
        invertTurn            = v(.invertTurn, d.invertTurn)
        tiltSensitivity       = v(.tiltSensitivity, d.tiltSensitivity)
        stickDeadzone         = v(.stickDeadzone, d.stickDeadzone)
        cursorSensitivity     = v(.cursorSensitivity, d.cursorSensitivity)
        hapticsEnabled        = v(.hapticsEnabled, d.hapticsEnabled)
        mouseAiming           = v(.mouseAiming, d.mouseAiming)
        starfieldDensity      = v(.starfieldDensity, d.starfieldDensity)
        showFPS               = v(.showFPS, d.showFPS)
        smoothSprites         = v(.smoothSprites, d.smoothSprites)
        frameRateCap          = v(.frameRateCap, d.frameRateCap)
        engineGlow            = v(.engineGlow, d.engineGlow)
        screenShake           = v(.screenShake, d.screenShake)
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
        uiScale               = v(.uiScale, d.uiScale)
    }
}
