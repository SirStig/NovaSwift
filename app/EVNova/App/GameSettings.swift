import Foundation

/// User-facing settings, persisted to `UserDefaults` as JSON. Read by the engine
/// and renderer at scene start. See docs/MOBILE_AND_PLUGINS.md §2.
struct GameSettings: Codable, Equatable {
    // Controls
    enum ControlScheme: String, Codable, CaseIterable, Identifiable {
        case virtualCockpit  // turn zone + thrust/fire buttons
        case tapToTurn       // point toward tap
        case tilt            // tilt-to-turn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .virtualCockpit: return "Virtual Cockpit"
            case .tapToTurn: return "Tap to Turn"
            case .tilt: return "Tilt to Turn"
            }
        }
    }
    var controlScheme: ControlScheme = .virtualCockpit
    var controlSensitivity: Double = 1.0
    var invertTurn: Bool = false

    // Graphics
    var starfieldDensity: Double = 1.0
    var showFPS: Bool = false

    // Audio
    var musicVolume: Double = 0.7
    var sfxVolume: Double = 0.9

    // Gameplay / accessibility
    var largerHUD: Bool = false

    static let storageKey = "com.evnova.settings.v1"

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
}
