import SwiftUI

/// The context-sensitive action strip at the bottom-centre of the play
/// viewport — the mobile "assistive controls" layer, grown out of the old
/// single-purpose Land pill.
///
/// On macOS (and tvOS) this is still just the classic EV Nova on-screen text
/// hint ("Press L to land on …") — desktop players have the whole keyboard, so
/// a description of the control is all that's wanted. On iOS it becomes a row
/// of **tappable pills** surfacing whichever occasional actions make sense in
/// the current situation, so they don't have to be dug out of the Actions grid
/// mid-flight:
///
///   · **Land** (amber, primary) when cleared to set down — the original pill.
///   · **Board** when the locked target is a disabled hulk.
///   · **Hail** when a ship target — or, failing that, a planet — is selected.
///   · **Jump** when a course is plotted and the ship is clear of the no-jump zone.
///   · **Escorts** while hostiles are actively attacking and there's a wing to
///     command — expands inline into the four Fleet Control standing orders.
///
/// Priority is Land > Board > Hail > Jump > Escorts, at most three pills at
/// once, so the row never crowds the open middle of the touch layout. The row
/// carries **discrete tap actions only** — hold/reflex controls (fire, thrust,
/// turn) live in `TouchControlsOverlay` and never move or pop in and out.
///
/// Reshaping is debounced (`task(id:)` below), asymmetrically: a new pill
/// shows after ~0.1 s, a departing one lingers ~0.45 s, so cycling targets —
/// or a ship's speed hovering right at the landing limit — can't make the row
/// strobe under the player's thumb. Labels step down (full → short → glyph)
/// to fit the gap between the bottom-corner touch clusters, and taps go
/// through the UIKit `PressCatcher` path so they aren't lost to the SKView.
struct ContextualActionsView: View {
    @ObservedObject var hud: GameHUDModel
    /// Restrict the strip to the land pill/hint alone. The tutorial sandbox
    /// keeps hail/board/jump deliberately inert, and a pill that does nothing
    /// when tapped is worse than no pill.
    var landOnly = false
    var onAction: (GameAction) -> Void = { _ in }
    /// Width of the HUD sidebar this screen is reserving on the right (see
    /// `GameContainerView.sidebarWidth`), so the strip centres on the actual
    /// play viewport instead of the full window.
    var rightInset: CGFloat = 0
    /// Room the bottom-corner touch clusters take from each side of the play
    /// viewport at the pills' height (`TouchLayout.bottomBandInsets`) — the
    /// strip centres in, and fits itself to, the gap between them.
    var clusterInsets: (leading: CGFloat, trailing: CGFloat) = (0, 0)
    /// The bottom safe-area inset. The mobile message line lives in the
    /// lowest band of the screen (`MessageLogView.mobileBand`); on a device
    /// with no home-indicator inset the strip lifts itself clear of it.
    var bottomSafeInset: CGFloat = 0

    /// One situational pill the strip can offer. The associated names are
    /// display-only — each tap dispatches a plain `GameAction` that acts on
    /// live game state, so a label lagging a target swap by the debounce
    /// interval can never make the action hit the wrong ship.
    private enum ContextualAction: Equatable, Identifiable {
        case land(String)     // cleared to set down on the named stellar
        case board(String)    // locked target is a disabled hulk
        case hail(String)     // a ship (or selected planet) to contact
        case jump(String)     // course plotted and clear to engage
        case escorts          // under attack with a wing to command

        var id: String {
            switch self {
            case .land: return "land"
            case .board: return "board"
            case .hail: return "hail"
            case .jump: return "jump"
            case .escorts: return "escorts"
            }
        }
    }

    /// What's actually on screen — trails `desired` by the debounce interval.
    @State private var shown: [ContextualAction] = []
    /// Whether the Escorts pill has expanded into the four standing orders.
    @State private var escortOrdersOpen = false

