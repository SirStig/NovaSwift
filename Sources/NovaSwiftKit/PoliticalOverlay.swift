import Foundation

/// The star map's political overlay (Show Borders), as the original builds it
/// (`NovaUi_EnableStarmapPoliticalOverlay` 0x004a9d10 →
/// `NovaUi_BuildStarmapPoliticalOverlay` 0x004a9d50 → `NovaUi_PaintStarmapGovDisc`
/// 0x004aa070 / `NovaUi_BlendStarmapOverlayCell` 0x004aa2f3, drawn by
/// 0x004aa620). The canvas is a grid of 2 px cells, each holding up to four
/// (government, strength) slots. Every eligible system paints a disc of
/// radius `round(22 / zoom) + 12` cells (`round(11 / zoom) + 9` for a
/// government with Flags2 0x0002) whose strength at distance `d` is
/// `(r² − d²) × 0.2 × zoom` (0.4 for the small tier), clamped to 1…255. A
/// slot of an allied (or the same) government keeps the larger strength;
/// otherwise the first empty slot is taken, else the weakest slot is
/// replaced. Each cell then shows its strongest slot's government colour ×
/// strength × 0.5 / 255 — a black government colour paints black. `zoom` is
/// the original's map units per pixel (its 0.5…2.0 range).
public struct PoliticalOverlay {
    public struct Disc: Sendable {
        public var cellX: Int, cellY: Int
        public var govt: Int
        public var small: Bool
        public init(cellX: Int, cellY: Int, govt: Int, small: Bool) {
            self.cellX = cellX; self.cellY = cellY; self.govt = govt; self.small = small
        }
    }

    public static let cellSize = 2
    public static let slots = 4

    public let width: Int, height: Int
    /// `width × height × slots` (govt, strength), govt −1 = empty.
    public private(set) var govts: [Int]
    public private(set) var strengths: [Int]

    public init(width: Int, height: Int) {
        self.width = max(0, width); self.height = max(0, height)
        govts = Array(repeating: -1, count: self.width * self.height * Self.slots)
        strengths = Array(repeating: 0, count: self.width * self.height * Self.slots)
    }

    public static func radius(zoom: Double, small: Bool) -> Int {
        small ? Int((11 / zoom).rounded()) + 9 : Int((22 / zoom).rounded()) + 12
    }

    public mutating func paint(_ disc: Disc, zoom: Double, allied: (Int, Int) -> Bool) {
        let r = Self.radius(zoom: zoom, small: disc.small)
        let factor = (disc.small ? 0.4 : 0.2) * zoom
        let r2 = r * r
        let y0 = max(0, disc.cellY - r), y1 = min(height - 1, disc.cellY + r)
        let x0 = max(0, disc.cellX - r), x1 = min(width - 1, disc.cellX + r)
        guard y0 <= y1, x0 <= x1 else { return }
        for y in y0...y1 {
            let dy = y - disc.cellY
            for x in x0...x1 {
                let dx = x - disc.cellX
                let d2 = dx * dx + dy * dy
                guard d2 < r2 else { continue }
                let s = min(255, max(1, Int(Double(r2 - d2) * factor)))
                blend(x, y, govt: disc.govt, strength: s, allied: allied)
            }
        }
    }

    private mutating func blend(_ x: Int, _ y: Int, govt: Int, strength: Int, allied: (Int, Int) -> Bool) {
        let base = (y * width + x) * Self.slots
        for i in 0..<Self.slots where govts[base + i] >= 0 && allied(govts[base + i], govt) {
            strengths[base + i] = max(strengths[base + i], strength)
            return
        }
        for i in 0..<Self.slots where govts[base + i] < 0 {
            govts[base + i] = govt; strengths[base + i] = strength
            return
        }
        var weakest = 0
        for i in 1..<Self.slots where strengths[base + i] < strengths[base + weakest] { weakest = i }
        govts[base + weakest] = govt; strengths[base + weakest] = strength
    }

    /// The strongest slot of a cell, or nil when empty.
    public func strongest(_ x: Int, _ y: Int) -> (govt: Int, strength: Int)? {
        let base = (y * width + x) * Self.slots
        var best: (Int, Int)?
        for i in 0..<Self.slots where govts[base + i] >= 0 {
            if best == nil || strengths[base + i] > best!.1 { best = (govts[base + i], strengths[base + i]) }
        }
        return best.map { (govt: $0.0, strength: $0.1) }
    }

    /// RGBA8 pixels, one per cell: the strongest government's colour ×
    /// strength × 0.5 / 255, opaque; empty cells transparent.
    public func rgba(color: (Int) -> (r: Int, g: Int, b: Int)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                guard let s = strongest(x, y) else { continue }
                let c = color(s.govt)
                let k = Double(s.strength) * 0.5 / 255
                let o = (y * width + x) * 4
                out[o] = UInt8(min(255, Double(c.r) * k))
                out[o + 1] = UInt8(min(255, Double(c.g) * k))
                out[o + 2] = UInt8(min(255, Double(c.b) * k))
                out[o + 3] = 255
            }
        }
        return out
    }
}
