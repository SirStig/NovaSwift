import SwiftUI
import EVNovaKit

/// EV Nova's menu coordinate space: the origin is the **centre** of the frame
/// PICT, matching the game's layout (children are positioned as offsets from the
/// frame centre, in the frame's native pixels).
struct NovaSpace {
    let width: CGFloat
    let height: CGFloat
    /// Native top-left point for a child whose EV Nova position is `(cx, cy)`
    /// relative to the frame centre (top-left anchored, as EV Nova lays them out).
    func point(_ cx: CGFloat, _ cy: CGFloat) -> CGPoint {
        CGPoint(x: width / 2 + cx, y: height / 2 + cy)
    }
}

extension View {
    /// Place this view at EV Nova position `(cx, cy)` (offset from frame centre,
    /// top-left anchored) inside a `NovaMenu`'s top-leading content layer.
    func novaPlace(_ space: NovaSpace, _ cx: CGFloat, _ cy: CGFloat) -> some View {
        let p = space.point(cx, cy)
        return self.offset(x: p.x, y: p.y)
    }
}

/// A full-screen EV Nova menu: draws the frame PICT from the player's data,
/// scaled to fit and centred (letterboxed on black), and lays children out in
/// its native coordinate space. Every spaceport screen is one of these.
struct NovaMenu<Content: View>: View {
    let frame: CGImage
    var maxScale: CGFloat = 2.2
    /// Dialog mode: render at the shared spaceport scale (so the frame appears at
    /// its true relative size, centred), with a transparent background so it
    /// OVERLAYS the landing hub instead of replacing it — as EV Nova stacks the
    /// outfitter / shipyard / bar / trade windows over the spaceport.
    var overlay: Bool = false
    @ViewBuilder var content: (NovaSpace) -> Content

    /// The reference design space every spaceport screen shares, so a small dialog
    /// frame is drawn at the same scale as the full landing interface — never
    /// fit-scaled up to fill the whole window.
    private static var reference: CGSize { CGSize(width: 1024, height: 768) }

    var body: some View {
        let nw = CGFloat(frame.width), nh = CGFloat(frame.height)
        let space = NovaSpace(width: nw, height: nh)
        GeometryReader { geo in
            // Every spaceport screen (hub + dialogs) shares one design scale
            // (1024×768), so the landing frame renders at its true proportions
            // centered — not fit-scaled up to fill the window — and dialogs overlay
            // it at a matching scale.
            let ref = Self.reference
            let scale = min(min(geo.size.width / ref.width, geo.size.height / ref.height), maxScale)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: nw, height: nh)
                content(space)
            }
            .frame(width: nw, height: nh, alignment: .topLeading)
            .scaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background((overlay ? Color.clear : Color.black).ignoresSafeArea())
    }
}

/// EV Nova body text (Geneva, white by default). Geneva ships with macOS; on
/// iOS it falls back to the system sans, which is a close visual match.
struct NovaText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = .white
    var width: CGFloat? = nil
    var align: TextAlignment = .leading
    var weight: Font.Weight = .regular

    init(_ text: String, size: CGFloat = 12, color: Color = .white,
         width: CGFloat? = nil, align: TextAlignment = .leading, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.color = color
        self.width = width
        self.align = align
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(.custom("Geneva", size: size).weight(weight))
            .foregroundStyle(color)
            .multilineTextAlignment(align)
            .frame(width: width,
                   alignment: align == .leading ? .leading : (align == .trailing ? .trailing : .center))
            .fixedSize(horizontal: width == nil, vertical: true)
    }
}

/// An authentic three-slice EV Nova button (left cap + tiling middle + right cap
/// PICTs 7500–7508) with its label drawn on top. `width` is the middle span, so
/// the button is `26 + width` wide overall — matching the game's geometry.
struct NovaButton: View {
    let graphics: SpaceportGraphics
    let title: String
    var width: CGFloat = 120
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled { action() } }) { Color.clear }
            .buttonStyle(NovaButtonStyle(graphics: graphics, title: title, width: width, enabled: enabled))
            .disabled(!enabled)
    }
}

struct NovaButtonStyle: ButtonStyle {
    let graphics: SpaceportGraphics
    let title: String
    let width: CGFloat
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let state: SpaceportGraphics.ButtonState =
            !enabled ? .grey : (configuration.isPressed ? .clicked : .normal)
        let slices = graphics.buttonSlices(state)
        HStack(spacing: 0) {
            slice(slices.left, 13)
            slice(slices.middle, width)
            slice(slices.right, 13)
        }
        .frame(width: 26 + width, height: 25)
        .overlay(
            Text(title)
                .font(.custom("Geneva", size: 12))
                .foregroundStyle(labelColor(state))
                .lineLimit(1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private func slice(_ image: CGImage?, _ w: CGFloat) -> some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.high).resizable()
                .frame(width: w, height: 25)
        } else {
            Color(white: 0.2).frame(width: w, height: 25)
        }
    }

    private func labelColor(_ state: SpaceportGraphics.ButtonState) -> Color {
        switch state {
        case .normal:  return .white
        case .clicked: return Color(white: 0.5)
        case .grey:    return Color(white: 0.15)
        }
    }
}