    /// The pills the current game state calls for, in priority order, capped
    /// at three so the strip stays a glance, not a menu.
    private var desired: [ContextualAction] {
        var pills: [ContextualAction] = []
        if hud.landReady, !hud.landName.isEmpty { pills.append(.land(hud.landName)) }
        guard !landOnly else { return pills }
        if !hud.targetName.isEmpty, hud.targetDisabled { pills.append(.board(hud.targetName)) }
        if !hud.targetName.isEmpty {
            pills.append(.hail(hud.targetName))
        } else if !hud.navTargetName.isEmpty {
            pills.append(.hail(hud.navTargetName))
        }
        if !hud.navCourseSystemName.isEmpty, hud.canJumpNow { pills.append(.jump(hud.navCourseSystemName)) }
        if hud.underAttack, hud.hasEscorts { pills.append(.escorts) }
        return Array(pills.prefix(3))
    }

    /// On iOS the safe area already clears the home indicator, and the touch
    /// controls anchor only a few points beyond it. On macOS there's no safe
    /// area to lean on, but it should still sit flush with the window's
    /// bottom edge rather than floating well above it.
    private var bottomPadding: CGFloat {
        #if os(iOS)
        max(6, MessageLogView.mobileBand + 4 - bottomSafeInset)
        #else
        8
        #endif
    }

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            #if os(iOS)
            // Symmetric so the strip stays centred on the viewport, using the
            // wider of the two clusters plus a thumb's gap.
            .padding(.horizontal, max(clusterInsets.leading, clusterInsets.trailing) + 8)
            #endif
            .padding(.trailing, rightInset)
            .padding(.bottom, bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .novaResponsive()
        .animation(.easeInOut(duration: 0.15), value: hud.landPrompt)
        #if os(iOS)
        .task(id: desired) {
            // Debounce: commit the new pill set only once the situation has
            // held still for a beat. `task(id:)` cancels the sleep whenever
            // `desired` changes again, so a flickering input (target cycling,
            // speed hovering at the landing limit) never reaches the screen.
            // Asymmetric: a pill that's newly called for shows almost at once
            // (waiting a third of a second for "Land" felt laggy), while one
            // that's going away lingers, so a pill never vanishes from under
            // a thumb that's already on its way to it.
            let target = desired
            guard target != shown else { return }
            let removes = shown.contains { !target.contains($0) }
            try? await Task.sleep(nanoseconds: removes ? 450_000_000 : 90_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                shown = target
                if !target.contains(.escorts) { escortOrdersOpen = false }
            }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        VStack(spacing: 7) {
            // The approach hint keeps its own live (undebounced) lane above the
            // pills — it's passive text, and "slow down" should track reality.
            if !hud.landName.isEmpty, !hud.landReady, !hud.landPrompt.isEmpty {
                hint(hud.landPrompt).allowsHitTesting(false)
            }
            if escortOrdersOpen {
                ViewThatFits(in: .horizontal) {
                    escortOrdersRow(.full)
                    escortOrdersRow(.iconOnly)
                }
            } else if !shown.isEmpty {
                // Full labels when they fit between the corner clusters, then
                // short labels, then glyphs only — three pills always fit on
                // the smallest phone instead of spilling under the controls.
                ViewThatFits(in: .horizontal) {
                    pillRow(.full)
                    pillRow(.short)
                    pillRow(.iconOnly)
                }
            }
        }
        #else
        // The original has one status line (0x0087550b) and no land hint; this
        // hint sits a line above it while a message is up so the two never
        // draw over each other.
        if !hud.landPrompt.isEmpty {
            hint(hud.landPrompt).allowsHitTesting(false)
                .padding(.bottom, hud.message == nil ? 0 : MessageLogView.lineHeight)
                .animation(.easeInOut(duration: 0.15), value: hud.message == nil)
        }
        #endif
    }

    // MARK: - Pills (iOS)

    /// How much text a pill carries — stepped down by `ViewThatFits` until
    /// the row fits the gap between the touch clusters.
    private enum PillStyle { case full, short, iconOnly }

    private func pillRow(_ style: PillStyle) -> some View {
        HStack(spacing: 8) {
            ForEach(shown) { pill(for: $0, style) }
        }
        .fixedSize()
    }

    @ViewBuilder private func pill(for action: ContextualAction, _ style: PillStyle) -> some View {
        switch action {
        case .land(let name):
            landPill(name, style)
        case .board:
            actionPill(icon: "shippingbox.fill", label: "Board", style) { onAction(.board) }
        case .hail:
            actionPill(icon: "antenna.radiowaves.left.and.right", label: "Hail", style) { onAction(.hailTarget) }
        case .jump(let system):
            actionPill(icon: "bolt.horizontal.circle.fill",
                       label: style == .full ? "Jump: \(system)" : "Jump", style) { onAction(.hyperjump) }
        case .escorts:
            actionPill(icon: "person.3.fill", label: "Escorts", style) {
                withAnimation(.easeOut(duration: 0.15)) { escortOrdersOpen = true }
            }
        }
    }

    /// The original amber Land pill — the one "do it now" primary in the row,
    /// filled rather than outlined so clearance to land is unmistakable.
    private func landPill(_ name: String, _ style: PillStyle) -> some View {
        ContextPillButton(action: { onAction(.land) }, accessibility: "Land on \(name)") {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                if style != .iconOnly {
                    Text(style == .full ? "Land on \(name)" : "Land").lineLimit(1)
                }
                // Pad players see which physical button lands, right on
                // the pill (renders nothing without a controller).
                PadGlyph(.land, size: 13, tint: .black)
            }
            .novaFont(.hud, weight: .semibold, size: 13)
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(minWidth: 44, minHeight: 36)
            .background(Capsule().fill(novaAmber))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .transition(.opacity)
    }

    /// A secondary contextual pill in the EV Nova HUD idiom — dark translucent
    /// capsule, thin amber edge, amber glyph — visually quieter than Land so
    /// the row reads as "one command, some options."
    private func actionPill(icon: String, label: String, _ style: PillStyle,
                            action: @escaping () -> Void) -> some View {
        ContextPillButton(action: action, accessibility: label) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                if style != .iconOnly { Text(label).lineLimit(1) }
            }
            .novaFont(.hud, weight: .semibold, size: 13)
            .foregroundStyle(novaAmber)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .frame(minWidth: 44, minHeight: 36)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().strokeBorder(novaAmber.opacity(0.4)))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .transition(.opacity)
    }

    /// The Escorts pill, expanded: EV Nova's four Fleet Control standing
    /// orders plus a close. Issuing an order collapses back to the pill row —
    /// standing orders aren't something you re-issue in quick succession.
    private func escortOrdersRow(_ style: PillStyle) -> some View {
        HStack(spacing: 8) {
            actionPill(icon: "flame.fill", label: "Aggressive", style) { issueEscortOrder(.commandEscortAggressive) }
            actionPill(icon: "shield.fill", label: "Defensive", style) { issueEscortOrder(.commandEscortDefensive) }
            actionPill(icon: "wind", label: "Evasive", style) { issueEscortOrder(.commandEscortEvasive) }
            actionPill(icon: "pause.fill", label: "Hold", style) { issueEscortOrder(.commandEscortHold) }
            ContextPillButton(action: {
                withAnimation(.easeOut(duration: 0.15)) { escortOrdersOpen = false }
            }, accessibility: "Close") {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
            }
            .transition(.opacity)
        }
        .fixedSize()
    }

    private func issueEscortOrder(_ order: GameAction) {
        onAction(order)
        withAnimation(.easeOut(duration: 0.15)) { escortOrdersOpen = false }
    }

    // MARK: - Passive hint (all platforms)

    private func hint(_ text: String) -> some View {
        Text(text)
            #if os(iOS)
            .novaFont(.hud, weight: .semibold, size: 12)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            #else
            .novaFont(.hud, weight: .semibold)
            #endif
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .transition(.opacity)
    }
}

/// A contextual pill's touch target. On iOS the press is caught by the same
/// UIKit `PressCatcher` the flight caps use: a SwiftUI `Button` floating over
/// the SpriteKit view competes with the SKView for the very same touch, which
/// is why taps on these pills were sometimes swallowed (or read as a fly-to
/// tap on the world behind). The hit box is padded past the visual capsule so
/// a thumb landing just off its edge still counts.
private struct ContextPillButton<Label: View>: View {
    let action: () -> Void
    var accessibility: String = ""
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        #if os(iOS)
        label()
            .opacity(pressed ? 0.7 : 1)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .padding(5)
            .contentShape(Rectangle())
            .overlay(PressCatcher(onPressChange: { pressed = $0 }, onTap: action))
            .padding(-5)
            .cursorClickable(action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
        #else
        Button(action: action, label: label).buttonStyle(.novaPlain)
        #endif
    }
}
