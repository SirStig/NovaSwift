import SwiftUI
import GameController

/// Registry of controller-clickable UI targets. Views opt in with
/// `.cursorClickable(action)`, which records their global-space frame here;
/// `ControllerCursorOverlay` reads it to decide what a press of Ⓐ activates.
/// Not on tvOS — there the system focus engine drives UI.
@MainActor
final class CursorTargets: ObservableObject {
    static let shared = CursorTargets()

    /// True while the flight scene owns the controller (sticks are flying the
    /// ship) — the cursor hides and Ⓐ stays a weapon trigger. Kept current by
    /// `GameContainerView`; false outside the game, so menus are cursorable.
    @Published var suppressed = false

    struct Target {
        var frame: CGRect
        var action: () -> Void
        /// Optional point-aware press (cursor position in the target's own
        /// coordinates) — lets a slider jump its thumb to where Ⓐ landed.
        var actionAt: ((CGPoint) -> Void)?
    }

    /// Deliberately NOT `@Published`: frames refresh on every layout pass and
    /// publishing would re-render the world per frame. The overlay polls.
    private(set) var targets: [UUID: Target] = [:]

    func update(_ id: UUID, frame: CGRect, action: @escaping () -> Void,
                actionAt: ((CGPoint) -> Void)? = nil) {
        targets[id] = Target(frame: frame, action: action, actionAt: actionAt)
    }

    func remove(_ id: UUID) {
        targets.removeValue(forKey: id)
    }

    /// The target under a point. Smallest containing frame wins, so a button
    /// always beats the sheet or panel registered behind it.
    func target(at point: CGPoint) -> Target? {
        targets.values
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

private struct CursorClickable: ViewModifier {
    let action: () -> Void
    var actionAt: ((CGPoint) -> Void)?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    // Runs on every layout pass, keeping both the frame and the
                    // captured action fresh. Safe during view updates because the
                    // registry publishes nothing on mutation.
                    let _ = CursorTargets.shared.update(id, frame: geo.frame(in: .global),
                                                        action: action, actionAt: actionAt)
                    Color.clear
                        .onDisappear { CursorTargets.shared.remove(id) }
                }
            )
            #if os(tvOS)
            // The cursor IS the interaction model — keep cursor-driven controls
            // out of the focus engine so Ⓐ can't also activate an invisibly
            // focused button somewhere else on screen.
            .focusable(false)
            #endif
    }
}

extension View {
    /// Lets the controller-driven UI cursor press this view (Ⓐ while the
    /// circle cursor hovers it). Pass the same action the control performs.
    func cursorClickable(_ action: @escaping () -> Void) -> some View {
        modifier(CursorClickable(action: action))
    }

    /// Point-aware variant: the closure receives the cursor position in this
    /// view's own coordinate space (for sliders/tracks, not plain buttons).
    func cursorClickable(at actionAt: @escaping (CGPoint) -> Void) -> some View {
        modifier(CursorClickable(action: {}, actionAt: actionAt))
    }
}

/// A plain-style `Button` the controller cursor can press — drop-in for the
/// `Button { … } label: { … }.buttonStyle(.plain)` pattern all the custom
/// chrome uses, without duplicating the action into a separate registration.
struct CursorButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .cursorClickable(action)
    }
}

/// The circle cursor itself, mounted once over the whole UI (`RootView`).
/// When a controller is connected and flight isn't consuming the sticks,
/// pushing a thumbstick reveals it and steers it (speed × the "Controller
/// cursor speed" setting); Ⓐ presses whatever it hovers; it fades out after a
/// few idle seconds. Draws nothing on tvOS or without a controller.
struct ControllerCursorOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var padState = PadState.shared
    @ObservedObject private var registry = CursorTargets.shared

    @State private var position: CGPoint?
    @State private var visible = false
    @State private var clickPulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if active, visible, let position {
                    cursorShape
                        .position(position)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: visible)
            .task(id: active) { await loop(in: geo.size) }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var active: Bool {
        // tvOS included: the pointer model is deliberately the same on every
        // platform — stick moves the circle, Ⓐ presses — instead of making TV
        // players hop focus between buttons.
        padState.isConnected && !registry.suppressed
    }

    /// The special circle icon: a soft ring + centre dot that squeezes on Ⓐ.
    private var cursorShape: some View {
        ZStack {
            Circle()
                .strokeBorder(novaAmber, lineWidth: 2.5)
                .background(Circle().fill(novaAmber.opacity(0.15)))
            Circle()
                .fill(novaAmber)
                .frame(width: 5, height: 5)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(clickPulse ? 0.72 : 1)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: clickPulse)
    }

    /// ~60 Hz stick poll while active: move, show/auto-hide, and click on the
    /// Ⓐ press edge. Lives in `.task(id: active)` so it stops when a pad
    /// disconnects or flight takes the sticks back.
    private func loop(in bounds: CGSize) async {
        guard active else { return }
        var wasPressed = false
        var idleTicks = 0
        while !Task.isCancelled {
            defer {}
            if let pad = GCController.current?.extendedGamepad {
                // Either stick steers the cursor — use whichever is deflected more.
                let l = (x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value))
                let r = (x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value))
                let stick = (l.x * l.x + l.y * l.y) >= (r.x * r.x + r.y * r.y) ? l : r
                let dz = max(0.1, model.settings.stickDeadzone)
                let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()

                if magnitude > dz {
                    var p = position ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2)
                    // Quadratic response: precise at small deflection, fast at full tilt.
                    let speed = 900.0 * model.settings.cursorSensitivity * magnitude * (1.0 / 60.0)
                    p.x += CGFloat(stick.x / max(magnitude, 0.001) * speed)
                    p.y -= CGFloat(stick.y / max(magnitude, 0.001) * speed)   // stick up = cursor up
                    p.x = min(max(p.x, 0), bounds.width)
                    p.y = min(max(p.y, 0), bounds.height)
                    position = p
                    visible = true
                    idleTicks = 0
                } else if visible {
                    idleTicks += 1
                    if idleTicks > 240 { visible = false }   // ~4 s idle → fade out
                }

                let pressed = pad.buttonA.isPressed
                if pressed, !wasPressed, visible, let p = position {
                    clickPulse = true
                    if let target = CursorTargets.shared.target(at: p) {
                        Haptics.play(.selection)
                        if let actionAt = target.actionAt {
                            actionAt(CGPoint(x: p.x - target.frame.minX, y: p.y - target.frame.minY))
                        } else {
                            target.action()
                        }
                    }
                } else if !pressed, wasPressed {
                    clickPulse = false
                }
                wasPressed = pressed
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}
