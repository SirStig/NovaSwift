import SwiftUI
import NovaSwiftEngine

/// Container-owned panels the mobile controls can open (these live in
/// `GameContainerView`, not reachable through `handleDiscrete`).
enum MobilePanel { case missions, pilotInfo, escorts }

/// The on-screen "virtual cockpit" for touch play — a full EV Nova control set
/// arranged for two thumbs, plus an expandable action menu for everything that
/// doesn't warrant a permanent button.
///
/// Layout (transparent everywhere except the buttons, so the open middle/top of
/// the screen stays free for tap/drag-to-fly steering and target taps):
///  • bottom-left  — flight: turn ◄ ►, thrust, reverse, afterburner
///  • bottom-right — combat: fire primary/secondary + weapon switch
///  • right edge   — targeting rail: nearest / cycle / hostile / clear
///  • top-right    — an "Actions" button expanding to map, jump, land, hail,
///                   board, missions, escorts, pilot info, menu
///
/// All sizes scale with the smaller screen edge (`Metrics`), so the controls
/// stay compact-but-tappable on a small iPhone and grow to fill an iPad — never
/// bulky, always ≥44pt on the load-bearing controls. Styling is the EV Nova HUD
/// idiom: dark translucent caps with a thin amber bevel, amber glyphs on the
/// action controls and white on the neutral ones.
///
/// Continuous controls write the isolated `input.touch` intent (OR-merged with
/// the other sources); discrete controls go through the container's
/// `handleDiscrete`/panel openers. The right-hand clusters inset by `rightInset`
/// so they never sit under the status-bar HUD.
struct TouchControlsOverlay: View {
    let input: InputController
    @ObservedObject var hud: GameHUDModel
    var tapToFly: Bool = false
    var rightInset: CGFloat = 0
    var onDiscrete: (GameAction) -> Void = { _ in }
    var onOpenPanel: (MobilePanel) -> Void = { _ in }

    @State private var menuOpen = false

    /// Button/spacing sizes derived from the smaller screen edge: 1× on a small
    /// iPhone, scaling up to 1.4× on an iPad, so controls read the same relative
    /// size everywhere and never get bulky on a phone.
    private struct Metrics {
        let s: CGFloat
        init(_ size: CGSize) { s = min(max(min(size.width, size.height) / 430, 1), 1.4) }
        var bigHold: CGFloat { 60 * s }     // thrust / fire primary
        var midHold: CGFloat { 46 * s }     // afterburner / reverse / fire secondary
        var turn: CGFloat { 54 * s }        // arc turn buttons
        var rail: CGFloat { 44 * s }        // targeting rail
        var tile: CGFloat { 64 * s }        // action-grid tile
        var toggle: CGFloat { 46 * s }      // actions open/close
        var gap: CGFloat { 12 * s }
        var edge: CGFloat { 20 * s }
    }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(geo.size)
            ZStack {
                if menuOpen {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { menuOpen = false } }
                }

