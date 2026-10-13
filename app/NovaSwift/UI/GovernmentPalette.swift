import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// A government's real map/territory color, shared across every UI that
/// color-codes by government (the galaxy map's regions, the Story Map's
/// storyline lanes, …) so the same government reads as the same color
/// everywhere. Built once per loaded game — cheap to keep around, no need to
/// rebuild per frame or per view.
///
/// Governments carry a real `gövt.mapColor`, but ~16 of the 68 base-game
/// governments leave it black (unset); those — and anything player-facing as
/// "independent" — fall back to a deterministic hue assigned by sorted
/// government id, so distinct factions still read apart even without an
/// authored color.
struct GovernmentPalette {
    private let shared: GovernmentMapPalette

    /// Independent/unresolved (`-1`, or no matching `gövt`) always renders this.
    static let independent = Color(white: 0.62)

    init(game: NovaGame) { shared = GovernmentMapPalette(game: game) }

    private static func swiftUIColor(_ rgb: [Double]) -> Color {
        Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// A deterministic per-government hue, ignoring any authored map color —
    /// used both as `color(for:)`'s fallback and by anything (like the Story
    /// Map's sidebar swatches) that just wants "a" distinct color per
    /// government rather than the authentic territory one.
    func fallbackColor(for government: Int) -> Color {
        Self.swiftUIColor(shared.fallbackColor(for: government))
    }

    /// A government's authentic **territory** color — its real `gövt.mapColor`
    /// (Federation blue, Auroran red, the Pirate families' greys, …). Falls
    /// back to `fallbackColor` only when the data leaves it black (16 of the
    /// 68 base governments do).
    func color(for government: Int) -> Color {
        Self.swiftUIColor(shared.color(for: government))
    }
}
