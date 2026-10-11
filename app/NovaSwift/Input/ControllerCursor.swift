import SwiftUI
import GameController

/// Registry of controller-clickable UI targets. Views opt in with
/// `.cursorClickable(action)`, which records their global-space frame here;
/// `ControllerCursorOverlay` reads it to decide what a press of Ⓐ activates.
///
/// Three things scope which targets a press can reach, so the cursor only ever
/// acts on what the player can actually see on top:
/// - **Host** — each window-like surface (the root view, every sheet / full-
///   screen cover) mounts its own cursor via `.cursorHost()`; targets belong to
///   the host they're drawn in, and only the topmost host's cursor runs. (A
///   sheet is a separate presentation: the root overlay draws *under* it on
///   iOS/tvOS and in another window on macOS, and its global coordinates are
///   its own.)
/// - **Layer** — `.cursorModal()` lifts an in-hierarchy dialog/overlay one
///   layer above what it covers; only the highest occupied layer in the host is
///   live, so Ⓐ can't press a button hidden behind a dialog and Ⓑ can't cancel
///   the screen underneath it.
/// - **Suspension** — while something else owns the pad (a rebind capture, the
///   tvOS system keyboard) the cursor is inert.
@MainActor
final class CursorTargets: ObservableObject {
    static let shared = CursorTargets()

    /// The root view's host id — the default for anything not inside a sheet.
    nonisolated static let rootHost = UUID()

    /// True while the flight scene owns the controller (sticks are flying the
    /// ship) — the cursor hides and Ⓐ stays a weapon trigger. Kept current by
    /// `GameContainerView`; false outside the game, so menus are cursorable.
    @Published var suppressed = false

    /// Reasons the cursor is temporarily inert (see `suspend(_:)`).
    @Published private(set) var suspensions: Set<String> = []

