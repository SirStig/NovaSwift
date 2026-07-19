import Foundation
import SwiftUI
import GameController

/// The live signals the flight-training tutorial watches for. Each `.objective`
/// step completes when the container observes its goal in the sandbox scene.
enum TutorialGoal {
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
struct TutorialStep: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let body: String
    let goal: TutorialGoal?
    var isManual: Bool { goal == nil }
}

/// Persistent record of whether the player has finished (or skipped) the flight
/// tutorial, so it's auto-offered to a brand-new pilot only once. It can still be
/// replayed any time from the main menu.
enum TutorialProgress {
    static let key = "novaswift.tutorialCompleted.v1"
    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Ordered course of steps, worded for the player's active control scheme and
/// key bindings so the instructions always match what's actually on screen.
/// Steps that would teach a capability the training ship lacks (afterburner,
/// secondary weapons) are dropped so the player is never asked to do something
/// impossible.
enum TutorialCourse {
    static func build(settings: GameSettings, bindings: KeyBindings,
                      hasAfterburner: Bool, hasSecondary: Bool) -> [TutorialStep] {
        var steps: [TutorialStep] = []

        steps.append(TutorialStep(
            id: "welcome", title: "Flight Training", systemImage: "graduationcap.fill",
            body: "Welcome aboard, Captain. This is a safe practice flight — nothing here touches your real pilot, and you can skip it any time. Let's run through the controls.",
            goal: nil))

        steps.append(TutorialStep(
            id: "fly", title: "Take the Helm", systemImage: "airplane",
            body: flyText(settings, bindings), goal: .fly))

        steps.append(TutorialStep(
            id: "turn", title: "Come About", systemImage: "arrow.turn.up.right",
            body: turnText(settings, bindings), goal: .turn))

        if hasAfterburner {
            steps.append(TutorialStep(
                id: "afterburner", title: "Afterburners", systemImage: "flame.fill",
                body: afterburnerText(settings, bindings), goal: .afterburner))
        }

        steps.append(TutorialStep(
            id: "target", title: "Lock a Target", systemImage: "scope",
            body: targetText(settings, bindings), goal: .target))

        steps.append(TutorialStep(
            id: "fire", title: "Open Fire", systemImage: "flame",
            body: fireText(settings, bindings), goal: .fire))

        if hasSecondary {
            steps.append(TutorialStep(
                id: "weapon", title: "Switch Weapons", systemImage: "arrow.left.arrow.right.circle",
                body: weaponText(settings, bindings), goal: .changeWeapon))
        }

        steps.append(TutorialStep(
            id: "land", title: "Come In to Land", systemImage: "airplane.arrival",
            body: landText(settings, bindings), goal: .land))

        steps.append(TutorialStep(
            id: "done", title: "Cleared for Duty", systemImage: "checkmark.seal.fill",
            body: "That's everything you need to survive out there — fly, fight, switch weapons, and land. You're ready, Captain. Fly safe.",
            goal: nil))

        return steps
    }

    // MARK: Control-aware instruction text

    /// The label to name a control with in instruction text. A connected game
    /// controller wins (the pad's own button name — "A", "Cross", "R2"), since
    /// someone holding a pad should be told pad buttons; otherwise the bound key.
    private static func key(_ action: GameAction, _ b: KeyBindings) -> String {
        if let pad = GCController.current?.extendedGamepad,
           let button = PadBindings.load().button(for: action) {
            return button.displayName(on: pad)
        }
        return KeyToken.label(b.token(for: action))
    }

    /// True when instructions should speak "controller" (a pad is connected).
    private static var padConnected: Bool { GCController.current?.extendedGamepad != nil }

