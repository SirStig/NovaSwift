import SwiftUI

/// The action list shared by the Keyboard and Controller tabs: every
/// `GameAction` grouped by category with its current binding chip. Unbound
/// rows are dimmed, rows sharing a key are red, and the selected row shows the
/// capture prompt. Tapping a row selects it (or, when a key/button is selected
/// on the art, assigns the action to it — the parent decides).
struct ActionListPanel<Header: View>: View {
    /// The binding text for an action, nil when unbound.
    let bindingText: (GameAction) -> String?
    /// Optional SF Symbol drawn before the chip (the connected pad's glyph).
    var symbol: (GameAction) -> String? = { _ in nil }
    /// Greyed text for an action whose input is fixed hardware (the sticks) when it has no binding.
    var fixedText: (GameAction) -> String? = { _ in nil }
    let selected: GameAction?
    @Binding var hovered: GameAction?
    let conflicts: Set<GameAction>
    /// Chip text on the selected row while waiting for input.
    let prompt: String
    var canUnbind: (GameAction) -> Bool = { _ in true }
    let onTap: (GameAction) -> Void
    let onUnbind: (GameAction) -> Void
    @ViewBuilder var header: () -> Header

    @State private var search = ""

    private var filtered: [(GameAction.Category, [GameAction])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return GameAction.Category.allCases.compactMap { category in
            let rows = GameAction.allCases.filter { action in
                action.category == category
                    && (q.isEmpty || action.title.lowercased().contains(q)
                        || (bindingText(action) ?? "").lowercased().contains(q))
            }
            return rows.isEmpty ? nil : (category, rows)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header()
            #if !os(tvOS)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions", text: $search)
                    .textFieldStyle(.plain)
                    .novaFont(.body)
                if !search.isEmpty {
                    CursorButton { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
            #endif
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(filtered, id: \.0) { category, actions in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(category.tint).frame(width: 4, height: 13)
                            Text(category.rawValue.uppercased())
                                .novaFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8).padding(.bottom, 2)
                        ForEach(actions) { action in row(action) }
                    }
                }
                .padding(.trailing, 4)
            }
            .cursorScrollable()
        }
    }

    private func row(_ action: GameAction) -> some View {
        let text = bindingText(action)
        let isSelected = selected == action
        let isConflict = conflicts.contains(action)
        return HStack(spacing: 4) {
            CursorButton { onTap(action) } label: {
                HStack(spacing: 8) {
                    Circle().fill(action.tint).frame(width: 8, height: 8)
                    Text(action.title).novaFont(.body)
                        .foregroundStyle(text == nil && !isSelected ? Color.secondary : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    if !isSelected, let name = symbol(action) {
                        Image(systemName: name).foregroundStyle(.secondary)
                    }
                    chip(isSelected ? prompt : (text ?? fixedText(action) ?? "—"), selected: isSelected, conflict: isConflict,
                         dimmed: text == nil && !isSelected)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? novaAmber.opacity(0.14) : (hovered == action ? Color.white.opacity(0.07) : .clear)))
                .contentShape(Rectangle())
            }
            .editorHover { hovered = $0 ? action : (hovered == action ? nil : hovered) }
            // The ✕ is its own pressable so a pad can unbind without a context menu.
            if text != nil, !isSelected, canUnbind(action) {
                CursorButton { onUnbind(action) } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .padding(4).contentShape(Rectangle())
                }
                .accessibilityLabel("Unbind \(action.title)")
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
        }
    }

    private func chip(_ text: String, selected: Bool, conflict: Bool, dimmed: Bool) -> some View {
        let color: Color = conflict ? .red : (selected ? novaAmber : .white)
        return Text(text)
            .novaFont(.hud, weight: .semibold)
            .foregroundStyle(conflict ? Color.red : (selected ? novaAmber : (dimmed ? Color.secondary : Color.primary)))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(minWidth: 52)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(.white.opacity(dimmed ? 0.03 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(selected || conflict ? 1 : 0.15)))
    }
}
