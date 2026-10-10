import Foundation

/// Every bindable in-game action, mirroring EV Nova's control set. `continuous`
/// actions are held (steering, thrust, fire); the rest fire once per press.
enum GameAction: String, CaseIterable, Codable, Identifiable {
    // Flight
    case accelerate, decelerate, turnLeft, turnRight, afterburner
    // Combat
    case firePrimary, fireSecondary, selectSecondaryPrev, selectSecondaryNext, toggleCloak
    /// Fighters launch by selecting a fighter-bay secondary and pulling
    /// `fireSecondary` — a bay is a secondary weapon, not a separate control.
    /// This is the one explicit fighter command left: call every deployed
    /// fighter home regardless of what it's doing.
    case recallFighters
    /// Abandon ship (the original's Alt+X): with an escape pod or an
    /// ejectable fighter bay, while disabled or going down (OS-02).
    case eject
    /// Standing orders for the whole escort wing (hired/captured escorts and
    /// bay-launched fighters alike) — EV Nova's Fleet Control keys, which work
    /// instantly without opening the Escorts window first.
    case commandEscortAggressive, commandEscortDefensive, commandEscortEvasive, commandEscortHold
    /// Opens the Escorts roster window directly. The original only reaches it
    /// by hailing a targeted escort/fighter (still works via `hailTarget`);
    /// this is a NovaSwift convenience to pull it up without targeting first.
    case openEscorts
    // Targeting
    case targetNearest, targetNext, nearestHostile, clearTarget
    // Navigation
    case land, hyperjump, galaxyMap, autopilot, hailTarget, board
    // Interface
    case pauseGame, openMenu
    /// Opens the Ship Info card for the currently targeted ship (or your own
    /// hull when nothing is targeted) — a NovaSwift convenience with no original
    /// key, the flight-side entry to the standalone ship-detail screen.
    case shipInfo
    // The original's commands NovaSwift lacked (UI-06, UI-07, UI-11, UI-13,
    // UI-15). New cases go at the end so stored bindings keep decoding.
    /// Shift-`: step the ship target backward.
    case targetPrevious
    /// Alt-`: cycle only the player's own escorts.
    case targetEscortNext
    /// Alt-N: clear the ship target (plain N clears the travel selection).
    case clearShipTarget
    /// 1–4: the current system's first four nav stellars.
    case selectNav1, selectNav2, selectNav3, selectNav4
    /// H: re-arm the plotted route's next hop as the jump target.
    case hyperspaceArm
    /// Return: dismiss the status-bar message.
    case dismissMessage
    /// P: the Player Info window.
    case playerInfo
    /// I: the mission info window.
    case missionInfo
    /// S: clear the secondary weapon selection.
    case clearSecondary
    /// Alt-Y: hail the selected stellar even with a ship targeted.
    case hailStellar
    /// Alt-−: self-destruct — held for five seconds, released to abort (UI-15).
    case selfDestruct
    /// C: escorts return to formation (order 0, slot 0x33).
    case commandEscortFormation
    /// Alt-C: carried fighters return to their hangar (order 3).
    case commandEscortReturnHangar

    var id: String { rawValue }

    var continuous: Bool {
        switch self {
        case .accelerate, .decelerate, .turnLeft, .turnRight, .afterburner,
             .firePrimary, .fireSecondary, .selfDestruct:
            return true
        default:
            return false
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case flight = "Flight", combat = "Combat", targeting = "Targeting"
        case navigation = "Navigation", interface = "Interface"
        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .accelerate, .decelerate, .turnLeft, .turnRight, .afterburner: return .flight
        case .firePrimary, .fireSecondary, .selectSecondaryPrev, .selectSecondaryNext, .toggleCloak,
             .recallFighters, .eject, .selfDestruct, .commandEscortAggressive, .commandEscortDefensive, .commandEscortEvasive,
             .commandEscortHold, .commandEscortFormation, .commandEscortReturnHangar: return .combat
        case .targetNearest, .targetNext, .nearestHostile, .clearTarget,
             .targetPrevious, .targetEscortNext, .clearShipTarget,
             .selectNav1, .selectNav2, .selectNav3, .selectNav4: return .targeting
        case .land, .hyperjump, .galaxyMap, .autopilot, .hailTarget, .board, .openEscorts,
             .hyperspaceArm, .hailStellar: return .navigation
        case .clearSecondary: return .combat
        case .pauseGame, .openMenu, .shipInfo, .dismissMessage, .playerInfo, .missionInfo: return .interface
        }
    }

    var title: String {
        switch self {
        case .accelerate: return "Accelerate"
        case .decelerate: return "Decelerate"
        case .turnLeft: return "Turn Left"
        case .turnRight: return "Turn Right"
        case .afterburner: return "Afterburner"
        case .firePrimary: return "Fire Primary Weapon"
        case .fireSecondary: return "Fire Secondary Weapon"
        case .selectSecondaryPrev: return "Previous Secondary"
        case .selectSecondaryNext: return "Next Secondary"
        case .toggleCloak: return "Toggle Cloak"
        case .recallFighters: return "Recall Fighters"
        case .eject: return "Eject"
        case .commandEscortAggressive: return "Escorts: Aggressive"
        case .commandEscortDefensive: return "Escorts: Defensive"
        case .commandEscortEvasive: return "Escorts: Evasive"
        case .commandEscortHold: return "Escorts: Hold Position"
        case .openEscorts: return "Open Escorts Window"
        case .targetNearest: return "Target Nearest Ship"
        case .targetNext: return "Cycle Target"
        case .nearestHostile: return "Target Nearest Hostile"
        case .clearTarget: return "Clear Target"
        case .land: return "Land / Depart"
        case .hyperjump: return "Hyperspace Jump"
        case .galaxyMap: return "Galaxy Map"
        case .autopilot: return "Autopilot"
        case .hailTarget: return "Hail Target"
        case .board: return "Board Target"
        case .pauseGame: return "Pause"
        case .openMenu: return "Menu"
        case .shipInfo: return "Ship Info"
        case .targetPrevious: return "Cycle Target Backward"
        case .targetEscortNext: return "Cycle Escorts"
        case .clearShipTarget: return "Clear Ship Target"
        case .selectNav1: return "Select Nav Destination 1"
        case .selectNav2: return "Select Nav Destination 2"
        case .selectNav3: return "Select Nav Destination 3"
        case .selectNav4: return "Select Nav Destination 4"
        case .hyperspaceArm: return "Hyperspace Destination"
        case .dismissMessage: return "Dismiss Message"
        case .playerInfo: return "Player Info"
        case .missionInfo: return "Mission Info"
        case .clearSecondary: return "Clear Secondary Weapon"
        case .hailStellar: return "Hail Planet"
        case .selfDestruct: return "Self-Destruct"
        case .commandEscortFormation: return "Escorts: Formation"
        case .commandEscortReturnHangar: return "Escorts: Return to Hangar"
        }
    }

    /// How this continuous action drives the flight `ControlIntent`.
    enum FlightEffect { case turnLeft, turnRight, thrust, reverse, afterburner, firePrimary, fireSecondary, selfDestruct, none }
    var flightEffect: FlightEffect {
        switch self {
        case .turnLeft: return .turnLeft
        case .turnRight: return .turnRight
        case .accelerate: return .thrust
        case .decelerate: return .reverse
        case .afterburner: return .afterburner
        case .firePrimary: return .firePrimary
        case .fireSecondary: return .fireSecondary
        case .selfDestruct: return .selfDestruct
        default: return .none
        }
    }
}
