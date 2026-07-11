import SwiftUI

/// Renders a ship's sprite the way EV Nova's target display and ship-info panels
/// do: a **red monochrome silhouette** — the classic "targeted / selected ship"
/// look — that keeps the sprite's own shading via its luminance rather than
/// flattening it to a solid fill.
///
/// One shared component for every place a ship needs the game's target
/// treatment: the HUD's target readout, the main-menu pilot panel, and any
/// future ship-info surface. `tint` is configurable so the same view also does
/// the neutral (white) and any government-specific variants; pass the raw
/// pixel-art sprite (in-flight sprite frame or dedicated shipyard art).
struct ShipSilhouetteView: View {
    let sprite: CGImage
    /// EV Nova's target-display red by default.
    var tint: Color = Color(red: 0.92, green: 0.22, blue: 0.18)
    /// Small in-flight sprites are pixel art and stay crisp; dedicated shipyard
    /// art (much larger) scales smoothly.
    var pixelated: Bool = true
    /// Overlay the target scope's faint horizontal scan lines. On by default —
    /// the game's target readout has them; turn off for a plain silhouette.
    var scanLines: Bool = true

    var body: some View {
        Image(decorative: sprite, scale: 1)
            .interpolation(pixelated ? .none : .high)
            .resizable()
            .scaledToFit()
            // Desaturate to the sprite's own luminance, then multiply by the
            // tint: a *shaded* red monochrome (bright hull → bright red, dark
            // detail → dark red), matching the game's target render. Both
            // modifiers preserve the sprite's alpha — so the ONLY thing tinted is
            // the ship's actual outline (a sprite with a real transparency mask),
            // never a solid backing box.
            .grayscale(1)
            .colorMultiply(tint)
            // Scope scan lines drawn only over the ship itself (masked to the
            // sprite's alpha), so they never paint a rectangle behind it.
            .overlay {
                if scanLines {
                    ScanLines()
                        .mask(Image(decorative: sprite, scale: 1)
                            .interpolation(pixelated ? .none : .high).resizable().scaledToFit())
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The thin, evenly-spaced dark horizontal lines of EV Nova's target scope,
/// drawn as a repeating gradient so they scale with whatever size they're given.
private struct ScanLines: View {
    var body: some View {
        GeometryReader { geo in
            let lineGap: CGFloat = 3
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(.black.opacity(0.35)))
                    y += lineGap
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
