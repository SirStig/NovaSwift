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
    /// What's being counted — "tons" for cargo, "items" for outfits/ammo.
    var unitLabel: String = "tons"
    var onConfirm: (Int) -> Void
    var onCancel: () -> Void

    @State private var text: String

    init(title: String, range: ClosedRange<Int>, initial: Int, unitLabel: String = "tons",
         onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.range = range
        self.unitLabel = unitLabel
        self._text = State(initialValue: "\(min(max(initial, 0), range.upperBound))")
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    /// The typed value: non-digits are stripped, an empty field is 0.
    private var typed: Int { Int(text.filter(\.isNumber)) ?? 0 }

    /// OK: a value above the maximum resets the field to the maximum (the
    /// original beeps and stays open); otherwise it is the answer.
    private func confirm() {
        if typed > range.upperBound { text = "\(range.upperBound)"; return }
        onConfirm(typed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .novaFont(.body, weight: .bold).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                NovaTextField(placeholder: "\(range.upperBound)", text: $text)
                    .onChange(of: text) { _, new in
                        let digits = new.filter(\.isNumber)
                        if digits != new { text = digits }
                    }
                    .frame(width: 96)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    #if !os(tvOS)
                    // The focused text field eats Escape before the Cancel
                    // button's `.cancelAction` shortcut sees it, so catch it
                    // here too (same approach as DevConsoleView's inputBar).
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    #endif
                Text("of \(range.upperBound) \(unitLabel) max")
                    .novaFont(.body).foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                footerButton("Cancel", isDefault: false, action: onCancel)
                footerButton("OK", isDefault: true, action: confirm)
            }
        }
        .padding(20)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2)))
        // A sheet needs this form's intrinsic height. novaResponsive wraps it
        // in a GeometryReader, whose ideal size can clip the footer on macOS.
        .novaTextScale(1)
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
        .buttonStyle(.novaPlain)
        .disabled(!enabled)
        #if os(macOS) || os(iOS)
        .keyboardShortcut(isDefault ? .defaultAction : .cancelAction)
        #endif
    }
}
