import SwiftUI
import NovaSwiftKit

/// The game-wide interface palette + fonts, resolved once from the player's
/// `cölr` #128 resource so a total-conversion plug-in that recolours the UI
/// fully applies to the port's native chrome — buttons, list rows, the
/// shipyard/outfit grid, the loading progress bar, and the escort/map borders.
///
/// This is the `cölr` counterpart to `AuthenticHUDStyle`/`IntfRes` (the flight
/// HUD's own theme): `IntfRes` skins the in-flight status bar, `NovaUITheme`
/// skins everything else. Each field falls back to the value the chrome used
/// before it was data-driven, so a missing/partial `cölr` (or a preview with no
/// game loaded) keeps today's look.
struct NovaUITheme: Equatable {
    // Spaceport button label colors (cölr.buttonUp/Down/Grey → NovaMenu labels).
    var buttonUp: Color
    var buttonDown: Color
    var buttonGrey: Color

    // Shipyard/outfit grid tile borders (cölr.gridBright selected / gridDim not).
    var gridBright: Color
    var gridDim: Color

    // List rows (cölr.listText/listBkgnd/listHilite → trade list).
    var listText: Color
    var listBkgnd: Color
    var listHilite: Color

    // Loading progress bar (cölr.progBright fill / progDim track / progOutline).
    var progBright: Color
    var progDim: Color
    var progOutline: Color

    // Floating hyperspace-map border + escort-menu selection (cölr.floatingMap/escortHilite).
    var floatingMap: Color
    var escortHilite: Color

    /// The `cölr` button font family (buttonFont), resolved to something
    /// registered (imported Geneva, or the bundled fallback) — `nil` leaves the
    /// role's own family. Applied to the authentic three-slice buttons.
    /// (cölr.menuFont has no text target here — our main-menu labels are PICT
    /// art, not rendered text — so it's decoded in `ColrRes` but not carried.)
    var buttonFont: String?

    /// The look each field had before `cölr` drove it — used whole when no `cölr`
    /// decodes, and per-field whenever a colour decodes to pure black (0,0,0),
    /// which for a text/hilite/border colour is far more likely a zeroed/edge
    /// decode than an intentional "paint it invisible on a black panel".
    static let fallback = NovaUITheme(
        buttonUp: .white,
        buttonDown: Color(white: 0.5),
        buttonGrey: Color(white: 0.15),
        gridBright: Color(red: 1, green: 0, blue: 0),
        gridDim: Color(white: 0.25),
        listText: .white,
        listBkgnd: .clear,
        listHilite: Color.white.opacity(0.14),
        progBright: novaAmber,
        progDim: Color(white: 0.05),
        progOutline: Color(white: 0.30),
        floatingMap: novaAmber.opacity(0.25),
        escortHilite: novaAmber.opacity(0.16),
        buttonFont: nil)

    init(buttonUp: Color, buttonDown: Color, buttonGrey: Color,
         gridBright: Color, gridDim: Color,
         listText: Color, listBkgnd: Color, listHilite: Color,
         progBright: Color, progDim: Color, progOutline: Color,
         floatingMap: Color, escortHilite: Color,
         buttonFont: String?) {
        self.buttonUp = buttonUp; self.buttonDown = buttonDown; self.buttonGrey = buttonGrey
        self.gridBright = gridBright; self.gridDim = gridDim
        self.listText = listText; self.listBkgnd = listBkgnd; self.listHilite = listHilite
        self.progBright = progBright; self.progDim = progDim; self.progOutline = progOutline
        self.floatingMap = floatingMap; self.escortHilite = escortHilite
        self.buttonFont = buttonFont
    }

    init(colr: ColrRes?) {
        guard let c = colr else { self = .fallback; return }
        let f = NovaUITheme.fallback
        // A cölr colour, unless it decoded to pure black — then the field's own
        // fallback, so a zeroed byte range can't paint the UI invisible.
        func col(_ nc: NovaColor, _ fb: Color) -> Color {
            (nc.r == 0 && nc.g == 0 && nc.b == 0)
                ? fb
                : Color(red: Double(nc.r) / 255, green: Double(nc.g) / 255, blue: Double(nc.b) / 255)
        }
        // A named cölr font, resolved to something actually registered (else nil,
        // leaving the consuming role's own family). Geneva/Charcoal round-trip to
        // the bundled fallbacks via NovaFontFallback the same way ïntf.statusFont does.
        func font(_ name: String) -> String? {
            let t = name.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let resolved = NovaFontFallback.resolve(t, fallback: NovaFontRole.button.family)
            return NovaFontAvailability.isAvailable(resolved) ? resolved : nil
        }
        self.init(
            buttonUp: col(c.buttonUp, f.buttonUp),
            buttonDown: col(c.buttonDown, f.buttonDown),
            buttonGrey: col(c.buttonGrey, f.buttonGrey),
            gridBright: col(c.gridBright, f.gridBright),
            gridDim: col(c.gridDim, f.gridDim),
            listText: col(c.listText, f.listText),
            // listBkgnd is legitimately black in the base game (the list sits on
            // the frame's own black panel), so a black decode here means "let the
            // frame show through" — keep the .clear fallback rather than painting
            // an opaque box over the chrome.
            listBkgnd: col(c.listBkgnd, f.listBkgnd),
            listHilite: col(c.listHilite, f.listHilite),
            progBright: col(c.progBright, f.progBright),
            progDim: col(c.progDim, f.progDim),
            progOutline: col(c.progOutline, f.progOutline),
            floatingMap: col(c.floatingMap, f.floatingMap),
            escortHilite: col(c.escortHilite, f.escortHilite),
            buttonFont: font(c.buttonFont))
    }
}

private struct NovaUIThemeKey: EnvironmentKey {
    static let defaultValue: NovaUITheme = .fallback
}

extension EnvironmentValues {
    /// The active `cölr` interface theme. Injected once at `RootView` from
    /// `AppModel.uiTheme`; chrome views read it instead of hardcoding colours.
    var novaTheme: NovaUITheme {
        get { self[NovaUIThemeKey.self] }
        set { self[NovaUIThemeKey.self] = newValue }
    }
}