    /// Presented cursor hosts, bottom to top. The root is always first.
    @Published private(set) var hostStack: [UUID] = [CursorTargets.rootHost]
    var activeHost: UUID { hostStack.last ?? Self.rootHost }

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
        /// coordinates) — lets a slider jump its thumb to where Ⓐ landed, and
        /// keeps tracking while Ⓐ is held (drag).
        var actionAt: ((CGPoint) -> Void)?
        /// False for track-like targets (sliders, the star map) where a
        /// whole-view hover-grow would look wrong; buttons leave it true.
        var hoverEffect = true
        /// Point-aware targets only: whether holding Ⓐ keeps re-sending the
        /// point as the cursor moves (a slider drag) or it's one pick per press.
        var drags = true
        var host = CursorTargets.rootHost
        var layer = 0
    }

    /// A dialog's Esc/Return equivalent for Ⓑ / Menu (see `.cursorCancel`).
    struct KeyAction {
        enum Kind { case cancel, `default` }
        var kind: Kind
        var host: UUID
        var layer: Int
        /// First-registration order: the newest dialog on a layer wins.
        var sequence: Int
        var action: () -> Void
    }

    /// Deliberately NOT `@Published`: frames refresh on every layout pass and
    /// publishing would re-render the world per frame. The overlay polls.
    private(set) var targets: [UUID: Target] = [:]
    /// `.cursorModal()` surfaces: (host, layer) occupied even if the dialog has
    /// no clickable control of its own (a pure message still blocks Ⓐ).
    private var blockers: [UUID: (host: UUID, layer: Int)] = [:]
    private var keyActions: [UUID: KeyAction] = [:]
    private var nextSequence = 0

    func update(_ id: UUID, frame: CGRect, action: @escaping () -> Void,
                actionAt: ((CGPoint) -> Void)? = nil, hoverEffect: Bool = true,
                drags: Bool = true,
                host: UUID = CursorTargets.rootHost, layer: Int = 0) {
        // No freezing while hovered/pressed: `CursorClickable` reads its frame
        // outside its own hover-grow/press-squish, so that animation provably
        // never feeds back into the measurement (verified — a 1.07 hover scale
        // leaves the reported frame byte-identical). Freezing only ever pinned a
        // stale rect across a real layout change.
        targets[id] = Target(frame: frame, action: action, actionAt: actionAt,
                             hoverEffect: hoverEffect, drags: drags, host: host, layer: layer)
    }

    func remove(_ id: UUID) {
        targets.removeValue(forKey: id)
        if hoveredID == id { hoveredID = nil }
        if pressedID == id { pressedID = nil }
    }

    // MARK: Hosts, layers, suspension

    func pushHost(_ id: UUID) {
        hostStack.removeAll { $0 == id }
        hostStack.append(id)
    }

    func popHost(_ id: UUID) {
        guard id != Self.rootHost else { return }
        hostStack.removeAll { $0 == id }
    }

    func addBlocker(_ id: UUID, host: UUID, layer: Int) { blockers[id] = (host, layer) }
    func removeBlocker(_ id: UUID) { blockers.removeValue(forKey: id) }

    /// Park the cursor while something else owns the pad. Balanced by
    /// `resume(_:)` with the same reason; idempotent both ways.
    func suspend(_ reason: String) {
        if !suspensions.contains(reason) { suspensions.insert(reason) }
    }

    func resume(_ reason: String) {
        if suspensions.contains(reason) { suspensions.remove(reason) }
    }

    /// The highest occupied layer in a host — the only live one.
    func topLayer(in host: UUID) -> Int {
        var top = 0
        for t in targets.values where t.host == host { top = max(top, t.layer) }
        for b in blockers.values where b.host == host { top = max(top, b.layer) }
        for k in keyActions.values where k.host == host { top = max(top, k.layer) }
        return top
    }

    /// Targets the cursor in `host` may currently reach.
    func live(in host: UUID) -> [(id: UUID, target: Target)] {
        let top = topLayer(in: host)
        return targets.compactMap { $0.value.host == host && $0.value.layer == top ? ($0.key, $0.value) : nil }
    }

    /// The target under a point. Smallest containing frame wins, so a button
    /// always beats the sheet or panel registered behind it. With `slop`, a
    /// point just outside a small control still lands on it (the nearest edge
    /// within `slop` points) — tiny chrome on a big screen stays pressable.
    func hit(at point: CGPoint, in host: UUID = CursorTargets.rootHost,
             slop: CGFloat = 0) -> (id: UUID, target: Target)? {
        let candidates = live(in: host)
        if let exact = candidates
            .filter({ $0.target.frame.contains(point) })
            .min(by: { $0.target.frame.area < $1.target.frame.area }) {
            return exact
        }
        guard slop > 0 else { return nil }
        return candidates
            .map { (hit: $0, d: $0.target.frame.distance(to: point)) }
            .filter { $0.d <= slop }
            .min { $0.d < $1.d }?.hit
    }

    /// D-pad snapping: the best target in `direction` from `point` — the one
    /// whose centre is ahead and most nearly in line (sideways offset costs
    /// more than distance, so ↓ in a column picks the next row, not a nearer
    /// button off to the side). Track targets (sliders, the map) are skipped;
    /// the d-pad steps between buttons.
    func neighbor(from point: CGPoint, toward direction: CGVector,
                  in host: UUID, excluding current: UUID?) -> (id: UUID, target: Target)? {
        var best: (id: UUID, target: Target)?
        var bestScore = CGFloat.infinity
        for candidate in live(in: host) where candidate.target.hoverEffect && candidate.id != current {
            let c = CGPoint(x: candidate.target.frame.midX, y: candidate.target.frame.midY)
            let v = CGVector(dx: c.x - point.x, dy: c.y - point.y)
            let along = v.dx * direction.dx + v.dy * direction.dy
            guard along > 4 else { continue }
            let across = abs(v.dx * direction.dy - v.dy * direction.dx)
            // Outside a ~63° cone it's not really "that way".
            guard across <= along * 2 else { continue }
            let score = along + across * 2.5
            if score < bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    // MARK: Ⓑ / Menu dialog keys

    func setKeyAction(_ id: UUID, kind: KeyAction.Kind, host: UUID, layer: Int,
                      action: (() -> Void)?) {
        guard let action else { keyActions.removeValue(forKey: id); return }
        let sequence: Int
        if let existing = keyActions[id]?.sequence {
            sequence = existing
        } else {
            nextSequence += 1
            sequence = nextSequence
        }
        keyActions[id] = KeyAction(kind: kind, host: host, layer: layer,
                                   sequence: sequence, action: action)
    }

    func removeKeyAction(_ id: UUID) { keyActions.removeValue(forKey: id) }

    /// Fire the newest live dialog's cancel (Ⓑ) or default (Menu) item.
    /// Returns false when nothing on the live layer offers one.
    @discardableResult
    func performKey(_ kind: KeyAction.Kind, in host: UUID) -> Bool {
        let top = topLayer(in: host)
        guard let entry = keyActions.values
            .filter({ $0.kind == kind && $0.host == host && $0.layer == top })
            .max(by: { $0.sequence < $1.sequence }) else { return false }
        entry.action()
        return true
    }

    // MARK: Hover / press bookkeeping

    /// Hover/press bookkeeping for the overlay's ~60 Hz loop: assigns only on
    /// real change so the published state doesn't re-render the UI per tick.
    func setHovered(_ id: UUID?) {
        if hoveredID != id { hoveredID = id }
    }

    func setPressed(_ id: UUID?) {
        if pressedID != id { pressedID = id }
    }
}

extension CGRect {
    fileprivate var area: CGFloat { width * height }

    /// Distance from a point to the nearest point of this rect (0 inside).
    fileprivate func distance(to p: CGPoint) -> CGFloat {
        let dx = Swift.max(minX - p.x, 0, p.x - maxX)
        let dy = Swift.max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Environment (host + layer)

private struct CursorHostKey: EnvironmentKey {
    static let defaultValue = CursorTargets.rootHost
}

private struct CursorLayerKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Which cursor host (root or a sheet) this view draws in.
    var cursorHost: UUID {
        get { self[CursorHostKey.self] }
        set { self[CursorHostKey.self] = newValue }
    }

    /// The cursor modal layer this view sits on (see `.cursorModal()`).
    var cursorLayer: Int {
        get { self[CursorLayerKey.self] }
        set { self[CursorLayerKey.self] = newValue }
    }
}

/// `scaleEffect(_:)` for containers holding cursor-clickable controls.
///
/// This is now a plain alias, kept because a dozen call sites read better for
/// saying "this scale has cursor targets under it" — and because the name is a
/// warning: a container that scales its contents used to have to *tell* its
/// descendants so they could correct their hit frames. It doesn't any more, and
/// must not try.
///
/// Measured on this SwiftUI generation (macOS 27 / iOS 26 / tvOS 26, probe in
/// the session notes), a descendant's `frame(in: .global)` is already reported
/// in **drawn** space: ancestor `scaleEffect` *and* ancestor `offset` (which is
/// how `novaPlace` positions every authentic control) are both folded in, and
/// nested scale containers compose on their own — outer 1.4 × inner 0.5 reports
/// a ratio of exactly 0.7. So a hit frame read at the control is already correct
/// and needs no adjustment whatsoever.
///
/// What used to happen: `CursorScaleEffect` probed whether the OS folded the
/// scale in by comparing its *own* `frame(in: .global)` against its layout size.
/// A geometry read at the modifier's own level always reports layout space, so
/// that comparison always concluded "the OS does not fold it in" — at every
/// scale, on every OS — and descendants dutifully scaled their already-drawn
/// frames a second time. The hit rect drifted away from the drawn control by
/// (scale − 1) × its distance from the container's centre, so the cursor had to
/// sit well off a button to press it. `novaFrameScale` floors at 1.0 on a phone
/// (no error, which is why it felt fine there) and rises to ~1.41 on a 1080p-
/// point 4K TV and up to 2.6 on a large desktop — precisely where it was worst.
extension View {
    func cursorScaleEffect(_ scale: CGFloat) -> some View {
        scaleEffect(scale)
    }
}

private struct CursorClickable: ViewModifier {
    let action: () -> Void
    var actionAt: ((CGPoint) -> Void)?
    var drags = true
    @State private var id = UUID()
    /// Ambient `.disabled()` must gate the cursor exactly like it gates taps —
    /// a disabled control's frame is deregistered so Ⓐ can't fire its action.
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.cursorHost) private var host
    @Environment(\.cursorLayer) private var layer
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
                        guard isEnabled else { CursorTargets.shared.remove(id); return }
                        // Already drawn-space: every ancestor `scaleEffect` and
                        // `offset` (i.e. `novaPlace`) is folded in here by
                        // SwiftUI, and nested scale containers compose. Register
                        // it verbatim — adjusting it is what put the hit rect
                        // beside the button. This reader sits *outside* the
                        // hover-grow below, so that effect can't feed back in.
                        let drawn = geo.frame(in: .global)
                        // ...which also makes the drawn/layout width ratio the
                        // exact cumulative visual scale, needed to hand a
                        // point-aware target (a slider track) a hit point in its
                        // own layout coordinates.
                        let visualScale = geo.size.width > 0 ? drawn.width / geo.size.width : 1
                        let mappedActionAt = actionAt.map { f in
                            { (p: CGPoint) in
                                f(CGPoint(x: p.x / visualScale, y: p.y / visualScale))
                            }
                        }
                        CursorTargets.shared.update(id, frame: drawn, action: action,
                                                    actionAt: mappedActionAt,
                                                    hoverEffect: hoverEffect, drags: drags,
                                                    host: host, layer: layer)
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
    /// It's called on the Ⓐ press and — with `drags` — again as the cursor
    /// moves while Ⓐ is held, so tracks can be dragged.
    func cursorClickable(drags: Bool = true, at actionAt: @escaping (CGPoint) -> Void) -> some View {
        modifier(CursorClickable(action: {}, actionAt: actionAt, drags: drags))
    }
}

// MARK: - Modal layers, dialog keys, hosts

private struct CursorModal: ViewModifier {
    @Environment(\.cursorHost) private var host
    @Environment(\.cursorLayer) private var layer
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.cursorLayer, layer + 1)
            .onAppear { CursorTargets.shared.addBlocker(id, host: host, layer: layer + 1) }
            .onDisappear { CursorTargets.shared.removeBlocker(id) }
    }
}

