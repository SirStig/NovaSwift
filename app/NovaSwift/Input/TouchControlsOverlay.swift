import SwiftUI
import NovaSwiftEngine
#if os(iOS)
import UIKit
#endif

/// Container-owned panels the mobile controls can open (these live in
/// `GameContainerView`, not reachable through `handleDiscrete`).
enum MobilePanel { case missions, pilotInfo }

/// The on-screen "virtual cockpit" for touch play. Deliberately sparse: only the
/// controls you hold constantly are always visible — **turn on the left, thrust
/// on the right**, so one thumb steers while the other drives — with target/next/
/// afterburner/fire-2nd and fire tucked beside thrust. Everything occasional
/// (map, jump, hail, board, missions, escorts, pilot, cloak, recall) lives
/// behind a single expandable Actions button, so the screen stays uncluttered;
/// the pause menu (top-left) and the amber Land pill (bottom-centre, when
/// cleared to land) are separate always-on controls, not grid entries.
///
/// The whole thing is one `VStack` with transparent `Spacer`s, not a stack of
/// full-screen layers — so only the buttons themselves capture touches and the
/// open middle stays free for tap/drag-to-fly steering and target taps. Every
/// hold control has a generous rectangular hit area and recognises
/// simultaneously with its siblings, so two thumbs register at once and a press
/// near a button's edge still counts.
///
/// Sizes scale with the smaller screen edge (`Metrics`): compact-but-tappable on
/// a small iPhone, a bit larger on an iPad — deliberately sized so the whole
/// drive cluster fits a landscape iPhone's short (~375–430pt) edge with room
/// to spare, rather than "as big as comfortably tappable." Styling is the EV
/// Nova HUD idiom — dark caps with a thin amber bevel, amber glyphs on the
/// action controls, white on the neutral ones.
struct TouchControlsOverlay: View {
    let input: InputController
    @ObservedObject var hud: GameHUDModel
    var viewportSize: CGSize = .zero
    var tapToFly: Bool = false
    var rightInset: CGFloat = 0
    var onDiscrete: (GameAction) -> Void = { _ in }
    var onOpenPanel: (MobilePanel) -> Void = { _ in }

    @State private var menuOpen = false

    /// Button/spacing sizes from the smaller screen edge: 1× on a small iPhone,
    /// up to 1.35× on an iPad, so controls read the same relative size
    /// everywhere. Sized to stay clear on a landscape iPhone's short (~375–430pt)
    /// edge — the whole cockpit (toggle + drive cluster) has to fit in that
    /// height alongside the open middle, so every control is deliberately
    /// compact rather than "as big as comfortably tappable."
    private struct Metrics {
        let s: CGFloat
        init(_ size: CGSize) {
            let minEdge = min(size.width == 0 ? 430 : size.width, size.height == 0 ? 430 : size.height)
            s = min(max(minEdge / 430, 0.86), 1.35)
        }
        var big: CGFloat { 58 * s }     // fire / thrust / turn
        var small: CGFloat { 40 * s }   // target / next / afterburner / fire-2nd
        var toggle: CGFloat { 44 * s }  // actions open/close
        var tile: CGFloat { 56 * s }    // action-grid tile
        var gap: CGFloat { 10 * s }
        var edge: CGFloat { 14 * s }
    }

    private var m: Metrics { Metrics(viewportSize) }

