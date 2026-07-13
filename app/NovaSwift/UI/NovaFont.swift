import SwiftUI
import CoreText

/// EV Nova's typography, centralized: which of the game's two original fonts
/// (Charcoal for chrome/titles, Geneva for everything else — the classic Mac OS 8
/// "Charcoal" appearance pairing the game itself used) a role renders in, and how
/// big it gets on the device in front of the player.
///
/// Charcoal and Geneva are Apple's copyrighted fonts, so the app never bundles
/// them — `GameDataController.registerFonts(from:)` registers the genuine
/// article from the player's own imported data. Until then, `family` falls
/// back to `NovaFontFallback`'s bundled free lookalikes (registered at launch
/// by `GameDataController.registerBundledFallbackFonts()`) rather than the
/// plain system font, so chrome and titles still look intentional.
enum NovaFontRole {
    case title      // Charcoal — large screen/app titles
    case heading    // Charcoal — dialog titles, section headers
    case body       // Geneva — descriptions, list rows, field text
    case caption    // Geneva — secondary/meta text, footnotes
    case button     // Geneva — button/action labels
    case hud        // Geneva — HUD/status-bar numeric readouts

    var family: String {
        switch self {
        case .title, .heading: return NovaFontFallback.resolve("Charcoal", fallback: NovaFontFallback.chrome)
        case .body, .caption, .button, .hud: return NovaFontFallback.resolve("Geneva", fallback: NovaFontFallback.text)
        }
    }

    /// The size this role renders at on a desktop-sized window.
    ///
    /// These are *not* the game's 2002 point sizes. EV Nova authored its chrome
    /// for a 1024×768 CRT where 9pt Geneva was a comfortable read; the same 9pt
    /// on a modern display, inside a window that may be a fraction of the screen,
    /// is not. The authentic sizes still govern the *authentic* screens, which
    /// live inside `NovaMenu`'s frame-pixel space and scale with their PICT (see
    /// `NovaText`). This scale governs our own native chrome — launcher,
    /// settings, plug-in store, pilot list — which has no PICT to scale against.
    var baseSize: CGFloat {
        switch self {
        case .title:   return 28
        case .heading: return 20
        case .body:    return 15
        case .caption: return 13
        case .button:  return 15
        case .hud:     return 14
        }
    }

    /// The smallest size this role may ever render at, whatever the window size.
    /// Below roughly 11pt, UI text stops being readable at arm's length; below
    /// 9pt it is decorative. Nothing is allowed past that line.
    var minimumSize: CGFloat {
        switch self {
        case .title:   return 20
        case .heading: return 16
        case .body:    return 13
        case .caption: return 11
        case .button:  return 13
        case .hud:     return 11
        }
    }

    /// The largest size, so a 4K display doesn't render 50pt body copy.
    var maximumSize: CGFloat { baseSize * 1.6 }
}

/// The free, SIL-OFL-licensed fonts bundled in `Resources/Fonts/` as stand-ins
/// for Charcoal/Geneva — chosen for family resemblance, not pixel-identity:
/// **Rubik** (corner-rounded grotesque) for Charcoal's chrome/titles, and
/// **Arimo** (a Helvetica/Arial-lineage redraw — the same substitution
/// cross-platform font tables historically used for Geneva itself) for body
/// text. Registered by `GameDataController.registerBundledFallbackFonts()`.
enum NovaFontFallback {
    static let chrome = "Rubik"
    static let text = "Arimo"
    static let bundledFontFileNames = [chrome, text]

    /// `family` if it's actually registered (real imported font or, first
    /// launch, one of these bundled fallbacks), else `fallback`.
    static func resolve(_ family: String, fallback: String) -> String {
        NovaFontAvailability.isAvailable(family) ? family : fallback
    }
}

/// Whether a font family resolves to itself under CoreText rather than
/// silently substituting — the only reliable way to tell if it's registered.
/// Cached because `NovaFontRole.family` is read on every render; invalidated
/// by `GameDataController.registerFonts`/`registerBundledFallbackFonts` after
/// registering something new.
enum NovaFontAvailability {
    private static var cache: [String: Bool] = [:]

    static func isAvailable(_ family: String) -> Bool {
        if let cached = cache[family] { return cached }
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        let resolved = (CTFontCopyFamilyName(font) as String) == family
        cache[family] = resolved
        return resolved
    }

    static func reset() { cache.removeAll() }
}

