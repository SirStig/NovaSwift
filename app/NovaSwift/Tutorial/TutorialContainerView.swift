import SwiftUI
import SpriteKit
import Combine

/// A full-screen, self-contained flight-training session. It reuses the real
/// flight simulation (`GameScene`) through a throwaway `GameHost` sandbox — so
/// the controls are exactly the ones the player will use in the game and honour
/// their control scheme / key bindings — but wires none of the pilot-save hooks,
/// makes the trainee invulnerable, and never persists anything. A coaching
/// overlay walks through flying, turning, targeting, firing, switching weapons
/// and landing, advancing as it observes each action in the live scene.
struct TutorialContainerView: View {
    @EnvironmentObject private var model: AppModel
    /// Label for the final "you're done" button and what happens after (set by
    /// the presenter — begin play for a new pilot, or return to the menu).
    var finishLabel: String = "Done"
    var onFinish: () -> Void

    @State private var host: GameHost?
    @StateObject private var run = TutorialRun()
    @FocusState private var focused: Bool

    // Per-step baselines for the goals measured relative to where a step began.
    @State private var distanceSinceBaseline: Double = 0
    @State private var baselineHeading: Double = 0
    @State private var lastSampledPos: CGPoint?

    /// Polls the sandbox scene for objective completion. 5 Hz is plenty for
    /// "did they move / turn / lock a target" and costs almost nothing.
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let host {
                sceneLayer(host)
                    .focused($focused)

                hudLayer(host)

                #if os(iOS)
                GeometryReader { geo in
                    TouchControlsOverlay(
                        input: host.input, hud: host.hud, viewportSize: geo.size,
                        tapToFly: model.settings.controlScheme == .tapToTurn,
                        rightInset: sidebarWidth(geo.size, hudStyle),
                        onDiscrete: handleDiscrete, onOpenPanel: { _ in })
                }
                #endif

                GeometryReader { geo in
                    ContextualActionsView(hud: host.hud, landOnly: true,
                                          onAction: { if $0 == .land { landAttempt() } },
                                          rightInset: sidebarWidth(geo.size, hudStyle))
                }

                MessageLogView(hud: host.hud)

                TutorialCoachView(run: run, finishLabel: finishLabel, onFinish: onFinish)
            } else {
                GameLoadingView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard host == nil else { return }
            let built = GameHost.makeTrainingHost(model: model)
            host = built
            guard let built else { return }
            // Capture the run object (not `self`) so the scene's stored closure
            // can't form a retain cycle through `@State host` and leak the sandbox.
            let tutorialRun = run
            built.scene.onPlayerFired = { tutorialRun.complete(.fire) }
            built.scene.tapToFlyEnabled = (model.settings.controlScheme == .tapToTurn)
            let ship = built.scene.playerShip
            let steps = TutorialCourse.build(
                settings: model.settings, bindings: model.bindings,
                hasAfterburner: ship?.afterburner != nil,
                hasSecondary: !(ship?.secondaryWeaponIDs.isEmpty ?? true))
            run.configure(steps)
            resetBaseline()
            built.hud.post("Training flight — nothing here affects your pilot.")
            grabFocus()
        }
        .onChange(of: run.index) { _, _ in resetBaseline() }
        .onReceive(ticker) { _ in sample() }
    }

    // MARK: Layers

    @ViewBuilder
    private func sceneLayer(_ host: GameHost) -> some View {
        GeometryReader { geo in
            let sidebar = sidebarWidth(geo.size, hudStyle)
            let playWidth = max(0, geo.size.width - sidebar)
            SpriteView(scene: host.scene,
                       preferredFramesPerSecond: model.settings.frameRateCap.fps ?? 120,
                       options: [.ignoresSiblingOrder])
                .frame(width: playWidth, height: geo.size.height)
                .position(x: playWidth / 2, y: geo.size.height / 2)
                .id(ObjectIdentifier(host.scene))
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
    }

    @ViewBuilder
    private func hudLayer(_ host: GameHost) -> some View {
        if let style = hudStyle {
            GeometryReader { geo in
                AuthenticHUDView(model: host.hud, style: style, showRadar: model.settings.showRadar,
                                 targetSprite: { host.targetSilhouette(shipType: $0) })
                    .frame(width: sidebarWidth(geo.size, style), height: geo.size.height, alignment: .trailing)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .opacity(model.settings.hudOpacity)
        } else {
            GameHUDView(model: host.hud, showRadar: model.settings.showRadar,
                        largerHUD: model.settings.largerHUD,
                        highContrast: model.settings.highContrastHUD)
                .opacity(model.settings.hudOpacity)
        }
    }

    private var hudStyle: AuthenticHUDStyle? {
        model.settings.modernHUD ? nil : host?.hudStyle
    }

    /// The width the authentic status bar reserves on the right, matching
    /// `GameContainerView.sidebarWidth` so the play viewport lines up.
    private func sidebarWidth(_ size: CGSize, _ style: AuthenticHUDStyle?) -> CGFloat {
        guard let style, style.nativeSize.height > 0 else { return 0 }
        let scale = size.height / style.nativeSize.height
        return min(style.nativeSize.width * scale, size.width * 0.35)
    }

    // MARK: Input handling (a deliberately trimmed subset of the real container)

    private func handleDiscrete(_ action: GameAction) {
        guard let scene = host?.scene else { return }
        switch action {
        case .land:
            landAttempt()
        case .targetNearest:
            scene.selectNearestTarget()
        case .nearestHostile:
            scene.selectNearestHostile()
        case .targetNext:
            scene.cycleTarget()
        case .clearTarget:
            scene.clearTarget()
        case .selectSecondaryNext:
            if scene.cycleSecondaryWeapon(forward: true) != nil { run.complete(.changeWeapon) }
        case .selectSecondaryPrev:
            if scene.cycleSecondaryWeapon(forward: false) != nil { run.complete(.changeWeapon) }
        default:
            // Map / jump / hail / board and friends are intentionally inert in the
            // sandbox — the tutorial keeps the player on flying, fighting and
            // landing, and never leaves the training system.
            break
        }
    }

    private func landAttempt() {
        guard let scene = host?.scene, let id = scene.attemptLand() else { return }
        _ = id
        host?.hud.post("Docking clamps engaged — nicely done, Captain.")
        run.complete(.land)
    }

    // MARK: Objective watching

    /// Sampled at 5 Hz: accumulates travel and checks the current step's goal.
    private func sample() {
        guard let ship = host?.scene.playerShip, !run.finished else { return }
        let pos = CGPoint(x: ship.position.x, y: ship.position.y)
        if let last = lastSampledPos {
            distanceSinceBaseline += Double(hypot(pos.x - last.x, pos.y - last.y))
        }
        lastSampledPos = pos

        guard let goal = run.current?.goal else { return }
        switch goal {
        case .fly:
            if distanceSinceBaseline > 650 { run.complete(.fly) }
        case .turn:
            if abs(angleDelta(ship.angle, baselineHeading)) > 1.2 { run.complete(.turn) }
        case .afterburner:
            if host?.input.intent.afterburner == true || ship.afterburnerActive {
                run.complete(.afterburner)
            }
        case .target:
            if ship.currentTargetID != nil { run.complete(.target) }
        case .fire, .changeWeapon, .land:
            break   // event-driven (onPlayerFired / handleDiscrete / landAttempt)
        }
    }

    /// Claim keyboard focus for the flight scene (macOS), retrying a few times —
    /// a single deferred set can lose the race before the focusable scene view has
    /// entered the hierarchy, which would leave the ship unflyable by keyboard.
    private func grabFocus(attempt: Int = 0) {
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !focused, attempt < 5, host != nil { grabFocus(attempt: attempt + 1) }
            }
        }
    }

    private func resetBaseline() {
        distanceSinceBaseline = 0
        let ship = host?.scene.playerShip
        baselineHeading = ship?.angle ?? 0
        lastSampledPos = ship.map { CGPoint(x: $0.position.x, y: $0.position.y) }
    }

    /// Shortest signed angular difference `a - b`, wrapped to (-π, π].
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
}
