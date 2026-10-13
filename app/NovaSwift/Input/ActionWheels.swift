import Foundation
import SwiftUI

/// One Steam-style action wheel: hold `trigger`, flick the right stick toward
/// a slot, release to fire it. A quick tap of the trigger still does the
/// button's normal bound action (see `GameControllerInput`), so a shoulder
/// button costs nothing to turn into a wheel.
struct ActionWheel: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var trigger: PadButton
    /// Clockwise from the top; 4...12 entries.
    var slots: [GameAction]

    static let slotRange = 4...12

    /// Which side of the screen the wheel opens on: the side of the hand that
    /// holds its trigger (face buttons, RB/RT/R3 and Menu are right-hand).
    var opensOnRight: Bool {
        switch trigger {
        case .rightShoulder, .rightTrigger, .rightThumbstickButton, .buttonMenu,
             .buttonA, .buttonB, .buttonX, .buttonY: return true
        default: return false
        }
    }

    init(id: String, title: String, trigger: PadButton, slots: [GameAction]) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.slots = slots
    }

    // Slots decode leniently: an action a later build removed is dropped
    // rather than invalidating the player's whole wheel setup.
    private enum CodingKeys: String, CodingKey { case id, title, trigger, slots }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        trigger = try c.decode(PadButton.self, forKey: .trigger)
        slots = try c.decode([String].self, forKey: .slots).compactMap(GameAction.init(rawValue:))
    }
}

/// The player's set of wheels (the wheel counterpart of `PadBindings`).
struct ActionWheels: Equatable {
    var wheels: [ActionWheel]

    init(wheels: [ActionWheel] = ActionWheels.defaults) { self.wheels = wheels }

    static let defaults: [ActionWheel] = [
        ActionWheel(id: "combat", title: "Combat & Fleet", trigger: .leftShoulder, slots: [
            .toggleCloak, .commandEscortAggressive, .commandEscortDefensive, .commandEscortEvasive,
            .commandEscortHold, .commandEscortFormation, .commandEscortReturnHangar, .recallFighters,
            .openEscorts, .clearSecondary, .eject, .selfDestruct]),
        ActionWheel(id: "nav", title: "Targeting & Nav", trigger: .rightShoulder, slots: [
            .targetNearest, .targetPrevious, .targetEscortNext, .clearShipTarget,
            .selectNav1, .selectNav2, .selectNav3, .selectNav4,
            .hailStellar, .hyperspaceArm, .cycleHyperspaceLink, .autopilot]),
        ActionWheel(id: "info", title: "Info & View", trigger: .buttonOptions, slots: [
            .playerInfo, .missionInfo, .shipInfo, .dismissMessage, .cycleCameraView,
            .cameraZoomIn, .cameraZoomOut, .routeMapZoomIn, .routeMapZoomOut, .pauseGame]),
    ]

    func wheel(for trigger: PadButton) -> ActionWheel? { wheels.first { $0.trigger == trigger } }

    mutating func resetToDefaults() { wheels = Self.defaults }

    /// Actions the left stick and triggers already cover (never need a slot).
    static let stickActions: Set<GameAction> = [.turnLeft, .turnRight, .accelerate, .decelerate]

    /// Whether `action` may sit in a wheel slot: any fire-once action, plus
    /// self-destruct (continuous in the original — held five seconds — so a
    /// wheel latches it; see `GameControllerInput`). Fire/thrust/afterburner
    /// are held controls and make no sense as a one-shot slot.
    static func isSlotEligible(_ action: GameAction) -> Bool {
        !action.continuous || action == .selfDestruct
    }

    /// Whether `button` may become a wheel trigger. A held control (fire,
    /// afterburner, thrust) can't double as tap/hold.
    static func canTrigger(_ button: PadButton, bindings: PadBindings) -> Bool {
        bindings.action(for: button)?.continuous != true
    }

    /// Every action the pad can't reach — neither bound to a button nor in a
    /// wheel slot. (Turning and throttle ride the left stick / triggers.)
    static func uncovered(bindings: PadBindings, wheels: ActionWheels) -> [GameAction] {
        let reachable = Set(bindings.map.keys).union(wheels.wheels.flatMap(\.slots))
        return GameAction.allCases.filter { !stickActions.contains($0) && !reachable.contains($0) }
    }

