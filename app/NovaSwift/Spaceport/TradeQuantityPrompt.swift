import SwiftUI

/// The real game's "type an exact amount" prompt — DITL #1003 ("qty", 74 bytes):
/// a `statText` label (template `"^0"`, filled in with the item/action at
/// runtime), a 51×16 `editText` for the number, and OK/Cancel buttons, in a
/// 172×72 dialog. EV Nova uses this whenever the player wants to buy/sell (or
/// jettison) a specific tonnage instead of clicking one-at-a-time — this is
/// the port's equivalent, styled like `NovaDialog`'s footer buttons since the
/// three-slice button PICTs don't read well at this dialog's small size.
struct TradeQuantityPrompt: View {
    let title: String
    /// Inclusive bound the player can type up to (e.g. cargo-hold-limited on
    /// buy, held-amount on sell) — advisory for the field; the actual
    /// transaction still clamps again against live affordability/hold.
    let range: ClosedRange<Int>
    var onConfirm: (Int) -> Void
    var onCancel: () -> Void

    @State private var text: String

    init(title: String, range: ClosedRange<Int>, initial: Int,
         onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.range = range
        self._text = State(initialValue: "\(min(max(initial, range.lowerBound), range.upperBound))")
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var parsedQuantity: Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).novaFont(.body, weight: .bold).foregroundStyle(.white)
            HStack(spacing: 8) {
                NovaTextField(placeholder: "\(range.upperBound)", text: $text)
                    .frame(width: 80)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("of \(range.upperBound) tons max")
                    .novaFont(.body).foregroundStyle(.gray)
            }
            HStack(spacing: 10) {
                Spacer()
                footerButton("Cancel", isDefault: false, action: onCancel)
                footerButton("OK", isDefault: true, enabled: parsedQuantity != nil) {
                    if let q = parsedQuantity { onConfirm(q) }
                }
            }
        }
        .padding(20)
        .frame(width: 220)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2)))
        .novaResponsive()
    }

    // Matches NovaDialog's footer-button style (the three-slice PICT chrome
    // is sized for full dialogs, not this small a control).
    private func footerButton(_ title: String, isDefault: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .novaFont(.button)
                .foregroundStyle(!enabled ? Color(white: 0.45) : (isDefault ? .black : .white))
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        isDefault
                        ? LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
