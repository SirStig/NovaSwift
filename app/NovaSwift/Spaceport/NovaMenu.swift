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
            .cursorScaleEffect(scale)
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

/// An authentic three-slice EV Nova button (left cap + stretched middle + right cap
/// PICTs 7500–7508) with its label drawn on top. `width` is the middle span, so
/// the button is `capL + width + capR` wide (26 + width with the stock caps).
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
        #if os(tvOS)
        // No real `Button` on tvOS — buttons are always focusable there and
        // the focus engine would paint its huge white platter over the art
        // (see CursorButton). The cursor is the pointer; the face + a cursor
        // target is the whole control. No long-press either: tvOS has no
        // touch, so the quantity prompt stays a macOS/iOS affordance.
        NovaButtonFace(graphics: graphics, title: title, width: width,
                       state: enabled ? .normal : .grey, theme: theme)
            .contentShape(Rectangle())
            .cursorClickable { if enabled { action() } }
        #else
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
            // Every authentic button is pressable by the controller cursor.
            .cursorClickable { if enabled { action() } }
        #endif
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
        #if os(tvOS)
        // Same as NovaButton: face + cursor target, no focusable Button.
        NovaIconButtonFace(graphics: graphics, systemName: systemName,
                           state: enabled ? .normal : .grey, enabled: enabled, theme: theme)
            .contentShape(Rectangle())
            .cursorClickable { if enabled { action() } }
        #else
        Button(action: { if enabled { action() } }) { Color.clear }
            .buttonStyle(NovaIconButtonStyle(graphics: graphics, systemName: systemName,
                                             enabled: enabled, theme: theme))
            .disabled(!enabled)
            .cursorClickable { if enabled { action() } }
        #endif
    }
}

struct NovaIconButtonStyle: ButtonStyle {
    let graphics: SpaceportGraphics
    let systemName: String
    let enabled: Bool
    var theme: NovaUITheme = .fallback

    func makeBody(configuration: Configuration) -> some View {
        NovaIconButtonFace(graphics: graphics, systemName: systemName,
                           state: !enabled ? .grey : (configuration.isPressed ? .clicked : .normal),
                           enabled: enabled, theme: theme)
            .contentShape(Rectangle())
    }
}

/// The square icon button's visual, independent of `Button` machinery so the
/// tvOS cursor path can draw it directly (see `NovaIconButton.body`). The
/// original labels these buttons `^`, `&`, `+` or `-`, which
/// `NovaUi_DrawThreeStateButton` draws as 2-px-pen vector glyphs instead of
/// text; the SF Symbol names callers pass map onto those glyphs.
struct NovaIconButtonFace: View {
    let graphics: SpaceportGraphics
    let systemName: String
    let state: SpaceportGraphics.ButtonState
    let enabled: Bool
    var theme: NovaUITheme = .fallback

    var body: some View {
        let slices = graphics.buttonSlices(state)
        ThreeStateButtonArt(slices: slices, totalWidth: CGFloat(slices.left?.width ?? 12)
                                + CGFloat(slices.right?.width ?? 12),
                            label: Self.glyphLabel(systemName), state: state, theme: theme)
    }

    static func glyphLabel(_ systemName: String) -> String {
        if systemName.hasPrefix("arrowtriangle.up") || systemName.hasPrefix("chevron.up") { return "^" }
        if systemName.hasPrefix("arrowtriangle.down") || systemName.hasPrefix("chevron.down") { return "&" }
        if systemName.hasPrefix("plus") { return "+" }
        if systemName.hasPrefix("minus") { return "-" }
        return ""
    }
}

/// The original three-state button drawing (`NovaUi_DrawThreeStateButton`
/// 0x004a3340): masked caps at their own PICT widths, stretched to the button
/// height; the unmasked middle stretched across the span between them; then
/// either a vector glyph (`^ & + -`) or the label in the cölr button font and
/// size, centred.
struct ThreeStateButtonArt: View {
    let slices: (left: CGImage?, middle: CGImage?, right: CGImage?)
    let totalWidth: CGFloat
    var height: CGFloat = 25
    let label: String
    let state: SpaceportGraphics.ButtonState
    var theme: NovaUITheme = .fallback
    /// Overrides the cölr label colour (the player-info tabs use their own).
    var labelColor: Color? = nil

    var body: some View {
        let layout = ThreeStateButton.layout(width: Int(totalWidth.rounded()),
                                             leftCapWidth: slices.left?.width,
                                             rightCapWidth: slices.right?.width)
        ZStack(alignment: .topLeading) {
            piece(slices.middle, CGFloat(layout.middleWidth)).offset(x: CGFloat(layout.middleX))
            piece(slices.left, CGFloat(layout.leftCapWidth))
            piece(slices.right, CGFloat(layout.rightCapWidth)).offset(x: CGFloat(layout.rightCapX))
            labelView
        }
        .frame(width: totalWidth, height: height, alignment: .topLeading)
    }

    @ViewBuilder private var labelView: some View {
        let colour = labelColor ?? stateColour
        if let segs = ThreeStateButton.glyph(label, width: Int(totalWidth.rounded()), height: Int(height)) {
            Path { p in
                // QuickDraw's 2x2 pen hangs below-right of the path.
                for g in segs {
                    p.move(to: CGPoint(x: CGFloat(g.fromX) + 1, y: CGFloat(g.fromY) + 1))
                    p.addLine(to: CGPoint(x: CGFloat(g.toX) + 1, y: CGFloat(g.toY) + 1))
                }
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .square))
            .frame(width: totalWidth, height: height)
        } else if !label.isEmpty {
            // cölr ButtonFont / ButtonFontSz used as given (no size cap).
            Text(label)
                .font(.custom(theme.buttonFont ?? NovaFontRole.button.family,
                              size: theme.buttonFontSize ?? 12))
                .foregroundStyle(colour)
                .fixedSize()
                .frame(width: totalWidth, height: height)
        }
    }

    private var stateColour: Color {
        switch state {
        case .normal:  return theme.buttonUp
        case .clicked: return theme.buttonDown
        case .grey:    return theme.buttonGrey
        }
    }

    @ViewBuilder private func piece(_ image: CGImage?, _ w: CGFloat) -> some View {
        if w > 0 {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: w, height: height)
            } else {
                Color.black.frame(width: w, height: height)
            }
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
        NovaButtonFace(graphics: graphics, title: title, width: width,
                       state: !enabled ? .grey : (configuration.isPressed ? .clicked : .normal),
                       theme: theme)
            .contentShape(Rectangle())
    }
}

/// The three-slice button's visual, independent of `Button` machinery so the
/// tvOS cursor path can draw it directly (see `NovaButton.body`). `width` is the
/// middle span; the caps add their own PICT widths (13 each in the stock data).
struct NovaButtonFace: View {
    let graphics: SpaceportGraphics
    let title: String
    let width: CGFloat
    let state: SpaceportGraphics.ButtonState
    var theme: NovaUITheme = .fallback

    var body: some View {
        let slices = graphics.buttonSlices(state)
        ThreeStateButtonArt(slices: slices,
                            totalWidth: CGFloat(slices.left?.width ?? 12) + width
                                + CGFloat(slices.right?.width ?? 12),
                            label: title, state: state, theme: theme)
    }
}