private struct CursorKey: ViewModifier {
    let kind: CursorTargets.KeyAction.Kind
    let action: (() -> Void)?
    @Environment(\.cursorHost) private var host
    @Environment(\.cursorLayer) private var layer
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()

    func body(content: Content) -> some View {
        // Re-registered on every update so the captured action stays current;
        // the registry publishes nothing here, so this is safe mid-update.
        let _ = CursorTargets.shared.setKeyAction(id, kind: kind, host: host, layer: layer,
                                                  action: isEnabled ? action : nil)
        content.onDisappear { CursorTargets.shared.removeKeyAction(id) }
    }
}

private struct CursorHost: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.cursorHost, id)
            .environment(\.cursorLayer, 0)
            .overlay { CursorHostChrome(host: id) }
            .onAppear { CursorTargets.shared.pushHost(id) }
            .onDisappear { CursorTargets.shared.popHost(id) }
    }
}

/// What a sheet's host draws over its content: the pad keyboard (when this is
/// the top host — it must appear inside the sheet the text field is in), any
/// `novaAlert` raised inside the sheet, and the sheet's own cursor.
private struct CursorHostChrome: View {
    let host: UUID
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var registry = CursorTargets.shared

    var body: some View {
        ZStack {
            if registry.activeHost == host, let request = model.padKeyboard {
                PadKeyboardView(request: request)
                    .id(request.id)
                    .environment(\.cursorHost, host)
                    .transition(.opacity)
            }
            NovaAlertLayer(host: host)
            ControllerCursorOverlay(host: host)
        }
    }
}

