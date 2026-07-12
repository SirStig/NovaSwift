import SwiftUI
import NovaSwiftEngine

/// Container-owned panels the mobile controls can open (these live in
/// `GameContainerView`, not reachable through `handleDiscrete`).
enum MobilePanel { case missions, pilotInfo, escorts }

/// The on-screen "virtual cockpit" for touch play. Deliberately sparse: only the
/// controls you hold constantly are always visible — **turn on the left, thrust
/// on the right**, so one thumb steers while the other drives — with fire and a
/// couple of combat holds tucked beside thrust. Everything occasional (targeting,
/// map, jump, land, hail, board, missions, escorts, pilot, menu) lives behind a
/// single expandable Actions button, so the screen stays uncluttered.
///
/// The whole thing is one `VStack` with transparent `Spacer`s, not a stack of
/// full-screen layers — so only the buttons themselves capture touches and the
/// open middle stays free for tap/drag-to-fly steering and target taps. Every
/// hold control has a generous rectangular hit area and recognises
/// simultaneously with its siblings, so two thumbs register at once and a press
/// near a button's edge still counts.
///
/// Sizes scale with the smaller screen edge (`Metrics`): compact-but-tappable on
/// a small iPhone, larger on an iPad, ≥60pt on the load-bearing controls. Styling
/// is the EV Nova HUD idiom — dark caps with a thin amber bevel, amber glyphs on
/// the action controls, white on the neutral ones.
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
    /// up to 1.4× on an iPad, so controls read the same relative size everywhere.
    private struct Metrics {
        let s: CGFloat
        init(_ size: CGSize) {
            let minEdge = min(size.width == 0 ? 430 : size.width, size.height == 0 ? 430 : size.height)
            s = min(max(minEdge / 430, 1), 1.4)
        }
        var big: CGFloat { 72 * s }     // turn / thrust / fire
        var small: CGFloat { 50 * s }   // afterburner / secondary
        var toggle: CGFloat { 52 * s }  // actions open/close
        var tile: CGFloat { 66 * s }    // action-grid tile
        var gap: CGFloat { 15 * s }
        var edge: CGFloat { 18 * s }
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
        HStack(spacing: m.gap) {
            HoldButton(size: m.big, onChange: { input.touch.turnLeft = $0 }) {
                NovaControlCap(system: "arrowtriangle.left.fill", size: m.big)
            }
            HoldButton(size: m.big, onChange: { input.touch.turnRight = $0 }) {
                NovaControlCap(system: "arrowtriangle.right.fill", size: m.big)
            }
        }
    }

    // MARK: Drive + fire (bottom-right; thrust is the rightmost, outer button)

    private var driveCluster: some View {
        VStack(alignment: .trailing, spacing: m.gap) {
            weaponChip
            HStack(spacing: m.gap) {
                HoldButton(size: m.small, onChange: { input.touch.afterburner = $0 }) {
                    NovaControlCap(system: "flame.fill", size: m.small, accent: true)
                }
                HoldButton(size: m.small, onChange: { input.touch.fireSecondary = $0 }) {
                    NovaControlCap(system: "burst.fill", size: m.small, accent: true)
                }
            }
            HStack(spacing: m.gap) {
                HoldButton(size: m.big, onChange: { input.touch.firePrimary = $0 }) {
                    NovaControlCap(system: "bolt.fill", size: m.big, accent: true)
                }
                HoldButton(size: m.big, onChange: { input.touch.thrust = $0 }) {
                    NovaControlCap(system: "chevron.up.2", size: m.big)
                }
            }
        }
    }

    /// Current secondary weapon + tap-to-cycle, in the EV Nova dark/amber idiom.
    private var weaponChip: some View {
        Button { onDiscrete(.selectSecondaryNext) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11 * m.s, weight: .bold))
                Text(hud.weaponName.isEmpty ? "No 2nd weapon" : hud.weaponName)
                    .font(.system(size: 11 * m.s, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(novaAmber)
            .padding(.horizontal, 10 * m.s).padding(.vertical, 5 * m.s)
            .frame(maxWidth: 160 * m.s)
            .novaControlPanel(corner: 7 * m.s)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions menu (top-right)

    private var actionsToggle: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { menuOpen.toggle() } } label: {
            NovaControlCap(system: menuOpen ? "xmark" : "square.grid.2x2.fill",
                           size: m.toggle, accent: !menuOpen, glyphScale: 0.42)
        }
        .buttonStyle(.plain)
    }

    /// The action tiles, in reading order. Kept as data so the grid can lay all
    /// of them out at a definite height (row count derives from `.count`).
    private var actionItems: [(icon: String, label: String, run: () -> Void, enabled: Bool)] {
        [
            ("scope", "Target", { onDiscrete(.targetNearest) }, true),
            ("exclamationmark.triangle.fill", "Hostile", { onDiscrete(.nearestHostile) }, true),
            ("arrow.triangle.2.circlepath", "Next", { onDiscrete(.targetNext) }, true),
            ("xmark.circle", "Untarget", { onDiscrete(.clearTarget) }, true),
            ("antenna.radiowaves.left.and.right", "Hail", { onDiscrete(.hailTarget) }, true),
            ("shippingbox.fill", "Board", { onDiscrete(.board) }, true),
            ("map.fill", "Map", { onDiscrete(.galaxyMap) }, true),
            ("bolt.horizontal.circle.fill", "Jump", { onDiscrete(.hyperjump) }, true),
            ("arrow.down.to.line", "Land", { onDiscrete(.land) }, hud.landReady),
            ("list.bullet.clipboard", "Missions", { onOpenPanel(.missions) }, true),
            ("person.2.fill", "Escorts", { onOpenPanel(.escorts) }, true),
            ("person.crop.circle", "Pilot", { onOpenPanel(.pilotInfo) }, true),
            ("line.3.horizontal", "Menu", { onDiscrete(.openMenu) }, true),
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
/// controls. Uses a padded rectangular hit area (bigger than the visual cap) and
/// a `.simultaneousGesture` so edge presses register and two thumbs can hold two
/// buttons at once — the reliability the earlier circle-only hit shape lacked.
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
            .padding(size * 0.1)                  // margin around the visual cap (bigger hit area)
            .contentShape(Rectangle())            // the whole padded box is tappable
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onChange(true) } }
                    .onEnded { _ in if pressed { pressed = false; onChange(false) } }
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}