    var body: some View {
        ZStack {
            if menuOpen {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { menuOpen = false } }
            }

            VStack(spacing: 0) {
                // Top-right: the Actions toggle and, when open, the grid.
                HStack(alignment: .top) {
                    Spacer()
                    VStack(alignment: .trailing, spacing: m.gap) {
                        actionsToggle
                        if menuOpen {
                            actionGrid
                                .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                        }
                    }
                    .padding(.trailing, rightInset + m.edge)
                    .padding(.top, m.edge)
                }

                Spacer(minLength: 0)   // open middle — free for steering / target taps

                // Bottom: turn (left thumb) · thrust + fire (right thumb).
                HStack(alignment: .bottom) {
                    if !tapToFly { turnCluster }
                    Spacer(minLength: 0)
                    driveCluster.padding(.trailing, rightInset)
                }
                .padding(.horizontal, m.edge)
                .padding(.bottom, m.edge + 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Steering (bottom-left)

    private var turnCluster: some View {
        HStack(alignment: .bottom, spacing: m.gap) {
            labeled("Turn Left") {
                HoldButton(size: m.big, onChange: { input.touch.turnLeft = $0 }) {
                    NovaControlCap(system: "arrowtriangle.left.fill", size: m.big)
                }
            }
            labeled("Turn Right") {
                HoldButton(size: m.big, onChange: { input.touch.turnRight = $0 }) {
                    NovaControlCap(system: "arrowtriangle.right.fill", size: m.big)
                }
            }
        }
    }

    // MARK: Drive + fire (bottom-right; thrust is the rightmost, outer button)

    /// Two rows, not four: the four secondary holds (target/next/afterburn/
    /// fire-2nd) sit in one row so the whole cluster fits the short edge of a
    /// landscape iPhone alongside the open middle and the Actions toggle above
    /// it — a stack of four rows ran taller than the screen on small phones.
    private var driveCluster: some View {
        VStack(alignment: .trailing, spacing: m.gap) {
            weaponChip
            // Combat targeting + holds, always visible: locking an enemy,
            // cycling to the next, burning or firing the secondary must never
            // mean opening the Actions menu mid-dogfight.
            HStack(alignment: .bottom, spacing: m.gap * 0.7) {
                labeled("Target") {
                    TapButton(size: m.small, onTap: { onDiscrete(.targetNearest) }) {
                        NovaControlCap(system: "scope", size: m.small, accent: true)
                    }
                }
                labeled("Next") {
                    TapButton(size: m.small, onTap: { onDiscrete(.targetNext) }) {
                        NovaControlCap(system: "arrow.triangle.2.circlepath", size: m.small)
                    }
                }
                labeled("Afterburn") {
                    HoldButton(size: m.small, onChange: { input.touch.afterburner = $0 }) {
                        NovaControlCap(system: "flame.fill", size: m.small, accent: true)
                    }
                }
                labeled("Fire 2nd") {
                    HoldButton(size: m.small, onChange: { input.touch.fireSecondary = $0 }) {
                        NovaControlCap(system: "burst.fill", size: m.small, accent: true)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: m.gap) {
                labeled("Fire") {
                    HoldButton(size: m.big, onChange: { input.touch.firePrimary = $0 }) {
                        NovaControlCap(system: "bolt.fill", size: m.big, accent: true)
                    }
                }
                labeled("Thrust") {
                    HoldButton(size: m.big, onChange: { input.touch.thrust = $0 }) {
                        NovaControlCap(system: "chevron.up.2", size: m.big)
                    }
                }
            }
        }
    }

    /// Stack a short caption under a control so each button's job is legible at a
    /// glance. Captions carry a dark shadow so they stay readable over the
    /// starfield, and are `.allowsHitTesting(false)` so they never absorb a press
    /// meant for the cap above them.
    @ViewBuilder
    private func labeled<Content: View>(_ text: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2 * m.s) {
            content()
            Text(text)
                .font(.system(size: 9.5 * m.s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.85), radius: 1.5, y: 0.5)
                .lineLimit(1)
                .fixedSize()
                .allowsHitTesting(false)
        }
    }

    /// Current secondary weapon: tap the chip to cycle forward, tap the small
    /// leading chevron to go back — the forward direction keeps the large,
    /// easy-to-hit tap target it always had; reverse is a smaller, secondary
    /// affordance next to it rather than splitting the chip itself in half.
    /// The chevron stays visible (disabled, not hidden) with zero/one
    /// secondaries fitted, since the loadout can change mid-flight (buy an
    /// outfit, get boarded) and a control that pops in and out is worse than
    /// one that's just briefly unusable.
    private var weaponChip: some View {
        HStack(spacing: 3) {
            Button { onDiscrete(.selectSecondaryPrev) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10 * m.s, weight: .bold))
                    .foregroundStyle(hud.hasSecondary ? novaAmber : Color(white: 0.4))
                    .frame(width: 18 * m.s, height: 20 * m.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hud.hasSecondary)

            Button { onDiscrete(.selectSecondaryNext) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11 * m.s, weight: .bold))
                    Text(hud.weaponName.isEmpty ? "No 2nd weapon" : hud.weaponName)
                        .font(.system(size: 11 * m.s, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(novaAmber)
                .padding(.horizontal, 10 * m.s).padding(.vertical, 5 * m.s)
                .frame(maxWidth: 140 * m.s)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 2 * m.s)
        .novaControlPanel(corner: 7 * m.s)
    }

    // MARK: Actions menu (top-right)

    private var actionsToggle: some View {
        labeled(menuOpen ? "Close" : "Actions") {
            TapButton(size: m.toggle,
                      onTap: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { menuOpen.toggle() } }) {
                NovaControlCap(system: menuOpen ? "xmark" : "square.grid.2x2.fill",
                               size: m.toggle, accent: !menuOpen, glyphScale: 0.42)
            }
        }
    }

    /// The action tiles, in reading order. Kept as data so the grid can lay all
    /// of them out at a definite height (row count derives from `.count`).
    /// Target/Next and Menu are deliberately *not* repeated here — they're
    /// already always-on controls (`driveCluster`, `topLeftMenuButton`), and
    /// duplicating them just made the grid taller for no reason.
    private var actionItems: [(icon: String, label: String, run: () -> Void, enabled: Bool)] {
        [
            ("exclamationmark.triangle.fill", "Hostile", { onDiscrete(.nearestHostile) }, true),
            ("xmark.circle", "Untarget", { onDiscrete(.clearTarget) }, true),
            ("antenna.radiowaves.left.and.right", "Hail", { onDiscrete(.hailTarget) }, true),
            ("person.3.fill", "Escorts", { onDiscrete(.openEscorts) }, true),
            ("shippingbox.fill", "Board", { onDiscrete(.board) }, true),
            (hud.cloakEngaged ? "eye.slash.fill" : "eye.slash", hud.cloakEngaged ? "Uncloak" : "Cloak",
             { onDiscrete(.toggleCloak) }, hud.hasCloak),
            // Fighters launch via the normal secondary-weapon fire control (select
            // the bay like any other secondary, then fire) — recall is the one
            // dedicated fighter-bay touch command left.
            ("airplane.arrival", "Recall", { onDiscrete(.recallFighters) }, hud.hasFighterBays),
            ("map.fill", "Map", { onDiscrete(.galaxyMap) }, true),
            ("bolt.horizontal.circle.fill", "Jump", { onDiscrete(.hyperjump) }, true),
            ("arrow.down.to.line", "Land", { onDiscrete(.land) }, hud.landReady),
            ("list.bullet.clipboard", "Missions", { onOpenPanel(.missions) }, true),
            ("person.crop.circle", "Pilot", { onOpenPanel(.pilotInfo) }, true),
        ]
    }

    private var actionGrid: some View {
        let columns = 4
        let cols = Array(repeating: GridItem(.fixed(m.tile), spacing: 9 * m.s), count: columns)
        // Lay the grid out at its full content height so every row is visible at
        // once (no more one-row scrolling). Row height matches the tile frame.
        let rows = (actionItems.count + columns - 1) / columns
        let rowH = m.tile * 0.92
        let contentH = CGFloat(rows) * rowH + CGFloat(rows - 1) * 9 * m.s
        // Cap so it can never run off the bottom of a short (landscape) screen;
        // it scrolls only if it genuinely wouldn't fit.
        let maxH = max(rowH, viewportSize.height - m.toggle - m.edge * 2 - 40 * m.s)
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 9 * m.s) {
                ForEach(actionItems.indices, id: \.self) { i in
                    let item = actionItems[i]
                    tile(item.icon, item.label, item.run, enabled: item.enabled)
                }
            }
        }
        .frame(width: m.tile * CGFloat(columns) + 9 * m.s * CGFloat(columns - 1),
               height: min(contentH, maxH))
        .padding(11 * m.s)
        .novaControlPanel(corner: 14 * m.s)
    }

    private func tile(_ system: String, _ label: String, _ action: @escaping () -> Void,
                      enabled: Bool = true) -> some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.15)) { menuOpen = false }
        } label: {
            VStack(spacing: 5 * m.s) {
                Image(systemName: system).font(.system(size: 19 * m.s, weight: .semibold))
                Text(label).font(.system(size: 10 * m.s, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(enabled ? novaAmber : Color(white: 0.4))
            .frame(width: m.tile, height: m.tile * 0.92)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10 * m.s))
            .overlay(RoundedRectangle(cornerRadius: 10 * m.s)
                .strokeBorder(novaAmber.opacity(enabled ? 0.22 : 0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A round EV Nova control cap: a dark translucent disc with a thin amber (or
/// white) bevel and a centred glyph.
private struct NovaControlCap: View {
    let system: String
    let size: CGFloat
    var accent: Bool = false
    var glyphScale: CGFloat = 0.4

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * glyphScale, weight: .bold))
            .foregroundStyle(accent ? novaAmber : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [(accent ? novaAmber : .white).opacity(0.6),
                                            (accent ? novaAmber : .white).opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.3)
            )
    }
}

private extension View {
    /// The EV Nova floating-panel look — dark translucent fill, thin amber edge.
    func novaControlPanel(corner: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: corner).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(novaAmber.opacity(0.3)))
    }
}

/// A press-and-hold button reporting down/up as a boolean, for the flight
/// controls. Uses a padded rectangular hit area (bigger than the visual cap) so
/// edge presses register and two thumbs can hold two buttons at once.
///
/// On iOS the press is captured by a real UIKit view (`PressCatcher`) laid over
/// the cap rather than a SwiftUI gesture: the controls sit on top of the
/// SpriteKit `SpriteView`, and a SwiftUI `DragGesture` there competes with the
/// SKView's own touch handling — the reason presses felt dropped. A UIView wins
/// UIKit hit-testing above the SKView, so the hold lands on the first touch and
/// the scene never also mistakes the press for a fly-to / target tap.
struct HoldButton<Label: View>: View {
    var size: CGFloat = 60
    let onChange: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.6 : 1)
            .overlay(pressed ? Circle().fill(novaAmber.opacity(0.18)).frame(width: size, height: size) : nil)
            .scaleEffect(pressed ? 0.93 : 1)
            .padding(size * 0.12)                 // margin around the visual cap (bigger hit area)
            .contentShape(Rectangle())            // the whole padded box is tappable
            .modifier(PressHandling(pressed: $pressed) { down in
                if pressed != down { pressed = down; onChange(down) }
            })
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// A momentary tap button (targeting, actions toggle) that goes through the same
/// reliable UIKit hit path as `HoldButton`, so single taps over the SpriteKit
/// view register on the first press instead of occasionally being swallowed.
struct TapButton<Label: View>: View {
    var size: CGFloat = 52
    let onTap: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.6 : 1)
            .scaleEffect(pressed ? 0.93 : 1)
            .padding(size * 0.12)
            .contentShape(Rectangle())
            .modifier(PressHandling(pressed: $pressed, onTap: onTap) { _ in })
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Wires a control's visual to the platform touch handling: a UIKit `PressCatcher`
/// on iOS (reliable over the SpriteKit view), a plain SwiftUI gesture on macOS
/// (where the overlay never actually appears, but the type must still compile).
private struct PressHandling: ViewModifier {
    @Binding var pressed: Bool
    var onTap: (() -> Void)? = nil
    let onPressChange: (Bool) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.overlay(PressCatcher(onPressChange: onPressChange, onTap: onTap))
        #elseif os(tvOS)
        // No touch/drag on tvOS and the overlay never shows there (controller
        // or remote drive flight) — the type just needs to compile.
        content
        #else
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onPressChange(true) } }
                    .onEnded { _ in if pressed { pressed = false; onPressChange(false); onTap?() } }
            )
        #endif
    }
}