extension View {
    /// Marks an in-hierarchy dialog / overlay / panel that covers other UI:
    /// while it's on screen, only cursor targets inside it are pressable and
    /// only its Ⓑ/Menu keys fire. Put it on the dialog's outermost view
    /// (scrim included). Nest freely — each modal lifts one more layer.
    func cursorModal() -> some View {
        modifier(CursorModal())
    }

    /// Makes Ⓑ on a controller do what Esc does here (dismiss / cancel / back).
    /// Pass nil while there's nothing to cancel. The newest live registration
    /// wins, so a nested dialog's cancel beats the screen underneath it.
    func cursorCancel(_ action: (() -> Void)?) -> some View {
        modifier(CursorKey(kind: .cancel, action: action))
    }

    /// Makes the controller's Menu/Start button do what Return does here (the
    /// dialog's default item).
    func cursorDefault(_ action: (() -> Void)?) -> some View {
        modifier(CursorKey(kind: .default, action: action))
    }

    /// Gives a separately-presented surface (`.sheet` / `.fullScreenCover`
    /// content) its own controller cursor. Required: the root cursor draws
    /// beneath sheets on iOS/tvOS and in a different window on macOS.
    func cursorHost() -> some View {
        modifier(CursorHost())
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

// MARK: - The cursor

/// The circle cursor itself — one per host: `RootView` mounts the root one,
/// `.cursorHost()` one per sheet; only the topmost host's runs. When a
/// controller is connected and flight isn't consuming the sticks:
///
/// - **Left stick** moves the cursor (speed scales with the surface size, so a
///   full-tilt sweep takes the same time on a phone as on a 4K TV; it slows
///   over a pressable control for precision).
/// - **Right stick** scrolls / pans whatever scrollable is under the cursor
///   (lists, outfit/ship grids, the star map).
/// - **D-pad** snaps the cursor to the next control in that direction (holding
///   repeats); with nothing further that way, it scrolls instead.
/// - **Ⓐ** presses what the cursor is over (held on a slider or the map, it
///   drags). **Ⓑ** is back/cancel (Esc), **Menu** the default button (Return).
///
/// It shows when a menu takes over from flight and fades after a few idle
/// seconds. Draws nothing without a pad.
struct ControllerCursorOverlay: View {
    var host: UUID = CursorTargets.rootHost

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var padState = PadState.shared
    @ObservedObject private var registry = CursorTargets.shared

    @State private var position: CGPoint?
    /// The surface size `position` was last laid out against — a resize,
    /// rotation or window change keeps the cursor at the same relative spot.
    @State private var lastSize: CGSize?
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
    /// the screen edge (e.g. the tvOS safe area, a form-sheet on iPad).
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
                if novaDebug, registry.activeHost == host {
                    // UI-debug: outline every live hit frame (green buttons,
                    // cyan tracks, dashed orange scrollables), so a misaligned
                    // target is visible without a controller — the rects should
                    // sit exactly on the drawn controls.
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Canvas { ctx, _ in
                            // Target frames are global; this canvas draws in
                            // the overlay's local space.
                            ctx.translateBy(x: -globalFrame.minX, y: -globalFrame.minY)
                            for (_, target) in CursorTargets.shared.live(in: host) {
                                ctx.stroke(Path(target.frame),
                                           with: .color(target.hoverEffect ? .green : .cyan),
                                           lineWidth: 1)
                            }
                            for target in CursorScrollTargets.shared.live(in: host) {
                                ctx.stroke(Path(target.frame),
                                           with: .color(.orange.opacity(0.7)),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
        padState.isConnected && !registry.suppressed && registry.suspensions.isEmpty
            && registry.activeHost == host
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

    /// Stick response: rescale past the dead zone to 0…1, then ease in
    /// (mostly quadratic) — precise at small deflection, fast at full tilt.
    static func response(_ magnitude: Double, deadzone: Double) -> Double {
        let t = min(1, max(0, (magnitude - deadzone) / max(0.01, 1 - deadzone)))
        return t * t * 0.8 + t * 0.2
    }

    /// ~60 Hz pad poll while active: move, scroll, snap, show/auto-hide, and
    /// the Ⓐ/Ⓑ/Menu press edges. Lives in `.task(id:)` so it stops when a pad
    /// disconnects, flight takes the sticks back, or another host covers this
    /// one.
    private func loop(in space: Space) async {
        guard space.active else { return }
        let bounds = space.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let diagonal = Double((bounds.width * bounds.width + bounds.height * bounds.height).squareRoot())
        let registry = CursorTargets.shared
        let scrolls = CursorScrollTargets.shared

        /// The cursor's local position in the global space targets register in.
        func global(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + space.originX, y: p.y + space.originY)
        }
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - space.originX, y: p.y - space.originY)
        }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        }

        // Resolution independence: a resize/rotation/window move keeps the
        // cursor at the same relative spot instead of stranding it off-screen.
        if let p = position, let last = lastSize, last != bounds, last.width > 0, last.height > 0 {
            position = CGPoint(x: p.x / last.width * bounds.width, y: p.y / last.height * bounds.height)
        }
        lastSize = bounds
        position = clamp(position ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2))
        // A menu just took over from flight (or a sheet opened): show where
        // the cursor is rather than making the player wiggle a stick to find it.
        visible = true

        defer {
            // Leave no stale hover/press behind when a pad disconnects or
            // flight takes the sticks back mid-hover.
            registry.setHovered(nil)
            registry.setPressed(nil)
            hovering = false
            clickPulse = false
        }

        // Buttons already down when the loop starts (Ⓐ still held from firing
        // as a dialog popped up, Menu still held from opening the menu) must
        // be released before they count — no phantom press on activation.
        let pad0 = GCController.current?.extendedGamepad
        var wasA = pad0?.buttonA.isPressed ?? false
        var wasB = pad0?.buttonB.isPressed ?? false
        var wasMenu = pad0?.buttonMenu.isPressed ?? false
        var heldDirection: CGVector?
        var repeatAt = 0
        var tick = 0
        var idleTicks = 0
        var dragID: UUID?
        var lastDragPoint: CGPoint?

        while !Task.isCancelled {
            tick += 1
            if let pad = GCController.current?.extendedGamepad, var p = position {
                let dz = max(0.1, model.settings.stickDeadzone)
                var acted = false

                // Left stick: move.
                let lx = Double(pad.leftThumbstick.xAxis.value)
                let ly = Double(pad.leftThumbstick.yAxis.value)
                let lMag = (lx * lx + ly * ly).squareRoot()
                if lMag > dz {
                    // A full-tilt sweep crosses ~¾ of the diagonal per second
                    // on any surface; a hovered control adds friction so it's
                    // easy to stop on, even when it's small on a big screen.
                    var speed = diagonal * 0.75 * model.settings.cursorSensitivity
                        * Self.response(lMag, deadzone: dz) / 60
                    if hovering { speed *= 0.55 }
                    p.x += CGFloat(lx / lMag * speed)
                    p.y -= CGFloat(ly / lMag * speed)   // stick up = cursor up
                    p = clamp(p)
                    acted = true
                }

                // Right stick: scroll/pan the scrollable under the cursor (or
                // the screen's main one when the cursor isn't over any).
                let rx = Double(pad.rightThumbstick.xAxis.value)
                let ry = Double(pad.rightThumbstick.yAxis.value)
                let rMag = (rx * rx + ry * ry).squareRoot()
                if rMag > dz, let scroll = scrolls.target(at: global(p), in: host) {
                    let speed = Double(bounds.height) * 1.6 * Self.response(rMag, deadzone: dz) / 60
                    // Content-offset convention: +dy shows what's further down.
                    scroll.scrollBy(CGVector(dx: rx / rMag * speed, dy: -ry / rMag * speed))
                    acted = true
                }

                // D-pad: snap between controls; scroll at the end of the line.
                let direction: CGVector? =
                    pad.dpad.up.isPressed ? CGVector(dx: 0, dy: -1)
                    : pad.dpad.down.isPressed ? CGVector(dx: 0, dy: 1)
                    : pad.dpad.left.isPressed ? CGVector(dx: -1, dy: 0)
                    : pad.dpad.right.isPressed ? CGVector(dx: 1, dy: 0)
                    : nil
                if let direction {
                    let fire: Bool
                    if direction != heldDirection { fire = true; repeatAt = tick + 22 }   // ~0.37 s
                    else if tick >= repeatAt { fire = true; repeatAt = tick + 7 }          // then ~8.5/s
                    else { fire = false }
                    if fire {
                        let here = global(p)
                        let current = registry.hit(at: here, in: host)?.id
                        if let next = registry.neighbor(from: here, toward: direction,
                                                        in: host, excluding: current) {
                            p = clamp(local(CGPoint(x: next.target.frame.midX, y: next.target.frame.midY)))
                            Haptics.play(.selection)
                        } else if let scroll = scrolls.target(at: here, in: host) {
                            scroll.scrollBy(CGVector(dx: direction.dx * 80, dy: direction.dy * 80))
                        }
                    }
                    acted = true
                }
                heldDirection = direction

                if acted {
                    position = p
                    visible = true
                    idleTicks = 0
                } else if visible {
                    idleTicks += 1
                    if idleTicks > 240, dragID == nil { visible = false }   // ~4 s idle → fade out
                }

                let here = global(p)

                // Hover: whatever's under the visible cursor (with a little
                // slop so tiny chrome isn't a pixel hunt). `setHovered`
                // publishes only on change, so this is cheap per tick.
                if !clickPulse {
                    let hit = visible ? registry.hit(at: here, in: host, slop: 6) : nil
                    registry.setHovered(hit?.target.hoverEffect == true ? hit?.id : nil)
                    hovering = hit != nil
                }

                // Ⓐ: press on the edge; held on a point-aware target, drag.
                let a = pad.buttonA.isPressed
                if a, !wasA {
                    clickPulse = true
                    visible = true
                    idleTicks = 0
                    if let (id, target) = registry.hit(at: here, in: host, slop: 6) {
                        registry.setPressed(id)
                        Haptics.play(.selection)
                        if let actionAt = target.actionAt {
                            actionAt(CGPoint(x: here.x - target.frame.minX, y: here.y - target.frame.minY))
                            if target.drags {
                                dragID = id
                                lastDragPoint = here
                            }
                        } else {
                            target.action()
                        }
                    }
                } else if a, let id = dragID, here != lastDragPoint,
                          let target = registry.targets[id], let actionAt = target.actionAt {
                    actionAt(CGPoint(x: here.x - target.frame.minX, y: here.y - target.frame.minY))
                    lastDragPoint = here
                } else if !a, wasA {
                    clickPulse = false
                    dragID = nil
                    lastDragPoint = nil
                    registry.setPressed(nil)
                }
                wasA = a

                // Ⓑ = Esc (cancel / back), Menu = Return (default item).
                let b = pad.buttonB.isPressed
                if b, !wasB, registry.performKey(.cancel, in: host) { Haptics.play(.light) }
                wasB = b
                let menu = pad.buttonMenu.isPressed
                if menu, !wasMenu, registry.performKey(.default, in: host) { Haptics.play(.light) }
                wasMenu = menu
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}
