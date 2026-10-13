import SwiftUI

extension KeyboardLayouts {
    /// Display text for a stored token — `KeyToken.label` plus the AppKit
    /// function-key characters it would print as private-use boxes.
    static func label(_ token: String) -> String {
        if token.hasPrefix("opt+") { return "⌥" + label(String(token.dropFirst(4))) }
        let special = legend(for: token)
        if let scalar = token.unicodeScalars.first, token.unicodeScalars.count == 1,
           (0xF700...0xF7FF).contains(scalar.value) { return special }
        return KeyToken.label(token)
    }
}

/// Board + action list on a split canvas: wide windows put the list at the
/// right, narrow ones (iPhone, split view) stack it under the device.
struct EditorSplit<Device: View, Side: View>: View {
    @ViewBuilder var device: () -> Device
    @ViewBuilder var side: () -> Side

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 760 {
                HStack(alignment: .top, spacing: 14) {
                    device().frame(maxWidth: .infinity, maxHeight: .infinity)
                    side().frame(width: 330)
                }
            } else {
                VStack(spacing: 10) {
                    device().frame(height: max(180, geo.size.height * 0.46))
                    side().frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// The Keyboard tab: a drawn keyboard (size preset + ISO + modifier layer) next
/// to the shared action list.
struct KeyboardTab: View {
    let keys: KeyBindings
    @Binding var prefs: ControlsEditorPrefs
    @Binding var layer: KeyLayer
    /// The action armed for capture.
    let capturing: GameAction?
    @Binding var selectedKey: String?
    @Binding var hoveredAction: GameAction?
    let conflicts: Set<GameAction>
    let onKeyTap: (KeyCap) -> Void
    let onActionTap: (GameAction) -> Void
    let onUnbind: (GameAction) -> Void

    private var size: KeyboardSize { prefs.keyboardSize ?? .automatic }
    private var layout: KeyboardLayout { KeyboardLayouts.layout(size, iso: prefs.iso) }

    private var holders: [String: [GameAction]] {
        Dictionary(grouping: GameAction.allCases.filter { !keys.token(for: $0).isEmpty },
                   by: { keys.token(for: $0) })
    }

    var body: some View {
        let layout = layout
        let holders = holders
        EditorSplit {
            VStack(spacing: 8) {
                controlsBar
                KeyboardCanvas(layout: layout, layer: layer, holders: holders,
                               selectedKey: selectedKey, selectedAction: capturing,
                               hoveredAction: hoveredAction, conflicts: conflicts,
                               onHover: { hoveredAction = $0.flatMap { cap in
                                   cap.token(on: layer).flatMap { holders[$0]?.first } } },
                               onTap: onKeyTap)
                offKeyboardStrip(layout: layout)
                CategoryLegend()
            }
        } side: {
            ActionListPanel(bindingText: { a in
                let t = keys.token(for: a)
                return t.isEmpty ? nil : KeyboardLayouts.label(t)
            }, selected: capturing, hovered: $hoveredAction, conflicts: conflicts,
               prompt: "Press a key…", onTap: onActionTap, onUnbind: onUnbind) {
                inspector(layout: layout, holders: holders)
            }
        }
    }

    // MARK: Controls

    private var controlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                NovaMenuPicker(title: "Size", selection: Binding(get: { size }, set: { prefs.keyboardSize = $0 }),
                               options: KeyboardSize.allCases) { $0.title }
                CursorButton { prefs.iso.toggle() } label: {
                    EditorChip(text: "ISO", highlighted: prefs.iso)
                }
                .accessibilityLabel("ISO layout")
            }
            NovaSegmentedPicker(selection: $layer, options: KeyLayer.allCases) { $0.rawValue }
        }
    }

    /// The side panel's top: what to do now, or the selected key's bindings.
    @ViewBuilder
    private func inspector(layout: KeyboardLayout, holders: [String: [GameAction]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capturing {
                Text("Binding “\(capturing.title)” — press the new key or click one on the board (Esc cancels).")
                    .novaFont(.caption).foregroundStyle(novaAmber)
            } else if let id = selectedKey, let cap = layout.keys.first(where: { $0.id == id }) {
                let token = cap.token(on: layer)
                let current = token.flatMap { holders[$0] } ?? []
                Text("Key \(cap.legend.isEmpty ? "Space" : cap.legend) (\(layer.rawValue.lowercased())): "
                     + (current.isEmpty ? "unbound — pick an action to assign it." : "does this now. Pick an action to replace."))
                    .novaFont(.caption).foregroundStyle(novaAmber)
                ForEach(current) { action in
                    HStack {
                        Text(action.title).novaFont(.body)
                        Spacer()
                        CursorButton { onUnbind(action) } label: { EditorChip(text: "Unbind") }
                    }
                }
                if token == nil {
                    Text("This layer can't bind this key.").novaFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Pick an action, then press a key — or click a key to see and change what it does. Amber dots mark keys with bindings on another layer.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bindings whose key isn't on this board (arrows on a 60%, F-keys on a
    /// 65%…) so nothing is hidden by a small layout.
    @ViewBuilder
    private func offKeyboardStrip(layout: KeyboardLayout) -> some View {
        let onBoard = layout.boardTokens
        let off = GameAction.allCases.filter { action in
            let t = keys.token(for: action)
            return !t.isEmpty && !onBoard.contains(KeyboardLayouts.baseToken(of: t))
        }
        if !off.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Off-keyboard bindings").novaFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(off) { action in
                        CursorButton { onActionTap(action) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(action.tint).frame(width: 7, height: 7)
                                Text("\(action.shortName)  \(KeyboardLayouts.label(keys.token(for: action)))")
                                    .novaFont(.caption).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(conflicts.contains(action) ? Color.red : .white.opacity(0.12)))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