                flightCluster(m)
                    .padding(.leading, m.edge).padding(.bottom, m.edge + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                combatCluster(m)
                    .padding(.trailing, rightInset + m.edge).padding(.bottom, m.edge + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                targetingRail(m)
                    .padding(.trailing, rightInset + m.edge - 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                actionsCorner(m)
                    .padding(.trailing, rightInset + m.edge - 2).padding(.top, m.edge - 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    // MARK: Flight (bottom-left)

    private func flightCluster(_ m: Metrics) -> some View {
        HStack(alignment: .bottom, spacing: m.gap + 2) {
            if !tapToFly {
                HStack(spacing: m.gap) {
                    HoldButton(onChange: { input.touch.turnLeft = $0 }) {
                        NovaControlCap(system: "arrow.turn.up.left", size: m.turn)
                    }
                    HoldButton(onChange: { input.touch.turnRight = $0 }) {
                        NovaControlCap(system: "arrow.turn.up.right", size: m.turn)
                    }
                }
            }
            VStack(spacing: m.gap) {
                HStack(spacing: m.gap) {
                    HoldButton(onChange: { input.touch.afterburner = $0 }) {
                        NovaControlCap(system: "flame.fill", size: m.midHold, accent: true)
                    }
                    HoldButton(onChange: { input.touch.reverse = $0 }) {
                        NovaControlCap(system: "chevron.down", size: m.midHold)
                    }
                }
                HoldButton(onChange: { input.touch.thrust = $0 }) {
                    NovaControlCap(system: "chevron.up", size: m.bigHold)
                }
            }
        }
    }

    // MARK: Combat (bottom-right)

    private func combatCluster(_ m: Metrics) -> some View {
        HStack(alignment: .bottom, spacing: m.gap + 2) {
            VStack(spacing: m.gap) {
                weaponChip(m)
                HoldButton(onChange: { input.touch.fireSecondary = $0 }) {
                    NovaControlCap(system: "paperplane.fill", size: m.midHold, accent: true)
                }
            }
            HoldButton(onChange: { input.touch.firePrimary = $0 }) {
                NovaControlCap(system: "bolt.fill", size: m.bigHold, accent: true)
            }
        }
    }

    /// The current secondary weapon + a tap-to-cycle affordance, in the EV Nova
    /// dark-panel/amber idiom.
    private func weaponChip(_ m: Metrics) -> some View {
        Button { onDiscrete(.selectSecondaryNext) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11 * m.s, weight: .bold))
                Text(hud.weaponName.isEmpty ? "—" : hud.weaponName)
                    .font(.system(size: 11 * m.s, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(novaAmber)
            .padding(.horizontal, 10 * m.s).padding(.vertical, 5 * m.s)
            .frame(maxWidth: 150 * m.s)
            .novaControlPanel(corner: 7 * m.s)
        }
        .buttonStyle(.plain)
    }

    // MARK: Targeting rail (right edge, mid-height)

    private func targetingRail(_ m: Metrics) -> some View {
        VStack(spacing: m.gap - 2) {
            railButton("scope", "Nearest", m) { onDiscrete(.targetNearest) }
            railButton("exclamationmark.triangle.fill", "Hostile", m, accent: true) { onDiscrete(.nearestHostile) }
            railButton("arrow.triangle.2.circlepath.circle", "Cycle", m) { onDiscrete(.targetNext) }
            railButton("xmark.circle", "Clear", m) { onDiscrete(.clearTarget) }
        }
    }

    private func railButton(_ system: String, _ label: String, _ m: Metrics,
                            accent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NovaControlCap(system: system, size: m.rail, accent: accent, glyphScale: 0.38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions menu (top-right, expandable)

    private func actionsCorner(_ m: Metrics) -> some View {
        VStack(alignment: .trailing, spacing: m.gap) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { menuOpen.toggle() } } label: {
                NovaControlCap(system: menuOpen ? "xmark" : "square.grid.2x2.fill",
                               size: m.toggle, accent: !menuOpen, glyphScale: 0.42)
            }
            .buttonStyle(.plain)

            if menuOpen {
                actionGrid(m)
                    .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private func actionGrid(_ m: Metrics) -> some View {
        let cols = Array(repeating: GridItem(.fixed(m.tile), spacing: 10 * m.s), count: 3)
        return LazyVGrid(columns: cols, spacing: 10 * m.s) {
            actionTile("map.fill", "Map", m) { onDiscrete(.galaxyMap) }
            actionTile("arrow.up.forward.circle.fill", "Jump", m) { onDiscrete(.hyperjump) }
            actionTile("arrow.down.to.line", "Land", m, enabled: hud.landPrompt != nil) { onDiscrete(.land) }
            actionTile("antenna.radiowaves.left.and.right", "Hail", m) { onDiscrete(.hailTarget) }
            actionTile("shippingbox.fill", "Board", m) { onDiscrete(.board) }
            actionTile("list.bullet.clipboard", "Missions", m) { onOpenPanel(.missions) }
            actionTile("person.2.fill", "Escorts", m) { onOpenPanel(.escorts) }
            actionTile("person.crop.circle", "Pilot", m) { onOpenPanel(.pilotInfo) }
            actionTile("line.3.horizontal", "Menu", m) { onDiscrete(.openMenu) }
        }
        .padding(11 * m.s)
        .novaControlPanel(corner: 14 * m.s)
    }

    private func actionTile(_ system: String, _ label: String, _ m: Metrics,
                            enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.15)) { menuOpen = false }
        } label: {
            VStack(spacing: 5 * m.s) {
                Image(systemName: system).font(.system(size: 19 * m.s, weight: .semibold))
                Text(label).font(.system(size: 10 * m.s, weight: .medium))
            }
            .foregroundStyle(enabled ? novaAmber : Color(white: 0.4))
            .frame(width: m.tile, height: m.tile * 0.9)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10 * m.s))
            .overlay(RoundedRectangle(cornerRadius: 10 * m.s)
                .strokeBorder(novaAmber.opacity(enabled ? 0.22 : 0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A round EV Nova control cap: a dark translucent disc with a thin amber (or
/// white) bevel and a centred glyph — the shared look for every flight/combat/
/// targeting button.
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
            .contentShape(Circle())
    }
}

private extension View {
    /// The EV Nova floating-panel look — dark translucent fill, thin amber edge.
    func novaControlPanel(corner: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: corner).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(novaAmber.opacity(0.3)))
    }
}

/// A button that reports press-down and press-up as a boolean, for hold controls.
struct HoldButton<Label: View>: View {
    let onChange: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.6 : 1)
            .overlay(pressed ? Circle().fill(novaAmber.opacity(0.18)) : nil)
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onChange(true) } }
                    .onEnded { _ in pressed = false; onChange(false) }
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}
