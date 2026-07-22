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

    /// The target currently under the visible cursor / being pressed by Ⓐ.
    /// Published so each `CursorClickable` can render its own hover-grow and
    /// press-squish (the pointer affordances a mouse gets for free). Written
    /// by the overlay's poll loop, only on actual change — not per tick.
    @Published private(set) var hoveredID: UUID?
    @Published private(set) var pressedID: UUID?

    struct Target {
        var frame: CGRect
        var action: () -> Void
        /// Optional point-aware press (cursor position in the target's own
        /// coordinates) — lets a slider jump its thumb to where Ⓐ landed.
        var actionAt: ((CGPoint) -> Void)?
        /// False for track-like targets (sliders) where a whole-view
        /// hover-grow would look wrong; buttons leave it true.
        var hoverEffect = true
    }

    /// Deliberately NOT `@Published`: frames refresh on every layout pass and
    /// publishing would re-render the world per frame. The overlay polls.
    private(set) var targets: [UUID: Target] = [:]

    func update(_ id: UUID, frame: CGRect, action: @escaping () -> Void,
                actionAt: ((CGPoint) -> Void)? = nil, hoverEffect: Bool = true) {
        // Global frames include render transforms, so the hover-grow/press-
        // squish animation would feed back into this very frame on the next
        // layout pass. Freeze the hit frame while its own effect is showing —
        // the action closure still refreshes.
        let frozen = (id == hoveredID || id == pressedID) ? targets[id]?.frame : nil
        targets[id] = Target(frame: frozen ?? frame, action: action, actionAt: actionAt,
                             hoverEffect: hoverEffect)
    }

    func remove(_ id: UUID) {
        targets.removeValue(forKey: id)
        if hoveredID == id { hoveredID = nil }
        if pressedID == id { pressedID = nil }
    }

    /// The target under a point. Smallest containing frame wins, so a button
    /// always beats the sheet or panel registered behind it.
    func hit(at point: CGPoint) -> (id: UUID, target: Target)? {
        targets
            .filter { $0.value.frame.contains(point) }
            .min { $0.value.frame.width * $0.value.frame.height
                 < $1.value.frame.width * $1.value.frame.height }
            .map { (id: $0.key, target: $0.value) }
    }

    /// Hover/press bookkeeping for the overlay's ~60 Hz loop: assigns only on
    /// real change so the published state doesn't re-render the UI per tick.
    func setHovered(_ id: UUID?) {
        if hoveredID != id { hoveredID = id }
    }

    func setPressed(_ id: UUID?) {
        if pressedID != id { pressedID = id }
    }
}

/// Maps layout-space rects (what `GeometryReader` reports) to drawn/screen
/// rects under ancestor `scaleEffect`s — a draw-time transform the layout
/// system can't see (verified: the debug overlay shows unscaled hit frames
/// compressed toward the scale anchor without this).
struct CursorFrameTransform: Equatable {
    var scale: CGFloat = 1
    /// The scale anchor in global layout coordinates (the point that doesn't
    /// move when the container scales about its centre). `nil` while the
    /// container hasn't been measured yet — see `ready`.
    var anchor: CGPoint?
    /// The container's *visual* scale, regardless of whether `scale` carries
    /// it. On OS versions that already fold ancestor `scaleEffect` into
    /// global geometry frames (see `CursorScaleEffect`'s probe) `scale` is 1 —
    /// but `actionAt` hit points still arrive in drawn coordinates and need
    /// this divided out to land in the target's own layout space.
    var pointScale: CGFloat = 1

    /// False only in the not-yet-measured window right after a scaled
    /// container appears; targets wait it out rather than register skewed.
    var ready: Bool { scale == 1 || anchor != nil }

    func apply(_ rect: CGRect) -> CGRect {
        guard scale != 1, let anchor else { return rect }
        return CGRect(x: anchor.x + (rect.minX - anchor.x) * scale,
                      y: anchor.y + (rect.minY - anchor.y) * scale,
                      width: rect.width * scale,
                      height: rect.height * scale)
    }
}