#if os(iOS)
/// A transparent UIKit touch target overlaid on a control's visual cap.
///
/// SwiftUI gestures layered directly over the SpriteKit `SpriteView` are
/// unreliable — the underlying `SKView` competes for the very same touch, which
/// is why the on-screen controls felt like they "didn't register." A real UIView
/// wins UIKit hit-testing above the SKView, so the press lands on the first tap
/// and the scene never also treats it as a fly-to / target tap. `isMultipleTouch`
/// + non-exclusive so two thumbs (turn + thrust) register at the same instant.
struct PressCatcher: UIViewRepresentable {
    var onPressChange: (Bool) -> Void = { _ in }
    var onTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isMultipleTouchEnabled = true
        v.isExclusiveTouch = false
        v.backgroundColor = .clear
        v.onPressChange = onPressChange
        v.onTap = onTap
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) {
        v.onPressChange = onPressChange
        v.onTap = onTap
    }

    final class CatcherView: UIView {
        var onPressChange: (Bool) -> Void = { _ in }
        var onTap: (() -> Void)?
        private var active = Set<UITouch>()
        private var slidOff = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let wasIdle = active.isEmpty
            active.formUnion(touches)
            if wasIdle { slidOff = false; onPressChange(true) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            // A finger that wanders well off the cap cancels a *tap*, but a held
            // control keeps firing while the thumb stays anywhere on/near it.
            guard onTap != nil, let t = touches.first else { return }
            if !bounds.insetBy(dx: -28, dy: -28).contains(t.location(in: self)) { slidOff = true }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let endedInside = touches.contains { bounds.insetBy(dx: -20, dy: -20).contains($0.location(in: self)) }
            active.subtract(touches)
            if active.isEmpty {
                onPressChange(false)
                if let onTap, endedInside, !slidOff { onTap() }
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.subtract(touches)
            if active.isEmpty { onPressChange(false) }
        }
    }
}
#endif
