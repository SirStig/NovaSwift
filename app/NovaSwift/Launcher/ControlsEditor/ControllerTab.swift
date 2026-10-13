import SwiftUI
import GameController

/// The Controller tab: a drawn pad (style picker, live press highlight,
/// callouts) next to the shared action list.
struct ControllerTab: View {
    @Binding var prefs: ControlsEditorPrefs
    let bindings: PadBindings
    let pad: GCExtendedGamepad?
    /// The action armed for capture (pad press or a click on the art binds it).
    let capturing: GameAction?
    @Binding var selectedButton: PadButton?
    @Binding var hoveredAction: GameAction?
    /// Buttons physically held right now (lights the art even when not capturing).
    let pressed: Set<PadButton>
    let onButtonTap: (PadButton) -> Void
    let onActionTap: (GameAction) -> Void
    let onUnbind: (GameAction) -> Void

    private var detected: PadStyle? { pad == nil ? nil : PadStyle.detect(GCController.active) }
    private var style: PadStyle { prefs.padStyle ?? detected ?? .xbox }

    /// Flown with the left stick; never rebindable (thrust/reverse may also take a button).
    static let stickActions: Set<GameAction> = [.turnLeft, .turnRight, .accelerate, .decelerate]

    var body: some View {
        EditorSplit {
            VStack(spacing: 8) {
                NovaSegmentedPicker(selection: Binding(get: { style }, set: { prefs.padStyle = $0 }),
                                    options: PadStyle.allCases) { $0.title }
                ControllerCanvas(style: style, bindings: bindings,
                                 livePad: detected == style ? pad : nil, pressed: pressed,
                                 selectedButton: selectedButton, selectedAction: capturing,
                                 hoveredAction: hoveredAction,
                                 onHover: { hoveredAction = $0.flatMap { bindings.action(for: $0) } },
                                 onTap: onButtonTap)
                if style == .steamDeck {
                    Text("Back grips and trackpads are set in Steam Input; Steam Deck presents the pad to games as a standard controller.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CategoryLegend()
            }
        } side: {
            ActionListPanel(bindingText: { a in
                guard let b = bindings.button(for: a) else { return nil }
                return detected == style ? b.displayName(on: pad) : style.name(b)
            }, symbol: { a in bindings.button(for: a)?.symbolName(on: pad) },
               fixedText: { a in Self.stickActions.contains(a) ? "Left stick" : nil },
               selected: capturing, hovered: $hoveredAction, conflicts: [],
               prompt: pad == nil ? "Click a control" : "Press a button…",
               onTap: onActionTap, onUnbind: onUnbind) {
                inspector
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capturing {
                Text(pad == nil
                     ? "Binding “\(capturing.title)” — click a control on the pad (no controller connected)."
                     : "Binding “\(capturing.title)” — press a button on the controller, or click a control. Cancels itself after a few seconds.")
                    .novaFont(.caption).foregroundStyle(novaAmber)
            } else if let button = selectedButton {
                let action = bindings.action(for: button)
                Text("\(style.name(button)) \(action == nil ? "is unbound — pick an action to assign it." : "does this now. Pick an action to replace it.")")
                    .novaFont(.caption).foregroundStyle(novaAmber)
                if let action {
                    HStack {
                        Text(action.title).novaFont(.body)
                        Spacer()
                        CursorButton { onUnbind(action) } label: { EditorChip(text: "Unbind") }
                    }
                }
            } else {
                Text(pad == nil
                     ? "No controller connected — you can still click a control to bind it. Bindings apply as soon as a pad is paired."
                     : "Pick an action, then press a button — or click a control to see and change what it does. Left stick steers and thrusts, right stick aims; the sticks can't be rebound, only their clicks.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
