import SwiftUI
import NovaSwiftKit

/// Authentic EV Nova dialog chrome for the screens the game itself presents as
/// dialogs over the title backdrop (new-pilot name entry, scenario select) and
/// for the port's own additions (pilot roster, About, Import).
///
/// It is a **true overlay**: a translucent scrim dims whatever UI is already on
/// screen (the real main menu shows through), and the panel — the game's
/// stretchable mission-panel frame (PICTs 8521/8522/8523: metal border, black
/// interior, grey control strip) with three-slice buttons (`NovaButton`) in the
/// strip — floats centred over it. It does **not** paint its own copy of the
/// title screen (which read as a second, emptier background menu).
///
/// The panel is a **fixed `width` and hugs its content's height**. When game
/// graphics aren't available (no data imported / demo), it degrades to a clean
/// dark panel with system-style buttons so the flow still works.
struct NovaDialog<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var width: CGFloat = 460
    var buttons: [NovaDialogButton]
    @ViewBuilder var content: () -> Content

    private var graphics: SpaceportGraphics? { model.uiGraphics }

    var body: some View {
        ZStack {
            // Scrim over the existing UI — this is a dialog floating over the
            // menu, not a replacement backdrop.
            Color.black.opacity(0.55).ignoresSafeArea()

            // Hug the content when it fits; fall back to a scrolling body only
            // when the card would be taller than the screen (a long About on a
            // short landscape iPhone, say). `ViewThatFits` picks the first
            // variant that fits vertically — so short dialogs stay compact and
            // tall ones stay fully on-screen and closable, with no downscaling,
            // so the text stays crisp. Width is capped to `width` but shrinks on
            // a narrow phone; the 12pt padding keeps it clear of the edges.
            ViewThatFits(in: .vertical) {
                card(scrolls: false)
                card(scrolls: true)
            }
            .frame(maxWidth: width)
            .padding(12)
        }
    }

    /// One card variant. `scrolls` wraps the body in a `ScrollView` so an
    /// over-tall dialog scrolls instead of overflowing; the footer strip stays
    /// pinned below it either way.
    private func card(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if scrolls {
                ScrollView { dialogBody }
            } else {
                dialogBody
            }

            // Footer buttons live on the panel art's own grey control strip.
            HStack(spacing: 10) {
                Spacer()
                ForEach(buttons) { b in footerButton(b) }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        .background(NovaPanelBackground(graphics: graphics, modern: model.settings.modernDialogs))
    }

    private var dialogBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
    }

    /// The game's real three-slice button art when graphics are loaded; a
    /// clean pill fallback (amber for the default action) before data import.
    @ViewBuilder private func footerButton(_ b: NovaDialogButton) -> some View {
        if let graphics, !model.settings.modernDialogs {
            NovaButton(graphics: graphics, title: b.title,
                       width: max(50, CGFloat(b.title.count) * 8), enabled: b.enabled) {
                model.audio.play(.uiSelect)
                b.action()
            }
        } else {
            Button { model.audio.play(.uiSelect); b.action() } label: {
                Text(b.title)
                    .novaFont(.button)
                    .foregroundStyle(!b.enabled ? Color(white: 0.45)
                                     : (b.isDefault ? .black : .white))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(
                        Capsule().fill(
                            b.isDefault
                            ? LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)],
                                             startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                             startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(!b.enabled)
        }
    }
}

/// Dialog chrome for the port's own **scrollable, native-control** surfaces
/// (Settings, the Plug-in hub) that can't live inside `NovaDialog`'s
/// content-hugging panel. Like `NovaDialog` it's a **true overlay** — a scrim
/// dims the UI already on screen — but the panel is a **fixed-size centred
/// card** (not a full-window takeover) whose Form/List scrolls inside it, with
/// an amber title header and a Done button on the panel's grey control strip.
struct DialogChrome<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var onClose: () -> Void = {}
    @ViewBuilder var content: () -> Content

    /// Comfortable design size the content is laid out at, then uniformly scaled
    /// to fit the viewport. Laying out at a fixed roomy size (rather than the raw
    /// screen) is what lets a phone show the *whole* Form/List — every row, the
    /// tab picker, the Done button — just shrunk to fit, instead of native-size
    /// rows where only two or three are visible.
    private let designW: CGFloat = 660
    private let designH: CGFloat = 620

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()

                // Deterministic downscale: compare the design size to the usable
                // viewport (capped to the real screen, less a margin). No content
                // measurement — so it can't silently fail to shrink the way the
                // old preference-based fit did, which is why these dialogs used
                // to overflow on iPhone.
                let boundW = min(geo.size.width, Self.screenSize.width)
                let boundH = min(geo.size.height, Self.screenSize.height)
                let availW = max(1, boundW - 28)
                let availH = max(1, boundH - 28)
                let scale = min(1, min(availW / designW, availH / designH))

                card
                    .frame(width: designW, height: designH)
                    .background(NovaPanelBackground(graphics: model.uiGraphics, modern: model.settings.modernDialogs))
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// The dialog's fixed-size body — header, scrollable content, Done strip.
    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            HStack {
                Spacer()
                doneButton
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }

    /// Hard ceiling on the usable space, whatever a parent claims to offer.
    private static var screenSize: CGSize {
        #if os(iOS)
        return UIScreen.main.bounds.size
        #else
        return CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        #endif
    }

    /// The game's real three-slice Done button when data is loaded (matching
    /// every other dialog); a plain amber pill only before any data import.
    @ViewBuilder private var doneButton: some View {
        if let graphics = model.uiGraphics, !model.settings.modernDialogs {
            NovaButton(graphics: graphics, title: "Done", width: 60) { onClose() }
        } else {
            Button { onClose() } label: {
                Text("Done").novaFont(.button, weight: .semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 7)
                    .background(Capsule().fill(novaAmber))
            }
            .buttonStyle(.plain)
        }
    }
}

