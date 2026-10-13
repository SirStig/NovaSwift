import Foundation

// The flight-training tutorial's pure logic, shared by the Apple app
// (`app/NovaSwift/Tutorial/TutorialModel.swift`) and the Godot frontend: the
// ordered coached steps (worded for the active control style), and the step
// machine that decides when a step is complete. The live-scene watching (did the
// player move / turn / lock a target) stays in each frontend.

/// The live signals the flight-training tutorial watches for. Each objective step
/// completes when the frontend observes its goal in the sandbox scene.
public enum TutorialGoal: String, Sendable, Equatable, CaseIterable {
    case fly          // travel a distance under thrust
    case turn         // change heading appreciably
    case afterburner  // engage the afterburner
    case target       // lock a target
    case fire         // open fire with the primary weapon
    case changeWeapon // cycle the selected secondary weapon
    case land         // set down on the training planet
}

/// One coached step. A step with a `goal` advances automatically when that goal
/// is observed; a step with no goal is a text card the player dismisses with the
/// Continue / finish button.
public struct TutorialStep: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let body: String
    public let goal: TutorialGoal?
    public var isManual: Bool { goal == nil }

    public init(id: String, title: String, systemImage: String, body: String, goal: TutorialGoal?) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.body = body
        self.goal = goal
    }
}

/// How the player is steering, which decides the wording of the instructions.
public enum TutorialControlStyle: Equatable, Sendable {
    /// A game controller is connected: name its buttons.
    case pad
    /// A touch device with the given on-screen control scheme.
    case touch(TutorialTouchScheme)
    /// Keyboard (and mouse).
    case keyboard
}

/// The iOS control schemes the touch wording distinguishes.
public enum TutorialTouchScheme: String, Sendable, Equatable {
    case virtualCockpit, tapToTurn, tilt
}

/// The controls the instruction text names. The frontend supplies the label for
/// each (a bound key, or the pad's own button name).
public enum TutorialAction: String, Sendable, CaseIterable {
    case accelerate, turnLeft, turnRight, afterburner
    case targetNearest, nearestHostile, targetNext
    case firePrimary, selectSecondaryNext, selectSecondaryPrev, land
}

/// Ordered course of steps, worded for the player's active control style and
/// key bindings so the instructions always match what's actually on screen.
/// Steps that would teach a capability the training ship lacks (afterburner,
/// secondary weapons) are dropped so the player is never asked to do something
/// impossible.
public enum TutorialCurriculum {
    public static func build(style: TutorialControlStyle,
                             label key: (TutorialAction) -> String,
                             hasAfterburner: Bool, hasSecondary: Bool) -> [TutorialStep] {
        var steps: [TutorialStep] = []

        steps.append(TutorialStep(
            id: "welcome", title: "Flight Training", systemImage: "graduationcap.fill",
            body: "Welcome aboard, Captain. This is a safe practice flight — nothing here touches your real pilot, and you can skip it any time. Let's run through the controls.",
            goal: nil))

        steps.append(TutorialStep(
            id: "fly", title: "Take the Helm", systemImage: "airplane",
            body: flyText(style, key), goal: .fly))

        steps.append(TutorialStep(
            id: "turn", title: "Come About", systemImage: "arrow.turn.up.right",
            body: turnText(style, key), goal: .turn))

        if hasAfterburner {
            steps.append(TutorialStep(
                id: "afterburner", title: "Afterburners", systemImage: "flame.fill",
                body: afterburnerText(style, key), goal: .afterburner))
        }

        steps.append(TutorialStep(
            id: "target", title: "Lock a Target", systemImage: "scope",
            body: targetText(style, key), goal: .target))

        steps.append(TutorialStep(
            id: "fire", title: "Open Fire", systemImage: "flame",
            body: fireText(style, key), goal: .fire))

        if hasSecondary {
            steps.append(TutorialStep(
                id: "weapon", title: "Switch Weapons", systemImage: "arrow.left.arrow.right.circle",
                body: weaponText(style, key), goal: .changeWeapon))
        }

        steps.append(TutorialStep(
            id: "land", title: "Come In to Land", systemImage: "airplane.arrival",
            body: landText(style, key), goal: .land))

        steps.append(TutorialStep(
            id: "done", title: "Cleared for Duty", systemImage: "checkmark.seal.fill",
            body: "That's everything you need to survive out there — fly, fight, switch weapons, and land. You're ready, Captain. Fly safe.",
            goal: nil))

        return steps
    }

    // MARK: Control-aware instruction text

