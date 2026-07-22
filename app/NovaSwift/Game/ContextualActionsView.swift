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
/// Reshaping is debounced (`task(id:)` below): the situation must hold still
/// for a beat before pills appear or leave, so cycling targets — or a ship's
/// speed hovering right at the landing limit — can't make the row strobe
/// under the player's thumb.
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
        6
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
            let target = desired
            guard target != shown else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
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
            if !hud.landName.isEmpty, !hud.landReady {
                hint("Slow down to land on \(hud.landName)").allowsHitTesting(false)
            }
            if escortOrdersOpen {
                escortOrdersRow
            } else if !shown.isEmpty {
                HStack(spacing: 8) {
                    ForEach(shown) { pill(for: $0) }
                }
            }
        }
        #else
        if !hud.landPrompt.isEmpty { hint(hud.landPrompt).allowsHitTesting(false) }
        #endif
    }

    // MARK: - Pills (iOS)

    @ViewBuilder private func pill(for action: ContextualAction) -> some View {
        switch action {
        case .land(let name):
            landPill(name)
        case .board(let name):
            actionPill(icon: "shippingbox.fill", label: "Board \(name)") { onAction(.board) }
        case .hail(let name):
            actionPill(icon: "antenna.radiowaves.left.and.right", label: "Hail \(name)") { onAction(.hailTarget) }
        case .jump(let system):
            actionPill(icon: "bolt.horizontal.circle.fill", label: "Jump: \(system)") { onAction(.hyperjump) }
        case .escorts:
            actionPill(icon: "person.3.fill", label: "Escorts") {
                withAnimation(.easeOut(duration: 0.15)) { escortOrdersOpen = true }
            }
        }
    }

    /// The original amber Land pill — the one "do it now" primary in the row,
    /// filled rather than outlined so clearance to land is unmistakable.
    private func landPill(_ name: String) -> some View {
        Button { onAction(.land) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                Text("Land on \(name)").lineLimit(1).frame(maxWidth: 150)
                // Pad players see which physical button lands, right on
                // the pill (renders nothing without a controller).
                PadGlyph(.land, size: 13, tint: .black)
            }
            .novaFont(.hud, weight: .semibold, size: 12)
            .foregroundStyle(.black)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(novaAmber))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.novaPlain)
        .transition(.opacity)
    }

    /// A secondary contextual pill in the EV Nova HUD idiom — dark translucent
    /// capsule, thin amber edge, amber glyph — visually quieter than Land so
    /// the row reads as "one command, some options."
    private func actionPill(icon: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).lineLimit(1).frame(maxWidth: 130)
            }
            .novaFont(.hud, weight: .semibold, size: 12)
            .foregroundStyle(novaAmber)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(novaAmber.opacity(0.35)))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.novaPlain)
        .transition(.opacity)
    }

    /// The Escorts pill, expanded: EV Nova's four Fleet Control standing
    /// orders plus a close. Issuing an order collapses back to the pill row —
    /// standing orders aren't something you re-issue in quick succession.
    private var escortOrdersRow: some View {
        HStack(spacing: 8) {
            actionPill(icon: "flame.fill", label: "Aggressive") { issueEscortOrder(.commandEscortAggressive) }
            actionPill(icon: "shield.fill", label: "Defensive") { issueEscortOrder(.commandEscortDefensive) }
            actionPill(icon: "wind", label: "Evasive") { issueEscortOrder(.commandEscortEvasive) }
            actionPill(icon: "pause.fill", label: "Hold") { issueEscortOrder(.commandEscortHold) }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { escortOrdersOpen = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
            }
            .buttonStyle(.novaPlain)
            .transition(.opacity)
        }
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
            #else
            .novaFont(.hud, weight: .semibold)
            #endif
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .transition(.opacity)
    }
}
