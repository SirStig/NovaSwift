import Foundation

// The `ïntf` (interface) resource defines EV Nova's authentic in-flight status
// bar: the colors and on-screen rectangles for the radar, shield / armor / fuel
// bars, and the nav/weapon/target/cargo readouts, plus a background PICT id.
// EV Nova ships seven of them — one per major government ("Default", "Polaris",
// "Federation", …) so the HUD reskins with your allegiance.
//
// Byte layout reverse-engineered and verified against the real 166-byte resource:
//   colors are 4 bytes 0x00RRGGBB; rects are 4×int16 (top,left,bottom,right).

/// An interface colour (EV Nova stores these as 0x00RRGGBB).
public struct NovaColor: Equatable, Hashable {
    public let r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// A QuickDraw rectangle (top, left, bottom, right), origin top-left.
public struct NovaRect: Equatable, Sendable {
    public let top: Int, left: Int, bottom: Int, right: Int
    public var width: Int { right - left }
    public var height: Int { bottom - top }
    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

/// The decoded interface / status-bar definition.
public struct IntfRes {
    public let id: Int
    public let name: String
    public let brightText: NovaColor
    public let dimText: NovaColor
    public let radarArea: NovaRect
    public let brightRadar: NovaColor
    public let dimRadar: NovaColor
    public let shieldArea: NovaRect
    public let shieldColor: NovaColor
    public let armorArea: NovaRect
    public let armorColor: NovaColor
    public let fuelArea: NovaRect
    public let fuelFull: NovaColor
    public let fuelPartial: NovaColor
    public let navArea: NovaRect
    public let weaponArea: NovaRect
    public let targetArea: NovaRect
    public let cargoArea: NovaRect
    public let statusFont: String
    public let statusFontSize: Int
    public let subtitleFontSize: Int
    /// PICT resource id drawn as the status-bar backdrop (e.g. 700).
    public let backgroundPictID: Int

    public init(_ resource: Resource) {
        id = resource.id
        name = resource.name
        let d = resource.data

        func color(_ off: Int) -> NovaColor {
            // 0x00RRGGBB — first byte padding.
            guard off + 4 <= d.count else { return NovaColor(r: 0, g: 0, b: 0) }
            let b = d.startIndex + off
            return NovaColor(r: d[b + 1], g: d[b + 2], b: d[b + 3])
        }
        func i16(_ off: Int) -> Int {
            guard off + 2 <= d.count else { return 0 }
            let b = d.startIndex + off
            let v = (Int(d[b]) << 8) | Int(d[b + 1])
            return v >= 0x8000 ? v - 0x10000 : v
        }
        func rect(_ off: Int) -> NovaRect {
            NovaRect(top: i16(off), left: i16(off + 2), bottom: i16(off + 4), right: i16(off + 6))
        }

        brightText   = color(0)
        dimText      = color(4)
        radarArea    = rect(8)
        brightRadar  = color(16)
        dimRadar     = color(20)
        shieldArea   = rect(24)
        shieldColor  = color(32)
        armorArea    = rect(36)
        armorColor   = color(44)
        fuelArea     = rect(48)
        fuelFull     = color(56)
        fuelPartial  = color(60)
        navArea      = rect(64)
        weaponArea   = rect(72)
        targetArea   = rect(80)
        cargoArea    = rect(88)
        // Font name: NUL-terminated Mac Roman in a fixed 64-byte field at 96.
        let fontEnd = min(d.startIndex + 160, d.endIndex)
        let fontBytes = d[(d.startIndex + 96)..<fontEnd].prefix { $0 != 0 }
        statusFont = String(data: Data(fontBytes), encoding: .macOSRoman) ?? ""
        statusFontSize   = i16(160)
        subtitleFontSize = i16(162)
        backgroundPictID = i16(164)
    }
}

public extension NovaGame {
    /// The status-bar interface definition (id 128 = "Default"; 129… per government).
    func interface(_ id: Int = 128) -> IntfRes? {
        resources.resource(NovaType.intf, id).map(IntfRes.init)
    }
}