    private static func flyText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Push the left stick up to thrust and sideways to steer — or hold \(key(.accelerate)) to throttle up. Get moving and build up some speed."
        case .touch(.virtualCockpit):
            return "Hold the THRUST control on the right to fly forward, and steer with the turn control on the left. Get moving and build up some speed."
        case .touch(.tapToTurn):
            return "Touch and drag anywhere on screen — your ship turns toward your finger and thrusts after it. Fly around for a moment."
        case .touch(.tilt):
            return "Tilt your device left and right to steer, and hold THRUST to accelerate. Fly forward and get a feel for it."
        case .keyboard:
            return "Hold \(key(.accelerate)) to thrust forward, and \(key(.turnLeft)) / \(key(.turnRight)) to steer. Build up some speed."
        }
    }

    private static func turnText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Steer with the left stick — or snap your bow straight to a heading with the right stick. In space you keep drifting the old way until you thrust after the new one."
        case .touch(.virtualCockpit):
            return "Use the turn control on the left to swing your bow around. In space there's no friction — you keep drifting the way you were going until you thrust the other way."
        case .touch(.tapToTurn):
            return "Drag to point your ship in a new direction. Remember: you keep drifting the old way until you thrust after your new heading."
        case .touch(.tilt):
            return "Tilt to bring your bow around to a new heading. You'll keep coasting the old way until you thrust after the new one."
        case .keyboard:
            return "Tap \(key(.turnLeft)) or \(key(.turnRight)) to bring your bow around to a new heading. In space you keep drifting the old way until you thrust after the new one."
        }
    }

    private static func afterburnerText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Hold \(key(.afterburner)) on the controller for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        case .touch:
            return "Tap and hold the AFTERBURNER control for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        case .keyboard:
            return "Hold \(key(.afterburner)) for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        }
    }

    private static func targetText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Press \(key(.targetNext)) on the controller to cycle targets, or \(key(.nearestHostile)) to lock the nearest hostile. Its details appear on your status panel."
        case .touch:
            return "Tap a ship out in space to lock it as your target — or open Actions and tap Target Nearest. Its details appear on your status panel."
        case .keyboard:
            return "Press \(key(.targetNearest)) to lock the nearest ship, or \(key(.targetNext)) to cycle through targets. You can also click a ship directly. Its details appear on your status panel."
        }
    }

    private static func fireText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Press \(key(.firePrimary)) on the controller to fire your primary weapon. Give it a few shots."
        case .touch:
            return "Tap the FIRE control to shoot your primary weapon. Give it a few shots."
        case .keyboard:
            return "Press \(key(.firePrimary)) to fire your primary weapon. Give it a few shots."
        }
    }

    private static func weaponText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Press \(key(.selectSecondaryNext)) (or \(key(.selectSecondaryPrev))) on the controller to cycle your secondary weapons. The selected one shows on your status panel."
        case .touch:
            return "Open Actions and tap Next Weapon to cycle your secondary weapons — missiles, bombs and the like. The selected one shows on your status panel."
        case .keyboard:
            return "Press \(key(.selectSecondaryNext)) (or \(key(.selectSecondaryPrev))) to cycle your secondary weapons — missiles, bombs and the like. The selected one shows on your status panel."
        }
    }

    private static func landText(_ style: TutorialControlStyle, _ key: (TutorialAction) -> String) -> String {
        switch style {
        case .pad:
            return "Fly close to the planet and slow right down, then press \(key(.land)) on the controller when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        case .touch:
            return "Fly close to the planet and slow right down, then tap LAND when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        case .keyboard:
            return "Fly close to the planet and slow right down, then press \(key(.land)) when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        }
    }
}

/// The tutorial's step machine. The frontend feeds it observed goals and this
/// decides when to advance — guarding each `complete(_:)` on the current step so
/// a stray early action (an itchy trigger finger) can't skip ahead.
public struct TutorialProgression: Sendable {
    public private(set) var steps: [TutorialStep] = []
    public private(set) var index = 0
    public private(set) var finished = false

    public init() {}

    /// Populate the course once the sandbox ship's capabilities are known.
    public mutating func configure(_ newSteps: [TutorialStep]) {
        steps = newSteps
        index = 0
        finished = false
    }

    public var current: TutorialStep? { steps.indices.contains(index) ? steps[index] : nil }
    public var isLast: Bool { index >= steps.count - 1 }
    public var stepNumber: Int { index + 1 }
    public var stepCount: Int { steps.count }

    /// Advance to the next step, or mark the whole course finished on the last.
    public mutating func advance() {
        guard !finished else { return }
        if isLast { finished = true } else { index += 1 }
    }

    /// Complete the current step iff it's waiting on exactly this goal.
    public mutating func complete(_ goal: TutorialGoal) {
        guard current?.goal == goal else { return }
        advance()
    }
}