private struct CursorFrameTransformKey: EnvironmentKey {
    static let defaultValue = CursorFrameTransform()
}

extension EnvironmentValues {
    var cursorFrameTransform: CursorFrameTransform {
        get { self[CursorFrameTransformKey.self] }
        set { self[CursorFrameTransformKey.self] = newValue }
    }
}

private struct CursorScaleEffect: ViewModifier {
    let scale: CGFloat
    /// The scale anchor (this view's centre) in global layout coordinates.
    /// `nil` until the first geometry callback — descendants don't register
    /// at all until then, so a not-yet-measured anchor can't skew targets.
    @State private var anchor: CGPoint?
    /// Whether this OS build already folds ancestor `scaleEffect` into global
    /// geometry frames (behaviour differs across SwiftUI versions/platforms).
    /// Probed from a real measurement rather than assumed: the container's
    /// global frame is compared against its own layout size. When the system
    /// does it for us, descendants must NOT scale their frames again — that
    /// double-scale is exactly the "cursor lands beside the button" offset.
    @State private var systemAppliesScale: Bool?

    /// One measurement carrying both interpretations of the same view.
    private struct Probe: Equatable {
        var frame: CGRect     // global — drawn or layout space, OS-dependent
        var layoutSize: CGSize // always layout space (scaleEffect is layout-neutral)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            // Layout-neutral geometry observation (a bare GeometryReader here
            // would be greedy and break the content-hugging dialogs). Fires on
            // appear and on every geometry change.
            .onGeometryChange(for: Probe.self) { proxy in
                Probe(frame: proxy.frame(in: .global), layoutSize: proxy.size)
            } action: { probe in
                // The centre is the scale anchor, invariant either way.
                anchor = CGPoint(x: probe.frame.midX, y: probe.frame.midY)
                if probe.layoutSize.width > 0, scale != 1 {
                    // Whichever reading the measured width is closer to wins.
                    let drawn = probe.layoutSize.width * scale
                    systemAppliesScale =
                        abs(probe.frame.width - drawn) < abs(probe.frame.width - probe.layoutSize.width)
                }
                #if DEBUG
                print("[cursor] scale container ×\(scale) frame \(probe.frame) layout \(probe.layoutSize) systemAppliesScale \(String(describing: systemAppliesScale))")
                #endif
            }
            .environment(\.cursorFrameTransform, transform)
    }

    private var transform: CursorFrameTransform {
        if systemAppliesScale == true {
            // Global frames are already drawn-space: register them untouched
            // (scale 1 → ready), only hit points still need the visual scale
            // divided out for `actionAt`.
            return CursorFrameTransform(scale: 1, anchor: nil, pointScale: scale)
        }
        // Legacy semantics (or not yet probed — anchor nil keeps `ready`
        // false so descendants wait rather than register skewed).
        return CursorFrameTransform(scale: scale, anchor: anchor, pointScale: scale)
    }
}

extension View {
    /// `scaleEffect(_:)` for containers holding cursor-clickable controls:
    /// applies the visual scale AND tells descendant `cursorClickable`s about
    /// it so their hit frames land where the controls are drawn. Note: wraps
    /// the content in a `GeometryReader`, so the container must be sized by
    /// its parent (all current sites are full-viewport or explicitly framed).
    func cursorScaleEffect(_ scale: CGFloat) -> some View {
        modifier(CursorScaleEffect(scale: scale))
    }
}