private struct NovaTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct NovaUIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct NovaHUDFontFamilyKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The device-responsive scale ambient text should render at. Set once per
    /// screen (see `NovaCanvas`, `NovaMenu`, `.novaResponsive()`) — individual
    /// `.novaFont()` call sites just consume it.
    var novaTextScale: CGFloat {
        get { self[NovaTextScaleKey.self] }
        set { self[NovaTextScaleKey.self] = newValue }
    }

    /// The player's global "Overall UI scale" accessibility setting (0.8…1.4),
    /// injected once at the app root. Multiplied into every `.novaFont()` size on
    /// top of the device scale, so all port chrome text grows/shrinks with it.
    var novaUIScale: CGFloat {
        get { self[NovaUIScaleKey.self] }
        set { self[NovaUIScaleKey.self] = newValue }
    }

    /// A font family that overrides the `.hud` role's default (Geneva) for its
    /// subtree — the mechanism by which the flight HUD honors a plug-in's
    /// `ïntf.statusFont`. `nil` (the default everywhere else) leaves `.hud`
    /// rendering in Geneva. Only `.hud` consults this; every other role keeps
    /// its own family, so setting it can't bleed into unrelated chrome.
    var novaHUDFontFamily: String? {
        get { self[NovaHUDFontFamilyKey.self] }
        set { self[NovaHUDFontFamilyKey.self] = newValue }
    }
}

extension View {
    /// Injects an explicit device-responsive text scale for this subtree.
    func novaTextScale(_ scale: CGFloat) -> some View {
        environment(\.novaTextScale, scale)
    }

    /// Scale our own native chrome for the space it has.
    ///
    /// This deliberately does **not** reuse `min(w/1024, h/768)` — the formula
    /// `NovaMenu` uses to fit a 1024×768 game canvas. On an iPhone that formula
    /// evaluates to ~0.4, which turned 9pt caption text into 4.5pt. A phone is
    /// *smaller*, so its text must be relatively *larger*, not smaller. Native
    /// chrome reflows instead of scaling, so it only needs a gentle nudge up on
    /// genuinely large displays, clamped hard at both ends by the role.
    func novaResponsive(maxScale: CGFloat = 1.6) -> some View {
        GeometryReader { geo in
            let reference: CGFloat = 1440   // a typical desktop window width
            let raw = geo.size.width / reference
            let scale = min(max(raw, 1.0), maxScale)
            self.novaTextScale(scale)
        }
    }
}

private struct NovaFontModifier: ViewModifier {
    @Environment(\.novaTextScale) private var scale
    @Environment(\.novaUIScale) private var uiScale
    @Environment(\.novaHUDFontFamily) private var hudFamily
    let role: NovaFontRole
    let weight: Font.Weight
    let baseSize: CGFloat
    let minimumSize: CGFloat
    let maximumSize: CGFloat

    func body(content: Content) -> some View {
        // The role's readable min/max floor/ceiling apply to the device-scaled
        // size; the player's global UI-scale then multiplies on top so it can go
        // beyond those bounds intentionally.
        let size = (baseSize * scale).clamped(to: minimumSize...maximumSize) * uiScale
        // Only the HUD role defers to a plug-in-supplied family (ïntf.statusFont);
        // every other role keeps its own so the override can't leak into chrome.
        let family = (role == .hud ? hudFamily : nil) ?? role.family
        content.font(.custom(family, size: size).weight(weight))
    }
}

extension View {
    /// Applies EV Nova's authentic typography for `role`, sized for the current
    /// device/window via the ambient `novaTextScale` and floored at the role's
    /// readable minimum. `size` overrides the role's default base size for
    /// one-off display treatments (e.g. the launcher's oversized hero title)
    /// while still sharing the role's font family.
    ///
    /// Note there is deliberately no blanket `lineLimit(1).minimumScaleFactor()`
    /// here. Applying it to every title, button, and HUD readout let each label
    /// silently shrink to a different size to fit its own box, so nothing on a
    /// screen shared a baseline or a cap height. Labels that genuinely must fit
    /// one line should say so at the call site.
    func novaFont(_ role: NovaFontRole, weight: Font.Weight = .regular, size: CGFloat? = nil) -> some View {
        let base = size ?? role.baseSize
        // An explicit size override scales its own floor/ceiling with it, so a
        // hero title doesn't get clamped down to the shared `.title` maximum.
        let ratio = base / role.baseSize
        return modifier(NovaFontModifier(role: role, weight: weight, baseSize: base,
                                         minimumSize: role.minimumSize * ratio,
                                         maximumSize: role.maximumSize * ratio))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
