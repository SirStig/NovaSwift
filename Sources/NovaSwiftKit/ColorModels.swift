import Foundation
// `CGPoint`/`CGFloat` come from CoreGraphics on Apple platforms and from
// Foundation (swift-corelib-foundation) on Linux/Windows, so this file — which
// only needs those geometry types — compiles cross-platform for the Godot layer.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The `cölr` (colors) resource is EV Nova's game-wide interface color/layout
// resource — main menu button text colors, main menu font + bright/dim colors,
// shipyard/outfit grid colors, the loading progress bar's position + colors,
// the six main menu button positions, list/escort selection colors, and the
// button font + a handful of animation anchor points (logo, rollover, sliders).
// Only `cölr` #128 ("Colors") exists in the base game and per the Nova Bible
// "only the first cölr resource is loaded."
//
// Byte layout reverse-engineered and verified against the real 244-byte
// resource (`novaswift-extract raw "data/EV Nova" "cölr" 128`), field order taken
// from the Nova Bible ("* The cölr resource"). Every field below was pinned to
// an exact byte offset by walking the Bible's field order end-to-end against
// the raw hex dump — the fields consume the full 244 bytes with no gap or
// overlap, which is strong corroborating evidence the offsets are right.
// Button1x/y..Button6x/y (offsets 114–137) are additionally cross-checked
// against the hardcoded MainMenuAssets.positions array in
// app/NovaSwift/Launcher/AuthenticMainMenuView.swift, where they match exactly.
//
// Colors are 4 bytes 0x00RRGGBB (byte 0 padding), same convention as IntfRes.
// Font names are NUL-padded Mac Roman strings in fixed 64-byte fields (same
// convention as IntfRes's statusFont).
//
// UNCERTAIN: the Bible lists "GridDim" before "GridBright" but doesn't say
// which byte offset is which — we can only observe two colors back-to-back
// at offsets 86 and 90. We assign offset 86 (255,0,0, a saturated highlight
// color) to gridBright and offset 90 (64,64,64, a subdued gray) to gridDim
// based on what those names would plausibly mean for a shipyard/outfit grid,
// but this pairing is a guess, not a confirmed name-to-offset match.

/// The decoded main-menu colors/layout definition.
public struct ColrRes {
    public let id: Int
    public let name: String

    // Button text colors (offsets 0, 4, 8).
    public let buttonUp: NovaColor
    public let buttonDown: NovaColor
    public let buttonGrey: NovaColor

    // Main menu font (offset 12, 64-byte fixed field) + size (offset 76).
    public let menuFont: String
    public let menuFontSize: Int
    // Bright / dim main menu text colors (offsets 78, 82).
    public let menuColor1: NovaColor
    public let menuColor2: NovaColor

    // Shipyard/outfit dialog grid colors (offsets 86, 90) — see UNCERTAIN note above.
    public let gridBright: NovaColor
    public let gridDim: NovaColor

    // Loading progress bar rect, relative to the center of the window (offset 94),
    // and its colors (offsets 102, 106, 110).
    public let progressBar: NovaRect
    public let progBright: NovaColor
    public let progDim: NovaColor
    public let progOutline: NovaColor

    /// The six main-menu button top-left positions (offsets 114–137), relative to
    /// the top-left corner of a 1024×768 main menu background. Confirmed against
    /// AuthenticMainMenuView.swift's MainMenuAssets.positions.
    public let buttonPositions: [CGPoint]

    // Floating hyperspace map / escort menu border color (offset 138).
    public let floatingMap: NovaColor
    // List colors (offsets 142, 146, 150) + escort menu item hilite (offset 154).
    public let listText: NovaColor
    public let listBkgnd: NovaColor
    public let listHilite: NovaColor
    public let escortHilite: NovaColor

    // Button font (offset 158, 64-byte fixed field) + size (offset 222).
    public let buttonFont: String
    public let buttonFontSz: Int

    // Animation anchor points (offsets 224–243).
    public let logo: CGPoint
    public let rollover: CGPoint
    public let slide1: CGPoint
    public let slide2: CGPoint
    public let slide3: CGPoint

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
        func point(_ off: Int) -> CGPoint {
            CGPoint(x: i16(off), y: i16(off + 2))
        }
        func fixedString(_ off: Int, length: Int) -> String {
            guard off < d.count else { return "" }
            let end = min(d.startIndex + off + length, d.endIndex)
            let bytes = d[(d.startIndex + off)..<end].prefix { $0 != 0 }
            return String(data: Data(bytes), encoding: .macOSRoman) ?? ""
        }

        buttonUp   = color(0)
        buttonDown = color(4)
        buttonGrey = color(8)

        menuFont     = fixedString(12, length: 64)
        menuFontSize = i16(76)
        menuColor1   = color(78)
        menuColor2   = color(82)

        gridBright = color(86)
        gridDim    = color(90)

        progressBar = rect(94)
        progBright  = color(102)
        progDim     = color(106)
        progOutline = color(110)

        buttonPositions = (0..<6).map { point(114 + $0 * 4) }

        floatingMap  = color(138)
        listText     = color(142)
        listBkgnd    = color(146)
        listHilite   = color(150)
        escortHilite = color(154)

        buttonFont   = fixedString(158, length: 64)
        buttonFontSz = i16(222)

        logo      = point(224)
        rollover  = point(228)
        slide1    = point(232)
        slide2    = point(236)
        slide3    = point(240)
    }
}

public extension NovaGame {
    /// The main-menu color/layout definition (id 128 = "Colors", the only one in the base game).
    func colr(_ id: Int = 128) -> ColrRes? {
        resources.resource(NovaType.colr, id).map(ColrRes.init)
    }
}
