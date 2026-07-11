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

    private let amber = Color(red: 1, green: 0.7, blue: 0.25)

    var body: some View {
        ZStack {
            if menuOpen {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { menuOpen = false }
            }

            flightCluster
                .padding(.leading, 22).padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            combatCluster
                .padding(.trailing, rightInset + 22).padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            targetingRail
                .padding(.trailing, rightInset + 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            actionsCorner
                .padding(.trailing, rightInset + 20).padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    // MARK: Flight (bottom-left)

    private var flightCluster: some View {
        HStack(alignment: .bottom, spacing: 14) {
            // Steering: arc buttons in Virtual-Cockpit mode; hidden when steering
            // is by touching the space view (Tap to Turn).
            if !tapToFly {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        HoldButton(onChange: { input.touch.turnLeft = $0 }) {
                            ControlGlyph(system: "arrow.turn.up.left")
                        }
                        HoldButton(onChange: { input.touch.turnRight = $0 }) {
                            ControlGlyph(system: "arrow.turn.up.right")
                        }
                    }
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    HoldButton(onChange: { input.touch.afterburner = $0 }) {
                        ControlGlyph(system: "flame.fill", tint: Color(red: 1, green: 0.55, blue: 0.2), size: 54)
                    }
                    HoldButton(onChange: { input.touch.reverse = $0 }) {
                        ControlGlyph(system: "chevron.down", size: 54)
                    }
                }
                HoldButton(onChange: { input.touch.thrust = $0 }) {
                    ControlGlyph(system: "chevron.up", tint: .white, size: 84)
                }
            }
        }
    }

    // MARK: Combat (bottom-right)

    private var combatCluster: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 12) {
                // Weapon readout + switch: shows the current weapon, tap to cycle.
                Button {
                    onDiscrete(.selectSecondaryNext)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                        Text(hud.weaponName.isEmpty ? "—" : hud.weaponName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: 150)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)

                HoldButton(onChange: { input.touch.fireSecondary = $0 }) {
                    ControlGlyph(system: "paperplane.fill", tint: Color(red: 0.6, green: 0.85, blue: 1), size: 54)
                }
            }
            HoldButton(onChange: { input.touch.firePrimary = $0 }) {
                ControlGlyph(system: "bolt.fill", tint: amber, size: 84)
            }
        }
    }

    // MARK: Targeting rail (right edge, mid-height)

    private var targetingRail: some View {
        VStack(spacing: 10) {
            railButton("scope", "Nearest") { onDiscrete(.targetNearest) }
            railButton("exclamationmark.triangle.fill", "Hostile",
                       tint: Color(red: 1, green: 0.42, blue: 0.35)) { onDiscrete(.nearestHostile) }
            railButton("arrow.triangle.2.circlepath.circle", "Cycle") { onDiscrete(.targetNext) }
            railButton("xmark.circle", "Clear") { onDiscrete(.clearTarget) }
        }
    }

    private func railButton(_ system: String, _ label: String,
                            tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions menu (top-right, expandable)

    private var actionsCorner: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { menuOpen.toggle() } } label: {
                Image(systemName: menuOpen ? "xmark" : "square.grid.2x2.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(menuOpen ? .white : amber)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)

            if menuOpen {
                actionGrid
                    .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var actionGrid: some View {
        let cols = [GridItem(.fixed(72), spacing: 10), GridItem(.fixed(72), spacing: 10),
                    GridItem(.fixed(72), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            actionTile("map.fill", "Map") { onDiscrete(.galaxyMap) }
            actionTile("arrow.up.forward.circle.fill", "Jump") { onDiscrete(.hyperjump) }
            actionTile("arrow.down.to.line", "Land", enabled: hud.landPrompt != nil) { onDiscrete(.land) }
            actionTile("antenna.radiowaves.left.and.right", "Hail") { onDiscrete(.hailTarget) }
            actionTile("shippingbox.fill", "Board") { onDiscrete(.board) }
            actionTile("list.bullet.clipboard", "Missions") { onOpenPanel(.missions) }
            actionTile("person.2.fill", "Escorts") { onOpenPanel(.escorts) }
            actionTile("person.crop.circle", "Pilot") { onOpenPanel(.pilotInfo) }
            actionTile("line.3.horizontal", "Menu") { onDiscrete(.openMenu) }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14)))
    }

    private func actionTile(_ system: String, _ label: String, enabled: Bool = true,
                            _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.15)) { menuOpen = false }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 20, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(enabled ? .white : Color(white: 0.4))
            .frame(width: 72, height: 60)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A circular control button glyph.
private struct ControlGlyph: View {
    let system: String
    var tint: Color = .white
    var size: CGFloat = 72
    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

/// A button that reports press-down and press-up as a boolean, for hold controls.
struct HoldButton<Label: View>: View {
    let onChange: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.55 : 1)
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