    /// Slot under a stick direction. `x`/`y` are stick axes (y up). Slot 0 is
    /// centred at the top and indices run clockwise. nil inside `threshold`
    /// (stick near centre) or for an empty wheel.
    static func slotIndex(x: Float, y: Float, count: Int, threshold: Float = 0.5) -> Int? {
        guard count > 0, hypot(x, y) > threshold else { return nil }
        return slotIndex(angle: Double(atan2(x, y)), count: count)
    }

    /// Slot for a compass angle (radians, 0 = up, clockwise positive).
    static func slotIndex(angle: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = 2 * Double.pi / Double(count)
        let i = Int((angle / step).rounded())
        return ((i % count) + count) % count
    }

    // MARK: Persistence

    static let storageKey = "com.novaswift.actionwheels.v1"

    static func load() -> ActionWheels {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ActionWheel].self, from: data) else {
            return ActionWheels()
        }
        // Stored wheels replace the defaults wholesale; a wheel left with too
        // few slots (actions removed since it was saved) is dropped.
        return ActionWheels(wheels: decoded.filter { ActionWheel.slotRange.contains($0.slots.count) })
    }

    func save() {
        if let data = try? JSONEncoder().encode(wheels) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// What the on-screen wheel shows. Written by `GameControllerInput.poll`
/// (dispatched to main only when something changes), read by
/// `ActionWheelOverlay`.
@MainActor
final class ActionWheelState: ObservableObject {
    static let shared = ActionWheelState()
    @Published var openWheel: ActionWheel?
    @Published var highlighted: Int?
    private init() {}

    func apply(wheel: ActionWheel?, highlighted: Int?) {
        if openWheel != wheel { openWheel = wheel }
        if self.highlighted != highlighted { self.highlighted = highlighted }
    }
}

extension GameAction {
    /// SF Symbol for the action wheel and editor.
    var icon: String {
        switch self {
        case .accelerate: return "arrow.up.circle"
        case .decelerate: return "arrow.down.circle"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        case .afterburner: return "flame"
        case .firePrimary: return "scope"
        case .fireSecondary: return "target"
        case .selectSecondaryPrev: return "chevron.left.circle"
        case .selectSecondaryNext: return "chevron.right.circle"
        case .toggleCloak: return "eye.slash"
        case .recallFighters: return "airplane.arrival"
        case .eject: return "figure.fall"
        case .commandEscortAggressive: return "bolt.shield"
        case .commandEscortDefensive: return "shield"
        case .commandEscortEvasive: return "arrow.uturn.backward"
        case .commandEscortHold: return "hand.raised"
        case .openEscorts: return "person.3"
        case .targetNearest: return "dot.viewfinder"
        case .targetNext: return "arrow.right.circle"
        case .nearestHostile: return "exclamationmark.triangle"
        case .clearTarget: return "xmark.circle"
        case .land: return "arrow.down.to.line"
        case .hyperjump: return "sparkles"
        case .galaxyMap: return "map"
        case .autopilot: return "location.north.line"
        case .hailTarget: return "antenna.radiowaves.left.and.right"
        case .board: return "arrow.right.to.line"
        case .pauseGame: return "pause.circle"
        case .openMenu: return "line.3.horizontal"
        case .shipInfo: return "info.circle"
        case .targetPrevious: return "arrow.left.circle"
        case .targetEscortNext: return "person.2"
        case .clearShipTarget: return "xmark.square"
        case .selectNav1: return "1.circle"
        case .selectNav2: return "2.circle"
        case .selectNav3: return "3.circle"
        case .selectNav4: return "4.circle"
        case .hyperspaceArm: return "scope"
        case .dismissMessage: return "text.bubble"
        case .playerInfo: return "person.crop.circle"
        case .missionInfo: return "list.bullet.clipboard"
        case .clearSecondary: return "minus.circle"
        case .hailStellar: return "globe"
        case .selfDestruct: return "exclamationmark.octagon"
        case .commandEscortFormation: return "triangle"
        case .commandEscortReturnHangar: return "house"
        case .cycleHyperspaceLink: return "arrow.triangle.2.circlepath"
        case .routeMapZoomOut: return "minus.magnifyingglass"
        case .routeMapZoomIn: return "plus.magnifyingglass"
        case .cycleCameraView: return "camera.viewfinder"
        case .cameraZoomIn: return "plus.circle"
        case .cameraZoomOut: return "minus.circle"
        }
    }
}
