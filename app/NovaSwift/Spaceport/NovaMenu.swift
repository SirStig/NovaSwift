import SwiftUI
import NovaSwiftKit
#if os(macOS)
import AppKit
#endif

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

/// EV Nova's design screen. Every authentic frame PICT was authored to sit on
/// a 1024×768 game screen at 1:1 pixels — the 618×517 spaceport hub filled
/// ~60% of it, the 263×185 bar panel ~25%, and so on.
let novaReferenceScreen = CGSize(width: 1024, height: 768)

/// The scale for an authentic frame of `frame` native pixels shown in
/// `viewport`, shared by every `scaleEffect`-based authentic screen
/// (`NovaMenu`, the galaxy map, the gambling panels).
///
/// Every frame renders at the **same** scale: the one the shared 1024×768 game
/// screen gets when letterboxed into the viewport. That is what keeps relative
/// sizes authentic — a small bar panel stays a small window over the spaceport
/// hub instead of each frame independently blowing up to fill the viewport
/// (which made a 263×185 bar dialog render as large as the 765×321 outfitter,
/// and everything ~2.5× the size the original game ever showed it).
///
/// - `minScale`: readability floor for small devices — a frame never renders
///   below this *unless* it wouldn't fit the viewport at all, in which case it
///   shrinks to fit rather than clipping off-screen. (On a phone the shared
///   screen scale is ~0.4×, which would make dialog text unreadable; small
///   frames get floored to 1× there and only the largest frames shrink.)
/// - `maxScale`: ceiling so the whole UI doesn't balloon on a huge display.
func novaFrameScale(frame: CGSize, viewport: CGSize,
                    minScale: CGFloat = 1.0, maxScale: CGFloat = 2.6) -> CGFloat {
    guard frame.width > 0, frame.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
    let screenFit = min(viewport.width / novaReferenceScreen.width,
                        viewport.height / novaReferenceScreen.height)
    let frameFit = min(viewport.width / frame.width, viewport.height / frame.height)
    return min(frameFit, maxScale, max(screenFit, minScale))
}

/// A full-screen EV Nova menu: draws the frame PICT from the player's data,
/// scaled to fit and centred (letterboxed on black), and lays children out in
/// its native coordinate space. Every spaceport screen is one of these.
struct NovaMenu<Content: View>: View {
    let frame: CGImage
    var maxScale: CGFloat = 2.6
    /// Dialog mode: render at the shared spaceport scale (so the frame appears at
    /// its true relative size, centred), with a transparent background so it
    /// OVERLAYS the landing hub instead of replacing it — as EV Nova stacks the
    /// outfitter / shipyard / bar / trade windows over the spaceport.
    var overlay: Bool = false
    @Environment(\.novaDebugEnabled) private var novaDebug
    @ViewBuilder var content: (NovaSpace) -> Content

