import SwiftUI
import NovaSwiftKit

/// A single line of loot in the manifest readout (`PlunderView`'s cargo
/// panel) — one row of cargo, or the credits/ammo/energy summary lines.
struct PlunderLine: Identifiable {
    let id = UUID()
    let label: String
    let amount: String
}

/// The in-flight "Plunder Dialog" — `DLOG`/`DITL` #1011 in `Nova.rez`,
/// verified with `novaswift-extract dlog/ditl "data/EV Nova/Nova.rez" 1011`:
///
///     DLOG #1011  bounds=(40,40)-(349,238)  309x198
///     DITL #1011 "Plunder Dialog"
///       [4] ( 11,  7)-(298,103) 287x96  userItem [disabled]  ← manifest readout
///       [5] ( 16,110)-(105,135)  89x25  userItem              ← row 1, left
///       [1] (110,110)-(199,135)  89x25  userItem              ← row 1, mid
///       [3] (204,110)-(293,135)  89x25  userItem              ← row 1, right
///       [2] ( 35,138)-(124,163)  89x25  userItem              ← row 2, left
///       [6] (129,138)-(275,163) 146x25  userItem              ← row 2, wide
///       [0] ( 91,166)-(217,191) 126x25  userItem              ← row 3, centered
///
/// Backdrop is real game art: PICT #8515 "Plunder" in `Nova Graphics 3.rez`
/// decodes to exactly 309×198 — the same size as the DLOG bounds, confirming
/// it as this dialog's frame (not a guess). Item [4] is `[disabled]`, i.e. a
/// non-interactive readout, not a list you pick rows from — consistent with
/// there being no per-row "Take" control anywhere in the DITL.
///
/// **Button-label mapping confirmed against a real gameplay screenshot and
/// the EVN wiki's Boarding article.** The wiki lists this dialog's actions
/// as: Energy, Cargo, Ammo, Credits, Capture Ship, Abort — six actions for
/// six buttons, with no "Demand Tribute" (that's a planet-tribute action,
/// unrelated to ship boarding — see [[novaswift-domination]]). A screenshot
/// of the original game confirms:
///   - Item [5] (top row, left, 89px) is "Energy".
///   - The isolated bottom item [0] (126px) is the short label "Abort", not
///     "Capture Ship" — it's a real, always-enabled dismiss button, not just
///     tap-outside-to-close.
///   - The wide item [6] (146px) fits "Capture Ship" — the only other
///     multi-word label besides "Abort"'s neighbor-block cousin "Demand
///     Tribute" (`STR# 150`, confirmed via
///     `novaswift-extract raw "data/EV Nova" 'STR#' 150`), which the
///     screenshot rules out for this dialog.
/// The remaining three 89px slots ([1], [3], [2]) take Cargo/Credits/Ammo;
/// their relative order among themselves is not resolvable from a single
/// screenshot (all three were disabled — empty hold/no ammo/no credits — in
/// the reference image) and is assigned here in DITL reading order.
struct PlunderView: View {
    /// Nil in the no-game-data path — falls back to plain chrome, same
    /// degrade-gracefully behavior as `HailDialogView`.
    let graphics: SpaceportGraphics?
    let targetName: String
    let cargoLines: [PlunderLine]
    let creditsAboard: Int
    let ammoAboard: Int
    let energyAboard: Int
    /// Percent chance of a successful capture, or nil if this hull can't be
    /// captured at all (the "Capture Ship" button is disabled either way).
    let captureChance: Int?

    var onTakeCargo: () -> Void
    var onTakeCredits: () -> Void
    var onTakeAmmo: () -> Void
    var onTakeEnergy: () -> Void
    var onCaptureShip: () -> Void
    /// A greyed button was pressed: the original sounds snd 153
    /// (NovaUi_RunBoardingPlunderWindow 0x00482940).
    var onRefused: () -> Void = {}
    var onDismiss: () -> Void

    /// PICT #8515 "Plunder" (`Nova Graphics 3.rez`) — not added to
    /// `SpaceportGraphics.Frame` per instructions; a local constant instead.
    private static let framePictID = 8515

