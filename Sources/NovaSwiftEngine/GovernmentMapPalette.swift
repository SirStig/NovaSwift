import Foundation
import NovaSwiftKit

/// A government's real map/territory colour as RGB 0...1, shared by every
/// frontend that colour-codes by government. Governments carry a `gövt.mapColor`,
/// but ~16 of the 68 base-game governments leave it black (unset); those fall
/// back to a deterministic hue assigned by sorted government id so distinct
/// factions still read apart. Independent (`-1`) is always `independent`.
public struct GovernmentMapPalette {
    private let game: NovaGame
    private let fallbackByGovernment: [Int: [Double]]

    /// Deliberately distinct from the galaxy map's amber (current-system marker)
    /// and route colours.
    public static let palette: [[Double]] = [
        [0.35, 0.62, 1.0],   // blue
        [1.0, 0.4, 0.4],     // red
        [0.72, 0.48, 1.0],   // purple
        [0.3, 0.82, 0.85],   // cyan
        [1.0, 0.52, 0.76],   // pink
        [0.93, 0.84, 0.35],  // gold
        [0.28, 0.72, 0.62],  // teal
        [0.62, 0.6, 0.95],   // lavender
    ]

    /// Independent/unresolved (`-1`, or no matching `gövt`) always renders this.
    public static let independent: [Double] = [0.62, 0.62, 0.62]

    public init(game: NovaGame) {
        self.game = game
        var map: [Int: [Double]] = [:]
        for (i, id) in game.govts().map(\.id).sorted().enumerated() {
            map[id] = Self.palette[i % Self.palette.count]
        }
        self.fallbackByGovernment = map
    }

    /// A deterministic per-government hue, ignoring any authored map colour.
    public func fallbackColor(for government: Int) -> [Double] {
        guard government >= 0, let color = fallbackByGovernment[government] else { return Self.independent }
        return color
    }

    /// A government's authentic territory colour (`gövt.mapColor`), falling back
    /// to `fallbackColor` only when the data leaves it black.
    public func color(for government: Int) -> [Double] {
        guard government >= 0 else { return Self.independent }
        if let mc = game.govt(government)?.mapColor, mc.r != 0 || mc.g != 0 || mc.b != 0 {
            return [Double(mc.r) / 255, Double(mc.g) / 255, Double(mc.b) / 255]
        }
        return fallbackColor(for: government)
    }
}