    var body: some View {
        let nw = CGFloat(frame.width), nh = CGFloat(frame.height)
        let space = NovaSpace(width: nw, height: nh)
        GeometryReader { geo in
            // Each frame scales to fill a consistent fraction of the actual
            // viewport (see `novaFrameScale`) — readable on a phone, sane on a
            // 4K desktop — rather than against a fixed 1024×768 canvas the small
            // dialog frames never filled.
            let scale = novaFrameScale(frame: CGSize(width: nw, height: nh), viewport: geo.size, maxScale: maxScale)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: nw, height: nh)
                content(space).novaTextScale(1)
                if novaDebug { NovaDebugGrid.forSpace(space) }
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
    /// Force to a single line and shrink the font (down to 50%) instead of
    /// wrapping — for a fixed-width field showing a variable-length value
    /// (credit amounts, prices) where wrapping reads as row overflow/growth
    /// rather than a clean single line. Off by default: most `NovaText` uses
    /// (descriptions, labels) want their normal wrap-and-grow behavior.
    var shrinkToFit: Bool = false

    init(_ text: String, size: CGFloat = 12, color: Color = .white,
         width: CGFloat? = nil, align: TextAlignment = .leading, weight: Font.Weight = .regular,
         shrinkToFit: Bool = false) {
        self.text = text
        self.size = size
        self.color = color
        self.width = width
        self.align = align
        self.weight = weight
        self.shrinkToFit = shrinkToFit
    }

    var body: some View {
        Text(text)
            .font(.custom(NovaFontRole.body.family, size: size).weight(weight))
            .foregroundStyle(color)
            .multilineTextAlignment(align)
            .lineLimit(shrinkToFit ? 1 : nil)
            .minimumScaleFactor(shrinkToFit ? 0.5 : 1)
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
    /// Real EV Nova's "how many?" quantity dialog: Option-click (the game's own
    /// manual calls it Alt-click) on Buy/Sell brings up a prompt to type an
    /// exact amount instead of transacting one at a time. On macOS this checks
    /// the live modifier state at click time; on touch (no Option key) a
    /// long-press is the equivalent gesture. `nil` (the default, e.g. Done,
    /// scroll arrows) means this button has no quantity to ask about.
    /// Declared before `action` so the trailing-closure call sites (`NovaButton(...) { ... }`)
    /// keep binding that closure to `action`, not this one.
    var onQuantity: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.novaTheme) private var theme
    @State private var longPressFired = false

    var body: some View {
        Button(action: {
            guard enabled else { return }
            #if os(macOS)
            if let onQuantity, NSEvent.modifierFlags.contains(.option) { onQuantity(); return }
            #endif
            if longPressFired { longPressFired = false; return }
            action()
        }) { Color.clear }
            .buttonStyle(NovaButtonStyle(graphics: graphics, title: title, width: width,
                                         enabled: enabled, theme: theme))
            .disabled(!enabled)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    guard enabled, let onQuantity else { return }
                    longPressFired = true
                    onQuantity()
                }
            )
    }
}

/// A small square authentic button (the full three-slice art at its minimum
/// 26×25 geometry) with an SF Symbol glyph instead of a text label — for the
/// controls the game draws as bare 25×25 `userItem`s (the Outfitter/Shipyard
/// scroll arrows, the galaxy map's zoom −/+). The game's own art for these
/// (PICT #134/#135 "Up arrow"/"Down Arrow") uses a vector PICT opcode our
/// decoder doesn't handle, so the glyph stands in on the real button chrome.
struct NovaIconButton: View {
    let graphics: SpaceportGraphics
    let systemName: String
    var enabled: Bool = true
    let action: () -> Void
    @Environment(\.novaTheme) private var theme

    var body: some View {
        Button(action: { if enabled { action() } }) { Color.clear }
            .buttonStyle(NovaIconButtonStyle(graphics: graphics, systemName: systemName,
                                             enabled: enabled, theme: theme))
            .disabled(!enabled)
    }
}

struct NovaIconButtonStyle: ButtonStyle {
    let graphics: SpaceportGraphics
    let systemName: String
    let enabled: Bool
    var theme: NovaUITheme = .fallback

    func makeBody(configuration: Configuration) -> some View {
        let state: SpaceportGraphics.ButtonState =
            !enabled ? .grey : (configuration.isPressed ? .clicked : .normal)
        let slices = graphics.buttonSlices(state)
        HStack(spacing: 0) {
            slice(slices.left)
            slice(slices.right)
        }
        .frame(width: 26, height: 25)
        .overlay(
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? theme.buttonUp : theme.buttonGrey)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private func slice(_ image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.high).resizable()
                .frame(width: 13, height: 25)
        } else {
            Color(white: 0.2).frame(width: 13, height: 25)
        }
    }
}

struct NovaButtonStyle: ButtonStyle {
    let graphics: SpaceportGraphics
    let title: String
    let width: CGFloat
    let enabled: Bool
    /// The cölr interface theme (label colours + button font). `.fallback` keeps
    /// the pre-data-driven look for any direct instantiation without one.
    var theme: NovaUITheme = .fallback

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
            // Geneva 12, fixed in frame pixels like all authentic-screen text
            // (verified against the vendored NovaJS `button.ts` text style).
            // `.novaFont(.button)` is for native chrome — its 15pt base and
            // 13pt floor overflow a 25px-tall authentic button. cölr.buttonFont
            // overrides the family when the data supplies (and registers) one.
            Text(title)
                .font(.custom(theme.buttonFont ?? NovaFontRole.button.family, size: 12))
                .foregroundStyle(labelColor(state))
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
        case .normal:  return theme.buttonUp
        case .clicked: return theme.buttonDown
        case .grey:    return theme.buttonGrey
        }
    }
}