/// The game's own stretchable dialog frame, shared by `NovaDialog` and
/// `DialogChrome`: PICTs 8521 (top cap, 9px), 8522 (middle, stretches with
/// content) and 8523 (bottom cap, 40px — the grey strip footer controls sit
/// on). Native width is 441; small horizontal stretches of the brushed-metal
/// border are imperceptible. Falls back to a plain dark card before data import.
struct NovaPanelBackground: View {
    let graphics: SpaceportGraphics?
    /// Nova Swift presentation: use the port's own modern chrome (metal border +
    /// space-blue "screen" interior) instead of the authentic PICT frame.
    var modern: Bool = false

    var body: some View {
        if modern {
            ModernDialogPanel()
        } else if let g = graphics,
           let top = g.pict(8521), let middle = g.pict(8522), let bottom = g.pict(8523) {
            VStack(spacing: 0) {
                Image(decorative: top, scale: 1).resizable().frame(height: 9)
                Image(decorative: middle, scale: 1).resizable()
                Image(decorative: bottom, scale: 1).resizable().frame(height: 40)
            }
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
        }
    }
}

/// The Nova Swift modern dialog chrome: a brushed-steel border framing a deep
/// space-blue "screen" interior with a faint wave/scanline sheen — the look the
/// port aims for in modern mode (metal frame, blue screen). Fully vector so it
/// stays crisp at any dialog size.
struct ModernDialogPanel: View {
    private let corner: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
            .fill(
                LinearGradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.15),
                                        Color(red: 0.05, green: 0.11, blue: 0.24)],
                               startPoint: .top, endPoint: .bottom)
            )
            // Screen glow from the top, like a lit console.
            .overlay(
                RadialGradient(colors: [Color(red: 0.15, green: 0.35, blue: 0.6).opacity(0.35), .clear],
                               center: .top, startRadius: 0, endRadius: 340)
                    .clipShape(shape)
            )
            // Faint waves so the interior reads as a screen, not flat fill.
            .overlay(waves.clipShape(shape).allowsHitTesting(false))
            // Inner hairline + brushed-steel outer border.
            .overlay(shape.inset(by: 3).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color(white: 0.82), Color(white: 0.34),
                                            Color(white: 0.62), Color(white: 0.26)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 3.5)
            )
            .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
    }

    /// A few low-amplitude sine waves, drawn faintly across the interior.
    private var waves: some View {
        Canvas { ctx, size in
            for (i, yFrac) in [0.34, 0.54, 0.74].enumerated() {
                var path = Path()
                let baseY = size.height * yFrac
                let amp = 5.0 + Double(i) * 2.5
                path.move(to: CGPoint(x: 0, y: baseY))
                var x = 0.0
                while x <= size.width {
                    let y = baseY + sin(x / 40 + Double(i) * 1.3) * amp
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 6
                }
                ctx.stroke(path, with: .color(Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.06)),
                           lineWidth: 1)
            }
        }
    }
}

/// A dialog footer button (authentic three-slice when data is present).
struct NovaDialogButton: Identifiable {
    let id = UUID()
    let title: String
    var isDefault = false
    var enabled = true
    let action: () -> Void
}

/// The EV Nova UI accent used for headings in the port's authentic screens.
let novaAmber = Color(red: 1.0, green: 0.7, blue: 0.28)

/// A Geneva-styled single-line text field matching the game's dialog inputs.
struct NovaTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder)
            .font(.custom(NovaFontRole.body.family, size: NovaFontRole.body.baseSize)).foregroundColor(.secondary))
            .textFieldStyle(.plain)
            .novaFont(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.3)))
    }
}

/// A selectable row inside a dialog (scenario / option lists), authentically
/// styled: Geneva text with a highlight bar for the selected row.
struct NovaSelectRow<Detail: View>: View {
    let title: String
    let selected: Bool
    /// Optional leading glyph (e.g. for a category/menu list) — tinted to
    /// match the row's text color. `nil` (the default) omits it entirely, so
    /// existing scenario/option-list call sites are unaffected.
    var systemImage: String? = nil
    @ViewBuilder var detail: () -> Detail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(selected ? .black : .white)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    NovaText(title, size: 13, color: selected ? .black : .white, weight: .bold)
                    detail()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? novaAmber : Color(white: 0.14),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