    private static func flyText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Push the left stick up to thrust and sideways to steer — or hold \(key(.accelerate, b)) to throttle up. Get moving and build up some speed."
        }
        #if os(iOS)
        switch s.controlScheme {
        case .virtualCockpit:
            return "Hold the THRUST control on the right to fly forward, and steer with the turn control on the left. Get moving and build up some speed."
        case .tapToTurn:
            return "Touch and drag anywhere on screen — your ship turns toward your finger and thrusts after it. Fly around for a moment."
        case .tilt:
            return "Tilt your device left and right to steer, and hold THRUST to accelerate. Fly forward and get a feel for it."
        }
        #else
        return "Hold \(key(.accelerate, b)) to thrust forward, and \(key(.turnLeft, b)) / \(key(.turnRight, b)) to steer. Build up some speed."
        #endif
    }

    private static func turnText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Steer with the left stick — or snap your bow straight to a heading with the right stick. In space you keep drifting the old way until you thrust after the new one."
        }
        #if os(iOS)
        switch s.controlScheme {
        case .virtualCockpit:
            return "Use the turn control on the left to swing your bow around. In space there's no friction — you keep drifting the way you were going until you thrust the other way."
        case .tapToTurn:
            return "Drag to point your ship in a new direction. Remember: you keep drifting the old way until you thrust after your new heading."
        case .tilt:
            return "Tilt to bring your bow around to a new heading. You'll keep coasting the old way until you thrust after the new one."
        }
        #else
        return "Tap \(key(.turnLeft, b)) or \(key(.turnRight, b)) to bring your bow around to a new heading. In space you keep drifting the old way until you thrust after the new one."
        #endif
    }

    private static func afterburnerText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Hold \(key(.afterburner, b)) on the controller for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        }
        #if os(iOS)
        return "Tap and hold the AFTERBURNER control for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        #else
        return "Hold \(key(.afterburner, b)) for a burst of speed. It burns fuel fast, so save it for escapes and intercepts."
        #endif
    }

    private static func targetText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Press \(key(.targetNext, b)) on the controller to cycle targets, or \(key(.nearestHostile, b)) to lock the nearest hostile. Its details appear on your status panel."
        }
        #if os(iOS)
        return "Tap a ship out in space to lock it as your target — or open Actions and tap Target Nearest. Its details appear on your status panel."
        #else
        return "Press \(key(.targetNearest, b)) to lock the nearest ship, or \(key(.targetNext, b)) to cycle through targets. You can also click a ship directly. Its details appear on your status panel."
        #endif
    }

    private static func fireText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Press \(key(.firePrimary, b)) on the controller to fire your primary weapon. Give it a few shots."
        }
        #if os(iOS)
        return "Tap the FIRE control to shoot your primary weapon. Give it a few shots."
        #else
        return "Press \(key(.firePrimary, b)) to fire your primary weapon. Give it a few shots."
        #endif
    }

    private static func weaponText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Press \(key(.selectSecondaryNext, b)) (or \(key(.selectSecondaryPrev, b))) on the controller to cycle your secondary weapons. The selected one shows on your status panel."
        }
        #if os(iOS)
        return "Open Actions and tap Next Weapon to cycle your secondary weapons — missiles, bombs and the like. The selected one shows on your status panel."
        #else
        return "Press \(key(.selectSecondaryNext, b)) (or \(key(.selectSecondaryPrev, b))) to cycle your secondary weapons — missiles, bombs and the like. The selected one shows on your status panel."
        #endif
    }

    private static func landText(_ s: GameSettings, _ b: KeyBindings) -> String {
        if padConnected {
            return "Fly close to the planet and slow right down, then press \(key(.land, b)) on the controller when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        }
        #if os(iOS)
        return "Fly close to the planet and slow right down, then tap LAND when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        #else
        return "Fly close to the planet and slow right down, then press \(key(.land, b)) when the prompt appears. Landing is how you trade, refuel, outfit and take on missions."
        #endif
    }
}

/// Drives the tutorial's step machine. The container feeds it observed goals and
/// this decides when to advance — guarding each `complete(_:)` on the current
/// step so a stray early action (an itchy trigger finger) can't skip ahead.
@MainActor
final class TutorialRun: ObservableObject {
    @Published private(set) var steps: [TutorialStep] = []
    @Published private(set) var index = 0
    @Published private(set) var finished = false

    /// Populate the course once the sandbox ship's capabilities are known.
    func configure(_ newSteps: [TutorialStep]) {
        steps = newSteps
        index = 0
        finished = false
    }

    var current: TutorialStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isLast: Bool { index >= steps.count - 1 }
    var stepNumber: Int { index + 1 }
    var stepCount: Int { steps.count }

    /// Advance to the next step, or mark the whole course finished on the last.
    func advance() {
        guard !finished else { return }
        if isLast { finished = true } else { index += 1 }
    }

    /// Complete the current step iff it's waiting on exactly this goal.
    func complete(_ goal: TutorialGoal) {
        guard current?.goal == goal else { return }
        advance()
    }
}
