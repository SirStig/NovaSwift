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
    /// Classic presentation: the original's native dialog (DITL #1003 in the
    /// `UiWindow` chrome) instead of the port's dark card.
    private let classic: Bool

    init(title: String, range: ClosedRange<Int>, initial: Int, unitLabel: String = "tons",
         onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.range = range
        self.unitLabel = unitLabel
        self._text = State(initialValue: "\(min(max(initial, range.lowerBound), range.upperBound))")
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.classic = !GameSettings.load().modernDialogs
    }

    private var parsedQuantity: Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    var body: some View {
        if classic { classicBody } else { modernBody }
    }

    /// DITL #1003 "qty" (172×72): the prompt (item 2) at (6,8) 102×16, the
    /// edit field (item 3) at (112,8) 51×16, OK (item 1) at (92,42) and
    /// Cancel (item 4) at (10,42), both 70×20, in the native white window.
    /// Return is OK and Esc is Cancel, as in every original dialog.
    private var classicBody: some View {
        ClassicUiWindowPanel {
            ZStack(alignment: .topLeading) {
                Color.white
                Text(title)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .frame(width: 102, height: 16, alignment: .topLeading)
                    .offset(x: 6, y: 8)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(ClassicUiWindow.font)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 2)
                    .frame(width: 51, height: 16)
                    .background(Color.white)
                    .overlay(ClassicBevel(topLeft: true).stroke(ClassicUiWindow.buttonDark, lineWidth: 1))
                    .overlay(ClassicBevel(topLeft: false).stroke(ClassicUiWindow.buttonLight, lineWidth: 1))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    #if !os(tvOS)
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    #endif
                    .offset(x: 112, y: 8)
                Button("OK") { if let q = parsedQuantity { onConfirm(q) } }
                    .buttonStyle(ClassicUiButtonStyle(isFocused: true))
                    .frame(width: 70, height: 20)
                    .disabled(parsedQuantity == nil)
                    #if os(macOS) || os(iOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                    .offset(x: 92, y: 42)
                Button("Cancel", action: onCancel)
                    .buttonStyle(ClassicUiButtonStyle())
                    .frame(width: 70, height: 20)
                    #if os(macOS) || os(iOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
                    .offset(x: 10, y: 42)
            }
            .frame(width: 172, height: 72, alignment: .topLeading)
        }
        .novaTextScale(1)
    }

    private var modernBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .novaFont(.body, weight: .bold).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                NovaTextField(placeholder: "\(range.upperBound)", text: $text)
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
                footerButton("OK", isDefault: true, enabled: parsedQuantity != nil) {
                    if let q = parsedQuantity { onConfirm(q) }
                }
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