private struct CursorClickable: ViewModifier {
    let action: () -> Void
    var actionAt: ((CGPoint) -> Void)?
    @State private var id = UUID()
    /// Ambient `.disabled()` must gate the cursor exactly like it gates taps —
    /// a disabled control's frame is deregistered so Ⓐ can't fire its action.
    @Environment(\.isEnabled) private var isEnabled
    /// Ancestor `cursorScaleEffect` — hit frames must be registered where the
    /// control is *drawn*; global layout frames don't include render scales.
    @Environment(\.cursorFrameTransform) private var frameTransform
    /// Re-renders this target when the cursor's hover/press target changes
    /// (an occasional event, not a per-tick one — see `setHovered`).
    @ObservedObject private var registry = CursorTargets.shared

    /// Track-like targets (the point-aware slider variant) skip the whole-view
    /// hover-grow; a stretched track bouncing under the cursor looks wrong.
    private var hoverEffect: Bool { actionAt == nil }

    func body(content: Content) -> some View {
        let hovered = hoverEffect && registry.hoveredID == id
        let pressed = hoverEffect && registry.pressedID == id
        content
            // The pointer affordances a mouse gets for free: grow a touch
            // under the cursor, squish while Ⓐ is held.
            .scaleEffect(pressed ? 0.92 : (hovered ? 1.07 : 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovered)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
            .background(
                GeometryReader { geo in
                    // Runs on every layout pass, keeping both the frame and the
                    // captured action fresh. Safe during view updates because the
                    // registry publishes nothing on target mutation.
                    let _ = {
                        if isEnabled, frameTransform.ready {
                            let t = frameTransform
                            // actionAt receives the hit point in this view's
                            // own layout coordinates — divide the ancestor's
                            // visual scale back out of the drawn-space offset.
                            let mappedActionAt = actionAt.map { f in
                                { (p: CGPoint) in
                                    f(CGPoint(x: p.x / t.pointScale, y: p.y / t.pointScale))
                                }
                            }
                            CursorTargets.shared.update(id, frame: t.apply(geo.frame(in: .global)),
                                                        action: action, actionAt: mappedActionAt,
                                                        hoverEffect: hoverEffect)
                        } else {
                            CursorTargets.shared.remove(id)
                        }
                    }()
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
        #if os(tvOS)
        // No real `Button` on tvOS: buttons there are ALWAYS focusable — the
        // focus engine ignores `.focusable(false)` for them — so the moment a
        // controller moves focus, the system paints its huge white focused
        // platter over the label. The cursor is the only pointer on tvOS, so
        // the label + a cursor target is the whole control.
        label()
            .contentShape(Rectangle())
            .cursorClickable(action)
        #else
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .cursorClickable(action)
        #endif
    }
}

/// Drop-in for `.buttonStyle(.plain)` that also makes the button a controller
/// cursor target — `.buttonStyle(.novaPlain)`. Off-tvOS it renders exactly a
/// plain button (re-wrapped via `Button(configuration)`); on tvOS it skips the
/// `Button` machinery entirely, keeping the control out of the focus engine
/// (see `CursorButton` — buttons there ignore `.focusable(false)`).
struct NovaPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .contentShape(Rectangle())
            .cursorClickable { configuration.trigger() }
        #else
        Button(configuration)
            .buttonStyle(.plain)
            .cursorClickable { configuration.trigger() }
        #endif
    }
}

extension PrimitiveButtonStyle where Self == NovaPlainButtonStyle {
    static var novaPlain: NovaPlainButtonStyle { NovaPlainButtonStyle() }
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
    @State private var hovering = false

    @Environment(\.novaDebugEnabled) private var novaDebug

    /// Where the overlay sits on screen + whether the loop should run — the
    /// poll task's identity, so it restarts when either changes. Targets
    /// register in *global* coordinates while the cursor draws (and its
    /// position state lives) in the overlay's *local* ones; the loop needs
    /// the local→global origin so the point it hit-tests is exactly the point
    /// under the drawn dot even when an ancestor keeps the overlay inset from
    /// the screen edge (e.g. the tvOS safe area).
    private struct Space: Hashable {
        var active: Bool
        var originX: CGFloat, originY: CGFloat
        var width: CGFloat, height: CGFloat
        var size: CGSize { CGSize(width: width, height: height) }
    }

