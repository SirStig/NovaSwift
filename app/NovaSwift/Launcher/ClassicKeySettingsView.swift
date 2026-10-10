import SwiftUI
import NovaSwiftKit
#if os(macOS)
import AppKit
#endif

/// The original's Key Settings window: `Menu_RunKeySettingsDialog` 0x0048b280,
/// DLOG/DITL 4002 (594x353). The labelled backdrop is PICT 139 (133 on the
/// Mac build) in item 3; the 34 key cells are items 4...37 (81x22), read in
/// the three columns the art labels them in. A click selects a cell, the next
/// key pressed binds it and the selection steps on (0x0048b6d0); OK is refused
/// while two cells share a key, Cancel discards, Set Default only previews the
/// defaults (0x0048b280). Cells for commands NovaSwift has no action for stay
/// blank; the port's other keys are under "More keys...".
struct ClassicKeySettingsView: View {
    @EnvironmentObject private var model: AppModel
    var onClose: () -> Void
    var onMoreKeys: () -> Void

    @State private var draft: KeyBindings?
    @State private var selected = 0
    @State private var conflict: Int?

    /// Cell order of the art: Navigation, Battle, Escort, Miscellaneous.
    static let cells: [GameAction?] = [
        // Navigation Controls
        .accelerate, .decelerate, .turnRight, .turnLeft, .afterburner, .autopilot,
        .hyperspaceArm, .cycleHyperspaceLink, .hyperjump, .clearTarget, .hailTarget, .land,
        // Battle Controls
        .firePrimary, .fireSecondary, .selectSecondaryNext, .clearSecondary, .targetNext, .nearestHostile,
        // Escort Controls
        .openEscorts, .commandEscortAggressive, .commandEscortDefensive, .commandEscortHold,
        .commandEscortFormation,
        // Miscellaneous Controls
        .pauseGame, .dismissMessage, .board, nil, .eject, .selfDestruct, .toggleCloak,
        .galaxyMap, .playerInfo, .missionInfo, nil,
    ]

    private var keys: KeyBindings { draft ?? model.bindings }

    private func label(_ cell: Int) -> String {
        guard let a = Self.cells[cell] else { return "" }
        let t = keys.token(for: a)
        return t.isEmpty ? "" : KeyToken.label(t)
    }

    private func capture(_ token: String) {
        guard let a = Self.cells[selected] else { selected = (selected + 1) % Self.cells.count; return }
        guard KeyBindings.isCapturable(token) else { return }
        var e = keys
        e.assign(a, to: token)
        draft = e
        conflict = nil
        selected = (selected + 1) % Self.cells.count
    }

    private func ok() {
        let order = Self.cells.compactMap { $0 }
        if let clash = keys.firstConflict(in: order) {
            conflict = Self.cells.firstIndex { $0 == clash }
            selected = conflict ?? selected
            return
        }
        if let draft { model.bindings = draft; model.commitBindings() }
        onClose()
    }

    var body: some View {
        let game = model.data.game
        let bg = game.flatMap { g in model.uiGraphics.flatMap { $0.pict(g.resources.resource(NovaType.pict, 139) != nil ? 139 : 133) } }
        var custom: [Int: AnyView] = [:]
        if let bg {
            custom[3] = AnyView(Image(decorative: bg, scale: 1).interpolation(.none)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
        for c in 0..<Self.cells.count {
            custom[4 + c] = AnyView(
                Text(label(c))
                    .font(ClassicUiWindow.font)
                    .foregroundStyle(selected == c ? Color.white : Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected == c ? Color.black : Color.clear)
                    .overlay(Rectangle().stroke(conflict == c ? Color.red : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = c; conflict = nil })
        }
        return ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ClassicDITLDialog(
                game: game, graphics: model.uiGraphics, id: 4002,
                fallbackSize: CGSize(width: 594, height: 353),
                actions: [0: ok,
                          1: { draft = nil; onClose() },
                          2: {
                              var p = keys
                              p.resetToDefaults(modern: model.settings.enhancements.modernKeyBindings)
                              draft = p; conflict = nil
                          }],
                custom: custom,
                defaultItem: 0, cancelItem: 1)
            VStack {
                Spacer()
                Button("More keys…", action: onMoreKeys)
                    .buttonStyle(.plain)
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 12)
            }
        }
        .focusable()
        .onKeyPress(phases: .down) { press in
            let token = KeyToken.from(press)
            if token == "escape" { return .ignored }
            if token.isEmpty { return .ignored }
            capture(token)
            return .handled
        }
        #if os(macOS)
        .background { ModifierFlagsBridge(onChange: { flags in
            if let t = bareModifierToken(flags) { capture(t) }
        }) }
        #endif
        .onAppear { if draft == nil { draft = model.bindings } }
    }
}
