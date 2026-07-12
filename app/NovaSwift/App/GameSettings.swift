import Foundation

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
        case easy, normal, hard
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// Damage the player takes, scaled. Easy is more forgiving; hard, less.
        var playerDamageScale: Double {
            switch self { case .easy: return 0.6; case .normal: return 1.0; case .hard: return 1.5 }
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
        var fps: Int? {
            switch self { case .fps30: return 30; case .fps60: return 60; case .fps120: return 120; case .unlimited: return nil }
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
    enum UIMode: String, Codable, CaseIterable, Identifiable {
        case classic, enhanced, novaSwift
        var id: String { rawValue }
        var label: String {
            switch self {
            case .classic:   return "Classic"
            case .enhanced:  return "Enhanced"
            case .novaSwift: return "Nova Swift"
            }
        }
        /// Blurb under the selector.
        var blurb: String {
            switch self {
            case .classic:   return "The faithful EV Nova look, rendered from your own game data."
            case .enhanced:  return "Classic, with the galaxy map opened up to full screen."
            case .novaSwift: return "The port's own modern interface — modern menu, dialogs and HUD."
            }
        }
    }

    // MARK: Gameplay

    var difficulty: Difficulty = .normal
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
    var frameRateCap: FrameRateCap = .fps60
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

    // MARK: Audio

    var masterVolume: Double = 1.0
    var musicVolume: Double = 0.7
    var sfxVolume: Double = 0.9
    var uiVolume: Double = 0.8
    var musicEnabled: Bool = true
    var muteAll: Bool = false

    // MARK: Interface

    /// The presentation mode (see `UIMode`). The single stored source of truth;
    /// the rendering flags below are derived from it.
    var uiMode: UIMode = .classic

    /// Render the galaxy map full-screen with overlaid controls (Enhanced &
    /// Nova Swift) instead of inside the authentic dialog frame (Classic).
    var fullscreenGalaxyMap: Bool { uiMode != .classic }
    /// Use the port's own modern interface — modern HUD, main menu and dialog
    /// chrome — in place of the authentic PICT chrome (Nova Swift only).
    var modernUI: Bool { uiMode == .novaSwift }

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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
        }
        difficulty            = v(.difficulty, d.difficulty)
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
        masterVolume          = v(.masterVolume, d.masterVolume)
        musicVolume           = v(.musicVolume, d.musicVolume)
        sfxVolume             = v(.sfxVolume, d.sfxVolume)
        uiVolume              = v(.uiVolume, d.uiVolume)
        musicEnabled          = v(.musicEnabled, d.musicEnabled)
        muteAll               = v(.muteAll, d.muteAll)
        uiMode                = v(.uiMode, d.uiMode)
        showRadar             = v(.showRadar, d.showRadar)
        hudOpacity            = v(.hudOpacity, d.hudOpacity)
        debugModeEnabled      = v(.debugModeEnabled, d.debugModeEnabled)
        uiDebugOverlay        = v(.uiDebugOverlay, d.uiDebugOverlay)
        iCloudSaves           = v(.iCloudSaves, d.iCloudSaves)
        largerHUD             = v(.largerHUD, d.largerHUD)
        highContrastHUD       = v(.highContrastHUD, d.highContrastHUD)
        colorblindMode        = v(.colorblindMode, d.colorblindMode)
        reduceFlashing        = v(.reduceFlashing, d.reduceFlashing)
        uiScale               = v(.uiScale, d.uiScale)
    }
}