    var body: some View {
        GeometryReader { geo in
            let globalFrame = geo.frame(in: .global)
            let space = Space(active: active,
                              originX: globalFrame.minX, originY: globalFrame.minY,
                              width: geo.size.width, height: geo.size.height)
            ZStack {
                if novaDebug {
                    // UI-debug: outline every registered hit frame, so a
                    // misaligned target is visible without a controller (the
                    // rects should sit exactly on the drawn controls).
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Canvas { ctx, _ in
                            #if DEBUG
                            print("[cursor] \(CursorTargets.shared.targets.count) targets: " +
                                  CursorTargets.shared.targets.values
                                      .map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
                                      .joined(separator: " | "))
                            #endif
                            // Target frames are global; this canvas draws in
                            // the overlay's local space.
                            ctx.translateBy(x: -globalFrame.minX, y: -globalFrame.minY)
                            for target in CursorTargets.shared.targets.values {
                                ctx.stroke(Path(target.frame),
                                           with: .color(target.hoverEffect ? .green : .cyan),
                                           lineWidth: 1)
                            }
                        }
                    }
                }
                if active, visible, let position {
                    cursorShape
                        .position(position)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: visible)
            .task(id: space) { await loop(in: space) }
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

    /// The special circle icon: a soft ring + centre dot that squeezes on Ⓐ
    /// and swells slightly over a clickable target (mirroring the target's
    /// own hover-grow, so "this is pressable" reads from both sides).
    private var cursorShape: some View {
        ZStack {
            Circle()
                .strokeBorder(novaAmber, lineWidth: 2.5)
                .background(Circle().fill(novaAmber.opacity(hovering ? 0.3 : 0.15)))
            Circle()
                .fill(novaAmber)
                .frame(width: 5, height: 5)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(clickPulse ? 0.72 : (hovering ? 1.15 : 1))
        .shadow(color: .black.opacity(0.6), radius: 3)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: clickPulse)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovering)
    }

    /// ~60 Hz stick poll while active: move, show/auto-hide, and click on the
    /// Ⓐ press edge. Lives in `.task(id:)` so it stops when a pad
    /// disconnects or flight takes the sticks back.
    private func loop(in space: Space) async {
        guard space.active else { return }
        let bounds = space.size
        /// The cursor's local position in the global space targets register in.
        func global(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + space.originX, y: p.y + space.originY)
        }
        defer {
            // Leave no stale hover/press behind when a pad disconnects or
            // flight takes the sticks back mid-hover.
            CursorTargets.shared.setHovered(nil)
            CursorTargets.shared.setPressed(nil)
            hovering = false
        }
        var wasPressed = false
        var idleTicks = 0
        while !Task.isCancelled {
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

                // Hover: whatever's under the visible cursor. `setHovered`
                // publishes only on change, so this is cheap per tick.
                let hit = (visible && !clickPulse) ? position.flatMap { CursorTargets.shared.hit(at: global($0)) } : nil
                if !clickPulse {
                    CursorTargets.shared.setHovered(hit?.target.hoverEffect == true ? hit?.id : nil)
                    hovering = hit?.target.hoverEffect == true
                }

                let pressed = pad.buttonA.isPressed
                if pressed, !wasPressed, visible, let p = position.map(global) {
                    clickPulse = true
                    if let (id, target) = CursorTargets.shared.hit(at: p) {
                        CursorTargets.shared.setPressed(id)
                        Haptics.play(.selection)
                        if let actionAt = target.actionAt {
                            actionAt(CGPoint(x: p.x - target.frame.minX, y: p.y - target.frame.minY))
                        } else {
                            target.action()
                        }
                    }
                } else if !pressed, wasPressed {
                    clickPulse = false
                    CursorTargets.shared.setPressed(nil)
                }
                wasPressed = pressed
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}
