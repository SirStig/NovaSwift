import SwiftUI

/// The original's native dialog chrome (`UiWindow_Draw` 0x004d0d00), used by
/// the resource dialogs whose items are real controls rather than PICT art —
/// the text prompt (DLOG 3001), the yes/no confirm (3002), the quantity
/// prompt and the options windows:
/// - font family 0 ("Chicago") size 12, black text on a white window;
/// - push buttons: a 35000-grey fill with a bevel (`FUN_004d0a50`) — 50000
///   light on the top/left edges inset 1, 15000 dark on the bottom/right
///   inset 1-2; pressed: 25000 fill with light and dark swapped; the label is
///   centred with its baseline at `(top+bottom+size)/2 − 1`;
/// - the keyboard-focused control gets a dotted rect inset 3 (`FUN_004d0bd0`);
/// - check boxes / radio buttons: a 17×17 bevelled box, an X inset 3 when
///   checked, the label at x+20;
/// - edit fields: the same bevel sunken (dark top/left, light bottom/right).
enum ClassicUiWindow {
    static func grey(_ v: Double) -> Color { Color(white: v / 65535) }
    static let buttonFill = grey(35000)
    static let buttonLight = grey(50000)
    static let buttonDark = grey(15000)
    static let buttonPressedFill = grey(25000)
    static let fontSize: CGFloat = 12
    /// "Chicago" is the original's family 0; Charcoal/Geneva stand in when the
    /// system doesn't have it.
    static var font: Font { .custom("Chicago", size: fontSize) }
}

/// The 3-D bevel of `FUN_004d0a50`: light lines along the top and left edges
/// (inset 1), dark along the bottom and right (inset 1-2).
struct ClassicBevel: Shape {
    var topLeft: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if topLeft {
            p.move(to: CGPoint(x: r.minX + 1.5, y: r.maxY - 1))
            p.addLine(to: CGPoint(x: r.minX + 1.5, y: r.minY + 1.5))
            p.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + 1.5))
        } else {
            p.move(to: CGPoint(x: r.minX + 1, y: r.maxY - 1.5))
            p.addLine(to: CGPoint(x: r.maxX - 1.5, y: r.maxY - 1.5))
            p.addLine(to: CGPoint(x: r.maxX - 1.5, y: r.minY + 1))
        }
        return p
    }
}

/// A native push button.
struct ClassicUiButtonStyle: ButtonStyle {
    var isFocused = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(ClassicUiWindow.font)
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(minWidth: 70, minHeight: 20)
            .background(pressed ? ClassicUiWindow.buttonPressedFill : ClassicUiWindow.buttonFill)
            .overlay(ClassicBevel(topLeft: true)
                .stroke(pressed ? ClassicUiWindow.buttonDark : ClassicUiWindow.buttonLight, lineWidth: 1))
            .overlay(ClassicBevel(topLeft: false)
                .stroke(pressed ? ClassicUiWindow.buttonLight : ClassicUiWindow.buttonDark, lineWidth: 1))
            .overlay {
                if isFocused {
                    Rectangle().inset(by: 3)
                        .stroke(.black, style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
                }
            }
    }
}

/// A native check box (radio buttons draw the same way in the original).
struct ClassicUiCheckBox: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 3) {
                ZStack {
                    ClassicUiWindow.buttonFill
                    ClassicBevel(topLeft: true).stroke(ClassicUiWindow.buttonLight, lineWidth: 1)
                    ClassicBevel(topLeft: false).stroke(ClassicUiWindow.buttonDark, lineWidth: 1)
                    if isOn {
                        Path { p in
                            p.move(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 14, y: 14))
                            p.move(to: CGPoint(x: 14, y: 3)); p.addLine(to: CGPoint(x: 3, y: 14))
                        }
                        .stroke(.black, lineWidth: 1)
                    }
                }
                .frame(width: 17, height: 17)
                Text(title).font(ClassicUiWindow.font).foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The white window the native controls sit in.
struct ClassicUiWindowPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .font(ClassicUiWindow.font)
            .foregroundStyle(.black)
            .background(Color.white)
            .overlay(Rectangle().stroke(.black, lineWidth: 1))
    }
}
