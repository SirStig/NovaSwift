import SwiftUI

/// EV Nova's typography, centralized: which of the game's two original fonts
/// (Charcoal for chrome/titles, Geneva for everything else — the classic Mac OS
/// 8 "Charcoal" appearance pairing the game itself used) a role renders in, its
/// base point size at the 1024×768 design reference, and its shrink-to-fit
/// behavior. `Font.custom` falls back to a system font automatically if the
/// named font isn't registered yet (e.g. before any data is imported — see
/// `GameDataController.registerFonts(from:)`), so no extra guarding is needed
/// here.
enum NovaFontRole {
    case title      // Charcoal — large screen/app titles
    case heading    // Charcoal — dialog titles, section headers
    case body       // Geneva — descriptions, list rows, field text
    case caption    // Geneva — secondary/meta text, footnotes
    case button     // Geneva — button/action labels
    case hud        // Geneva — HUD/status-bar numeric readouts

    var family: String {
        switch self {
        case .title, .heading: return "Charcoal"
        case .body, .caption, .button, .hud: return "Geneva"
        }
    }

    /// Point size at 1× (the game's 1024×768 design space).
    var baseSize: CGFloat {
        switch self {
        case .title:   return 24
        case .heading: return 18
        case .body:    return 11
        case .caption: return 9
        case .button:  return 12
        case .hud:     return 12
        }
    }

    /// Fixed-width chrome (titles, buttons, HUD readouts) shrinks to fit on one
    /// line rather than clipping; paragraph text (body/caption) wraps instead —
    /// shrinking multi-line text hurts readability more than it helps fitting.
    var shrinksToFit: Bool {
        switch self {
        case .title, .heading, .button, .hud: return true
        case .body, .caption: return false
        }
    }
}

private struct NovaTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The device-responsive scale ambient text should render at. Set once per
    /// screen (see `NovaCanvas`, `NovaMenu`, `.novaResponsive()`) — individual
    /// `.novaFont()` call sites just consume it.
    var novaTextScale: CGFloat {
        get { self[NovaTextScaleKey.self] }
        set { self[NovaTextScaleKey.self] = newValue }
    }
}

extension View {
    /// Injects an explicit device-responsive text scale for this subtree.
    func novaTextScale(_ scale: CGFloat) -> some View {
        environment(\.novaTextScale, scale)
    }

    /// The reusable "how big is 1024×768 in the space we've got" formula
    /// `NovaMenu` already uses for its whole-tree `.scaleEffect`, exposed here
    /// for the screens that have no `NovaCanvas`/`NovaMenu` container of their
    /// own (dialogs, HUD overlays, launcher/settings chrome) so their text can
    /// still scale between a small phone and a large desktop window.
    func novaResponsive(maxScale: CGFloat = 2.2) -> some View {
        GeometryReader { geo in
            let scale = min(min(geo.size.width / 1024, geo.size.height / 768), maxScale)
            self.novaTextScale(scale)
        }
    }
}

private struct NovaFontModifier: ViewModifier {
    @Environment(\.novaTextScale) private var scale
    let role: NovaFontRole
    let weight: Font.Weight
    let baseSize: CGFloat

    func body(content: Content) -> some View {
        let size = (baseSize * scale).clamped(to: baseSize * 0.5...baseSize * 2.2)
        let styled = content.font(.custom(role.family, size: size).weight(weight))
        if role.shrinksToFit {
            styled.lineLimit(1).minimumScaleFactor(0.55)
        } else {
            styled
        }
    }
}

extension View {
    /// Applies EV Nova's authentic typography for `role`, scaled for the
    /// current device/window via the ambient `novaTextScale`. `size` overrides
    /// the role's default base size for one-off display treatments (e.g. the
    /// launcher's oversized hero title) while still sharing the role's font
    /// family and shrink-to-fit behavior.
    func novaFont(_ role: NovaFontRole, weight: Font.Weight = .regular, size: CGFloat? = nil) -> some View {
        modifier(NovaFontModifier(role: role, weight: weight, baseSize: size ?? role.baseSize))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
