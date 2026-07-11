import SwiftUI

/// The pilot dossier's "Escorts" panel — an authentic-geometry recreation of
/// DLOG/DITL #1022 "Escorts", the game's real in-flight escort management
/// window (re-verified this pass: `novaswift-extract dlog "data/EV Nova/Nova.rez" 1022`
/// → bounds 424×259; `novaswift-extract ditl ... 1022` → 12 items, all
/// `userItem`/`statText`, no native controls, so the item rects ARE the exact
/// pixel layout). Its frame art is PICT #8513 "Escort communications" in
/// `Nova Graphics 3.rez` — confirmed (not assumed) by decoding it and reading
/// the PICT's own bounding rect out of the header: `(0,0)-(259,424)`, an exact
/// match for the DLOG bounds.
///
/// Items 0–3 (four 146×26 buttons, x 29–175) and 9–11 (the two side info
/// panels + the 200×200 display panel) all fall inside that 424×259 art.
/// Items 4 and 8 (a 200×25 field and its "Ship Identifier" `statText` label)
/// sit *below* it — top ≥304, past the 259-tall frame — the same "plain strip
/// below the decorated chrome" split seen in DITL #1007 "Communications"
/// (whose own items 3–8 overflow its 215-tall frame the same way), so they're
/// drawn here in a plain lower strip rather than on the art. Items 5–7 are
/// three more 200×25 rects that mutually overlap by up to 28px and weren't
/// called out by the prior research pass either — almost certainly List
/// Manager bookkeeping rects rather than distinct visible controls — so
/// they're deliberately not rendered rather than guessed at.
///
/// No escort hire/dismiss/roster data model exists anywhere in the codebase
/// (checked `Sources/NovaSwiftEngine`, `NovaSwiftKit`, `NovaSwiftStory`: `AIBrain` has
/// only the *AI-side* "escort a fleet leader" formation-flying state, and
/// `Fleet`/`Spawner` only spawn NPC escort fleets — nothing tracks escorts the
/// *player* has hired). So this is deliberately the EMPTY STATE only: correct
/// panel/button geometry, "No escorts hired." in the display panel, every
/// control disabled. A real hire/dismiss mechanic is a follow-up gameplay
/// feature, not UI.
///
/// This can't reach the live `SpaceportGraphics` the other authentic screens
/// use — that comes from `AppModel` via `@EnvironmentObject`, and this view's
/// call site (`StoryGuideView`'s Pilot tab, plus its `#Preview`) isn't wired
/// with that environment and is out of scope to change here. So — matching
/// `HailDialogView`'s own documented no-graphics branch — it degrades to
/// plain chrome: Geneva text (`NovaText`) and grey pill buttons instead of the
/// three-slice PICT art, but the exact same `NovaSpace`/`.novaPlace` pixel
/// coordinates as every authentic screen.
struct EscortsView: View {
    // PICT #8513's own decoded size — the coordinate origin every item below
    // is placed relative to (frame-centre, top-left anchored; see NovaMenu.swift).
    private static let frameW: CGFloat = 424
    private static let frameH: CGFloat = 259
    private let space = NovaSpace(width: frameW, height: frameH)

    // Full footprint including the plain lower strip for items 4/8 (bottom
    // edge of item 8 lands at absolute y≈331; see type doc).
    private static let totalW: CGFloat = 424
    private static let totalH: CGFloat = 340

    var body: some View {
        ZStack(alignment: .topLeading) {
            art

            // Item 9: (14,9)-(206,67) 192×58 — target/escort identity panel.
            sidePanel(width: 192, height: 58) {
                NovaText("No escort selected", size: 11, color: Color(white: 0.5))
            }
            .novaPlace(space, -198, -120.5)

            // Item 11: (14,79)-(206,131) 192×52 — status readout panel.
            sidePanel(width: 192, height: 52) {
                NovaText("—", size: 11, color: Color(white: 0.4))
            }
            .novaPlace(space, -198, -50.5)

            // Item 10: (217,30)-(417,230) 200×200 — the big ship display; the
            // one item explicitly `[disabled]` on its own in the DITL, and
            // the natural home for the empty-state message.
            sidePanel(width: 200, height: 200, amber: true) {
                VStack(spacing: 6) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(white: 0.45))
                    NovaText("No escorts hired.", size: 12, color: Color(white: 0.6),
                              width: 160, align: .center)
                }
            }
            .novaPlace(space, 5, -99.5)

            // Items 2,3,1,0 top-to-bottom (146×26 each, x 29–175) — the four
            // escort-command buttons. All disabled: nothing is selected to command.
            commandButton("Aggressive").novaPlace(space, -183, 11.5)
            commandButton("Defensive").novaPlace(space, -183, 39.5)
            commandButton("Evasive").novaPlace(space, -183, 67.5)
            commandButton("Hold Position").novaPlace(space, -183, 95.5)

            // Item 8: (38,315)-(150,331) 112×16 `statText`, `[disabled]` in the
            // DITL itself — its real label text, "Ship Identifier".
            NovaText("Ship Identifier", size: 10, color: Color(white: 0.4))
                .novaPlace(space, -174, 185.5)

            // Item 4: (5,304)-(205,329) 200×25 — the identifier field itself.
            fieldPlaceholder.novaPlace(space, -207, 174.5)
        }
        .frame(width: Self.totalW, height: Self.totalH, alignment: .topLeading)
        .background(Color(white: 0.07))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(novaAmber.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Stand-in for PICT #8513 itself (see type doc for why the real art
    /// isn't decoded at this call site): a dark plate the same 424×259
    /// footprint, so every item lands where the real frame would put it.
    private var art: some View {
        Rectangle().fill(Color(white: 0.1))
            .frame(width: Self.frameW, height: Self.frameH)
    }

    @ViewBuilder
    private func sidePanel<Content: View>(width: CGFloat, height: CGFloat, amber: Bool = false,
                                          @ViewBuilder content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder((amber ? novaAmber : Color.white).opacity(amber ? 0.25 : 0.12)))
    }

    private var fieldPlaceholder: some View {
        Rectangle().fill(Color.black.opacity(0.3))
            .frame(width: 200, height: 25)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.25)))
    }

    /// A 146×26 command button in the disabled/grey state — the real chrome
    /// is the game's three-slice button art (`NovaButton`, PICTs 7500–7508)
    /// but that needs live `SpaceportGraphics`; see type doc.
    private func commandButton(_ title: String) -> some View {
        Text(title)
            .novaFont(.button)
            .foregroundStyle(Color(white: 0.45))
            .frame(width: 146, height: 26)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(white: 0.26)))
    }
}

#Preview("Escorts") {
    EscortsView()
        .padding(20)
        .background(Color.black)
}
