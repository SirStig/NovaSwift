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

    var id: String { rawValue }

    var continuous: Bool {
        switch self {
        case .accelerate, .decelerate, .turnLeft, .turnRight, .afterburner,
             .firePrimary, .fireSecondary:
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
             .recallFighters, .commandEscortAggressive, .commandEscortDefensive, .commandEscortEvasive,
             .commandEscortHold: return .combat
        case .targetNearest, .targetNext, .nearestHostile, .clearTarget: return .targeting
        case .land, .hyperjump, .galaxyMap, .autopilot, .hailTarget, .board, .openEscorts: return .navigation
        case .pauseGame, .openMenu, .shipInfo: return .interface
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
        }
    }

    /// How this continuous action drives the flight `ControlIntent`.
    enum FlightEffect { case turnLeft, turnRight, thrust, reverse, afterburner, firePrimary, fireSecondary, none }
    var flightEffect: FlightEffect {
        switch self {
        case .turnLeft: return .turnLeft
        case .turnRight: return .turnRight
        case .accelerate: return .thrust
        case .decelerate: return .reverse
        case .afterburner: return .afterburner
        case .firePrimary: return .firePrimary
        case .fireSecondary: return .fireSecondary
        default: return .none
        }
    }
}