    private var hasCargo: Bool { cargoLines.contains { $0.amount != "0" } }
    private var totalCargoTons: Int { cargoLines.compactMap { Int($0.amount) }.reduce(0, +) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if let graphics, let frame = graphics.pict(Self.framePictID) {
                // Rects resolve through DITL #1011 (stock rects as fallback) so a
                // plug-in's replacement DITL moves and resizes the controls.
                let d = DITLPlacement(graphics.game, 1011, frame: frame)
                NovaMenu(frame: frame, overlay: true) { space in
                    let panel = d.rect(4, top: 7, left: 11, bottom: 103, right: 298)
                    manifest(panel.size).ditlPlace(space, d, panel)
                    // Row 1: Energy / Cargo / Credits
                    ditlButton(graphics, space, d, d.rect(5, top: 110, left: 16, bottom: 135, right: 105),
                               "Energy", enabled: energyAboard > 0, action: onTakeEnergy)
                    ditlButton(graphics, space, d, d.rect(1, top: 110, left: 110, bottom: 135, right: 199),
                               "Cargo", enabled: hasCargo, action: onTakeCargo)
                    ditlButton(graphics, space, d, d.rect(3, top: 110, left: 204, bottom: 135, right: 293),
                               "Credits", enabled: creditsAboard > 0, action: onTakeCredits)
                    // Row 2: Ammo / Capture Ship
                    ditlButton(graphics, space, d, d.rect(2, top: 138, left: 35, bottom: 163, right: 124),
                               "Ammo", enabled: ammoAboard > 0, action: onTakeAmmo)
                    ditlButton(graphics, space, d, d.rect(6, top: 138, left: 129, bottom: 163, right: 275),
                               "Capture Ship", enabled: captureChance != nil, action: onCaptureShip)
                    // Row 3: Abort (isolated, bottom-centered)
                    ditlButton(graphics, space, d, d.rect(0, top: 166, left: 91, bottom: 191, right: 217),
                               "Abort", enabled: true, action: onDismiss)
                }
            } else {
                fallbackPanel
            }
        }
        .novaResponsive()
    }

    /// A three-slice button filling DITL rect `rect` (the caps are 13 px each,
    /// so the middle spans the rest).
    private func ditlButton(_ graphics: SpaceportGraphics, _ space: NovaSpace, _ d: DITLPlacement,
                            _ rect: CGRect, _ title: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        NovaButton(graphics: graphics, title: title, width: max(0, rect.width - 26),
                   enabled: enabled, onRefused: onRefused, action: action)
            .ditlPlace(space, d, rect)
    }

    /// Item [4]: the disabled 287×96 readout. Title and the "Cargo:"/"Ammo:"/
    /// "Capture Odds:" labels are the real game's own text — verbatim from
    /// `STR# 2002` ("misc strings"), confirmed via
    /// `novaswift-extract raw "data/EV Nova" 'STR#' 2002`:
    ///
    ///     Select what to plunder from this ship:.Cargo:.Ammo:.Capture Odds:
    ///
    /// No "Credits:" or "Energy:" label exists anywhere in the game's string
    /// tables — EV Nova never prefixes a credits/energy amount with a label,
    /// it's always a bare "<n> credits"/"<n> energy" — so those two stay an
    /// unlabeled summary line, same as before. A screenshot of the original
    /// dialog also shows a "Capture Odds: 33 (Unregistered)" row — "odds
    /// computed, but blocked because the pilot isn't a registered citizen"
    /// (a real capture precondition per the wiki's Matt Burch capture-formula
    /// writeup). This engine doesn't model pilot registration status, so the
    /// row is only shown when `captureChance` is non-nil, without that
    /// qualifier.
    private func manifest(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            NovaText("Select what to plunder from this ship:", size: 11, color: novaAmber, weight: .bold)
            manifestRow("Cargo:", hasCargo ? "\(totalCargoTons) tons" : "None")
            manifestRow("Ammo:", ammoAboard > 0 ? "\(ammoAboard)" : "None")
            if let captureChance {
                manifestRow("Capture Odds:", "\(captureChance)%")
            }
            Divider().overlay(Color(white: 0.3))
            NovaText("\(creditsAboard) credits · \(energyAboard) energy",
                     size: 10, color: Color(white: 0.65))
        }
        .padding(6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color.black.opacity(0.55))
        .clipped()
    }

    private func manifestRow(_ label: String, _ value: String) -> some View {
        HStack {
            NovaText(label, size: 11, width: 100)
            NovaText(value, size: 11, width: 100, align: .trailing)
        }
    }

    // MARK: Fallback (no loaded PICT/button art — demo/no-data path)

    private var fallbackPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select what to plunder from this ship:").novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
            HStack { Text("Cargo:").novaFont(.body).foregroundStyle(.white); Spacer()
                     Text(hasCargo ? "\(totalCargoTons) tons" : "None").novaFont(.body).foregroundStyle(.white) }
            HStack { Text("Ammo:").novaFont(.body).foregroundStyle(.white); Spacer()
                     Text(ammoAboard > 0 ? "\(ammoAboard)" : "None").novaFont(.body).foregroundStyle(.white) }
            if let captureChance {
                HStack { Text("Capture Odds:").novaFont(.body).foregroundStyle(.white); Spacer()
                         Text("\(captureChance)%").novaFont(.body).foregroundStyle(.white) }
            }
            Text("\(creditsAboard) credits · \(energyAboard) energy")
                .novaFont(.caption).foregroundStyle(Color(white: 0.65))
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                fallbackButton("Energy", enabled: energyAboard > 0, action: onTakeEnergy)
                fallbackButton("Cargo", enabled: hasCargo, action: onTakeCargo)
                fallbackButton("Credits", enabled: creditsAboard > 0, action: onTakeCredits)
                fallbackButton("Ammo", enabled: ammoAboard > 0, action: onTakeAmmo)
                fallbackButton("Capture Ship", enabled: captureChance != nil, action: onCaptureShip)
                fallbackButton("Abort", enabled: true, action: onDismiss)
            }
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
    }

    private func fallbackButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: enabled ? action : onRefused) {
            Text(title).novaFont(.button).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.novaPlain)
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - Preview

#Preview("Freighter, full hold") {
    PlunderView(
        graphics: nil,
        targetName: "Disabled Freighter",
        cargoLines: [
            PlunderLine(label: "Food", amount: "12"),
            PlunderLine(label: "Industrial Equipment", amount: "8"),
            PlunderLine(label: "Medical Supplies", amount: "4"),
        ],
        creditsAboard: 1250, ammoAboard: 6, energyAboard: 40,
        captureChance: 35,
        onTakeCargo: {}, onTakeCredits: {}, onTakeAmmo: {}, onTakeEnergy: {},
        onCaptureShip: {}, onDismiss: {})
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}

#Preview("Empty hulk") {
    PlunderView(
        graphics: nil,
        targetName: "Disabled Shuttle",
        cargoLines: [],
        creditsAboard: 0, ammoAboard: 0, energyAboard: 0,
        captureChance: nil,
        onTakeCargo: {}, onTakeCredits: {}, onTakeAmmo: {}, onTakeEnergy: {},
        onCaptureShip: {}, onDismiss: {})
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}
