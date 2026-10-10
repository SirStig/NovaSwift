import SwiftUI
import NovaSwiftKit

/// A native-control dialog drawn from its own `DLOG`/`DITL`, the way
/// `UiWindow_CreateFromDialogResource` (0x008730a1) + `Dialog_ParseItemList`
/// (0x004cef50) build one: the window is the DLOG size, every item sits at
/// its DITL rect, and the controls use the native chrome of `ClassicUiWindow`
/// (white window, bevelled grey push buttons, X check boxes, sunken edit
/// fields, 12 pt text). A plug-in's replacement DITL moves the items.
///
/// Callers bind behaviour by DITL index (0-based, as `DITLRes` numbers them):
/// text for static items, bindings for check boxes and edit fields, actions
/// for buttons and clickable pictures.
struct ClassicDITLDialog: View {
    let game: NovaGame?
    let graphics: SpaceportGraphics?
    let id: Int
    /// Used when the data has no such DLOG/DITL.
    var fallbackSize = CGSize(width: 340, height: 140)
    /// Natural-size drawing (nil = scale to fit the viewport).
    var fixedScale: CGFloat? = nil
    var texts: [Int: String] = [:]
    var checks: [Int: Binding<Bool>] = [:]
    var edits: [Int: Binding<String>] = [:]
    var actions: [Int: () -> Void] = [:]
    var popups: [Int: (labels: [String], selection: Binding<Int>)] = [:]
    var hidden: Set<Int> = []
    /// Items drawn by the caller (user items).
    var custom: [Int: AnyView] = [:]
    var buttonTitles: [Int: String] = [:]
    var defaultItem: Int? = nil
    var cancelItem: Int? = nil

    private var dialog: NovaDialogRes? { game?.dialog(id) }

    private var size: CGSize {
        if let w = dialog?.window { return CGSize(width: w.bounds.width, height: w.bounds.height) }
        return fallbackSize
    }

    var body: some View {
        GeometryReader { geo in
            let scale = fixedScale ?? novaFrameScale(frame: size, viewport: geo.size)
            ClassicUiWindowPanel {
                ZStack(alignment: .topLeading) {
                    Color.white
                    ForEach(dialog?.items.items ?? [], id: \.index) { item in
                        if !hidden.contains(item.index), inWindow(item) { render(item) }
                    }
                    keys
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
            }
            .fixedSize()
            .cursorScaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// Return = default item, Esc = cancel item (0x004cfdd0).
    @ViewBuilder private var keys: some View {
        Color.clear.frame(width: 0, height: 0)
            .novaDialogKeys(onDefault: defaultItem.flatMap { actions[$0] },
                            onCancel: cancelItem.flatMap { actions[$0] })
    }

    /// Items outside the window (the DITLs park unused ones off-screen) are
    /// not drawn.
    private func inWindow(_ item: DITLItem) -> Bool {
        item.rect.left < Int(size.width) && item.rect.top < Int(size.height)
    }

    private func frame(_ r: NovaRect) -> CGRect {
        CGRect(x: r.left, y: r.top, width: r.width, height: r.height)
    }

    @ViewBuilder private func render(_ item: DITLItem) -> some View {
        let r = frame(item.rect)
        switch item.kind {
        case .button:
            let title = buttonTitles[item.index] ?? item.text
            Button(title) { actions[item.index]?() }
                .buttonStyle(ClassicUiButtonStyle(isFocused: item.index == defaultItem))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        case .checkbox:
            if let b = checks[item.index] {
                ClassicUiCheckBox(title: texts[item.index] ?? item.text, isOn: b)
                    .frame(width: r.width, height: r.height, alignment: .leading)
                    .offset(x: r.minX, y: r.minY)
            }
        case .statText:
            Text(texts[item.index] ?? item.text)
                .font(ClassicUiWindow.font).foregroundStyle(.black)
                .frame(width: r.width, height: r.height, alignment: .topLeading)
                .offset(x: r.minX, y: r.minY)
        case .editText:
            if let b = edits[item.index] {
                TextField("", text: b)
                    .textFieldStyle(.plain)
                    .font(ClassicUiWindow.font).foregroundStyle(.black)
                    .padding(.horizontal, 2)
                    .frame(width: r.width, height: r.height)
                    .background(Color.white)
                    .overlay(ClassicBevel(topLeft: true).stroke(ClassicUiWindow.buttonDark, lineWidth: 1))
                    .overlay(ClassicBevel(topLeft: false).stroke(ClassicUiWindow.buttonLight, lineWidth: 1))
                    .offset(x: r.minX, y: r.minY)
            }
        case .picture, .icon:
            if let rid = item.resourceID, let img = graphics?.pict(rid) {
                let tap = actions[item.index]
                Image(decorative: img, scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .onTapGesture { tap?() }
                    .offset(x: r.minX, y: r.minY)
            }
        case .resControl:
            if let p = popups[item.index] {
                ClassicPopup(labels: p.labels, selection: p.selection)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
        case .userItem, .unknown:
            if let v = custom[item.index] {
                v.frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
        }
    }
}

/// A native pop-up button: bevelled grey box with the current label and a
/// small down triangle.
struct ClassicPopup: View {
    let labels: [String]
    @Binding var selection: Int
    var body: some View {
        Menu {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                Button(l) { selection = i }
            }
        } label: {
            HStack {
                Text(labels.indices.contains(selection) ? labels[selection] : "")
                    .font(ClassicUiWindow.font).foregroundStyle(.black)
                Spacer(minLength: 0)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 9, y: 0))
                    p.addLine(to: CGPoint(x: 4.5, y: 6)); p.closeSubpath()
                }
                .fill(.black).frame(width: 9, height: 6)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClassicUiWindow.buttonFill)
            .overlay(ClassicBevel(topLeft: true).stroke(ClassicUiWindow.buttonLight, lineWidth: 1))
            .overlay(ClassicBevel(topLeft: false).stroke(ClassicUiWindow.buttonDark, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}
