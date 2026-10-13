import SwiftUI
import GameController

/// What the visual Controls editor remembers between launches: which keyboard
/// size/ISO variant and which controller style the player picked. `nil` means
/// "auto" (Mac laptop on a Mac, Full elsewhere; the connected pad's family,
/// else Xbox) so a fresh install picks sensibly and a deliberate choice sticks.
struct ControlsEditorPrefs: Codable, Equatable {
    var keyboardSize: KeyboardSize?
    var iso = false
    var padStyle: PadStyle?

    static let storageKey = "com.novaswift.controlseditor.v1"

    static func load() -> ControlsEditorPrefs {
        UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(ControlsEditorPrefs.self, from: $0) }
            ?? ControlsEditorPrefs()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Category colours and short names

extension GameAction.Category {
    /// One fixed colour per category — keys and pad buttons are tinted by the
    /// category of the action bound to them, so a glance shows the layout's shape.
    var tint: Color {
        switch self {
        case .flight: return Color(red: 0.30, green: 0.60, blue: 1.00)
        case .combat: return Color(red: 0.95, green: 0.32, blue: 0.30)
        case .targeting: return Color(red: 0.96, green: 0.62, blue: 0.20)
        case .navigation: return Color(red: 0.30, green: 0.80, blue: 0.50)
        case .interface: return Color(red: 0.68, green: 0.50, blue: 0.95)
        case .camera: return Color(red: 0.25, green: 0.78, blue: 0.80)
        }
    }
}

extension GameAction {
    var tint: Color { category.tint }

    /// A cap-sized name: the full `title` doesn't fit on a 1u key.
    var shortName: String {
        switch self {
        case .accelerate: return "Thrust"
        case .decelerate: return "Reverse"
        case .turnLeft: return "Left"
        case .turnRight: return "Right"
        case .afterburner: return "Burner"
        case .firePrimary: return "Fire 1"
        case .fireSecondary: return "Fire 2"
        case .selectSecondaryPrev: return "Prev Sec"
        case .selectSecondaryNext: return "Next Sec"
        case .clearSecondary: return "Clr Sec"
        case .toggleCloak: return "Cloak"
        case .recallFighters: return "Recall"
        case .eject: return "Eject"
        case .selfDestruct: return "Destruct"
        case .commandEscortAggressive: return "Attack"
        case .commandEscortDefensive: return "Defend"
        case .commandEscortEvasive: return "Evade"
        case .commandEscortHold: return "Hold"
        case .commandEscortFormation: return "Form Up"
        case .commandEscortReturnHangar: return "Hangar"
        case .openEscorts: return "Escorts"
        case .targetNearest: return "Nearest"
        case .targetNext: return "Next Tgt"
        case .targetPrevious: return "Prev Tgt"
        case .targetEscortNext: return "Escort Tgt"
        case .nearestHostile: return "Hostile"
        case .clearTarget: return "Clr Tgt"
        case .clearShipTarget: return "Clr Ship"
        case .land: return "Land"
        case .hyperjump: return "Jump"
        case .hyperspaceArm: return "Hyp Dest"
        case .cycleHyperspaceLink: return "Cycle Dest"
        case .galaxyMap: return "Map"
        case .autopilot: return "Autopilot"
        case .hailTarget: return "Hail"
        case .hailStellar: return "Hail Planet"
        case .board: return "Board"
        case .selectNav1: return "Nav 1"
        case .selectNav2: return "Nav 2"
        case .selectNav3: return "Nav 3"
        case .selectNav4: return "Nav 4"
        case .routeMapZoomOut: return "Map −"
        case .routeMapZoomIn: return "Map +"
        case .pauseGame: return "Pause"
        case .openMenu: return "Menu"
        case .shipInfo: return "Ship Info"
        case .dismissMessage: return "Dismiss"
        case .playerInfo: return "Player"
        case .missionInfo: return "Missions"
        case .cycleCameraView: return "Camera"
        case .cameraZoomIn: return "Zoom +"
        case .cameraZoomOut: return "Zoom −"
        }
    }
}

// MARK: - Shared chrome

/// `onHover` doesn't exist on tvOS (pointer-less); the cursor is the only pointer there.
extension View {
    @ViewBuilder
    func editorHover(_ perform: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        self.onHover(perform: perform)
        #endif
    }
}

/// The colour key for the six action categories, shown under each device.
struct CategoryLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(GameAction.Category.allCases) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(category.tint)
                        .frame(width: 12, height: 12)
                    Text(category.rawValue).novaFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A small pill used for the editor's toggles and action chips; a
/// `CursorButton` label.
struct EditorChip: View {
    let text: String
    var highlighted = false
    var tint: Color = novaAmber

    var body: some View {
        Text(text)
            .novaFont(.caption, weight: .semibold)
            .foregroundStyle(highlighted ? Color.black : Color.white)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(highlighted ? tint : Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(highlighted ? tint : .white.opacity(0.15)))
    }
}
