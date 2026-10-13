import Foundation
import SwiftUI
import GameController
import NovaSwiftStory

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
/// key bindings so the instructions always match what's actually on screen. The
/// steps and wording are the shared `TutorialCurriculum` (NovaSwiftStory, also
/// used by the Godot frontend); this only supplies the control style and labels.
enum TutorialCourse {
    static func build(settings: GameSettings, bindings: KeyBindings,
                      hasAfterburner: Bool, hasSecondary: Bool) -> [TutorialStep] {
        TutorialCurriculum.build(style: controlStyle(settings),
                                 label: { key($0, bindings) },
                                 hasAfterburner: hasAfterburner, hasSecondary: hasSecondary)
    }

    /// How the player is steering: a connected pad wins, then the platform's scheme.
    private static func controlStyle(_ s: GameSettings) -> TutorialControlStyle {
        if padConnected { return .pad }
        #if os(iOS)
        switch s.controlScheme {
        case .virtualCockpit: return .touch(.virtualCockpit)
        case .tapToTurn: return .touch(.tapToTurn)
        case .tilt: return .touch(.tilt)
        }
        #else
        return .keyboard
        #endif
    }

    private static func gameAction(_ a: TutorialAction) -> GameAction {
        switch a {
        case .accelerate: return .accelerate
        case .turnLeft: return .turnLeft
        case .turnRight: return .turnRight
        case .afterburner: return .afterburner
        case .targetNearest: return .targetNearest
        case .nearestHostile: return .nearestHostile
        case .targetNext: return .targetNext
        case .firePrimary: return .firePrimary
        case .selectSecondaryNext: return .selectSecondaryNext
        case .selectSecondaryPrev: return .selectSecondaryPrev
        case .land: return .land
        }
    }

    /// The label to name a control with in instruction text. A connected game
    /// controller wins (the pad's own button name — "A", "Cross", "R2"), since
    /// someone holding a pad should be told pad buttons; otherwise the bound key.
    private static func key(_ tutorialAction: TutorialAction, _ b: KeyBindings) -> String {
        let action = gameAction(tutorialAction)
        if let pad = GCController.active?.extendedGamepad,
           let button = PadBindings.load().button(for: action) {
            return button.displayName(on: pad)
        }
        return KeyToken.label(b.token(for: action))
    }

    /// True when instructions should speak "controller" (a pad is connected).
    private static var padConnected: Bool { GCController.active?.extendedGamepad != nil }
}

/// Drives the tutorial's step machine. The container feeds it observed goals and
/// this decides when to advance — guarding each `complete(_:)` on the current
/// step so a stray early action (an itchy trigger finger) can't skip ahead.
@MainActor
final class TutorialRun: ObservableObject {
    @Published private(set) var steps: [TutorialStep] = []
    @Published private(set) var index = 0
    @Published private(set) var finished = false

    /// The shared step machine (NovaSwiftStory); the published fields mirror it.
    private var core = TutorialProgression()

    /// Populate the course once the sandbox ship's capabilities are known.
    func configure(_ newSteps: [TutorialStep]) {
        core.configure(newSteps)
        sync()
    }

    var current: TutorialStep? { core.current }
    var isLast: Bool { core.isLast }
    var stepNumber: Int { core.stepNumber }
    var stepCount: Int { core.stepCount }

    /// Advance to the next step, or mark the whole course finished on the last.
    func advance() {
        core.advance()
        sync()
    }

    /// Complete the current step iff it's waiting on exactly this goal.
    func complete(_ goal: TutorialGoal) {
        core.complete(goal)
        sync()
    }

    private func sync() {
        steps = core.steps
        index = core.index
        finished = core.finished
    }
}
