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
/// **Button-label mapping is inferred, not stored in the resource fork.**
/// Every item here is a custom-drawn `userItem`; the original engine chose
/// labels at runtime and the DITL only records rects. The one block of
/// exactly six adjacent `STR# 150` entries that thematically fits a
/// plunder/boarding action list is indices 40-45: "Cargo", "Credits",
/// "Ammo", "Energy", "Capture Ship", "Demand Tribute" (confirmed via
/// `novaswift-extract raw "data/EV Nova" 'STR#' 150`) — six labels for six
/// buttons. The two long labels ("Capture Ship", "Demand Tribute") land on
/// this dialog's two widest slots (126px, 146px); the four short resource
/// names fill the four 89px slots. Which of the four short names sits in
/// which 89px slot is arbitrary (all four fit any of the four slots) — assigned
/// here in DITL reading order (top row left-to-right, then row 2) purely for
/// a stable, legible default. Callers needing a different assignment can
/// still reuse this view; the labels are all parameters.
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
    var onDemandTribute: () -> Void
    var onDismiss: () -> Void

    /// PICT #8515 "Plunder" (`Nova Graphics 3.rez`) — not added to
    /// `SpaceportGraphics.Frame` per instructions; a local constant instead.
    private static let framePictID = 8515
    fileprivate static let frameSize = CGSize(width: 309, height: 198)

    private var hasCargo: Bool { cargoLines.contains { $0.amount != "0" } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if let graphics, let frame = graphics.pict(Self.framePictID) {
                NovaMenu(frame: frame, overlay: true) { space in
                    manifest.ditlPlace(space, left: 11, top: 7)
                    // Row 1: Cargo / Credits / Ammo
                    button(graphics, "Cargo", width: 63, enabled: hasCargo, action: onTakeCargo)
                        .ditlPlace(space, left: 16, top: 110)
                    button(graphics, "Credits", width: 63, enabled: creditsAboard > 0, action: onTakeCredits)
                        .ditlPlace(space, left: 110, top: 110)
                    button(graphics, "Ammo", width: 63, enabled: ammoAboard > 0, action: onTakeAmmo)
                        .ditlPlace(space, left: 204, top: 110)
                    // Row 2: Energy / Demand Tribute
                    button(graphics, "Energy", width: 63, enabled: energyAboard > 0, action: onTakeEnergy)
                        .ditlPlace(space, left: 35, top: 138)
                    button(graphics, "Demand Tribute", width: 120, enabled: true, action: onDemandTribute)
                        .ditlPlace(space, left: 129, top: 138)
                    // Row 3: Capture Ship (isolated, bottom-centered)
                    button(graphics, "Capture Ship", width: 100, enabled: captureChance != nil, action: onCaptureShip)
                        .ditlPlace(space, left: 91, top: 166)
                }
            } else {
                fallbackPanel
            }
        }
        .novaResponsive()
    }

    @ViewBuilder
    private func button(_ graphics: SpaceportGraphics, _ title: String, width: CGFloat,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        NovaButton(graphics: graphics, title: title, width: width, enabled: enabled, action: action)
    }

    /// Item [4]: the disabled 287×96 readout — target name, cargo manifest,
    /// then a credits/ammo/energy summary line, all real data from the
    /// caller (no invented sample commodities baked into the view itself).
    private var manifest: some View {
        VStack(alignment: .leading, spacing: 3) {
            NovaText(targetName, size: 12, color: novaAmber, weight: .bold)
            if cargoLines.isEmpty {
                NovaText("Cargo hold is empty.", size: 11, color: Color(white: 0.6))
            } else {
                ForEach(cargoLines) { line in
                    HStack {
                        NovaText(line.label, size: 11, width: 180)
                        NovaText(line.amount, size: 11, width: 80, align: .trailing)
                    }
                }
            }
            Divider().overlay(Color(white: 0.3))
            NovaText("\(creditsAboard) cr · \(ammoAboard) ammo · \(energyAboard) energy",
                     size: 10, color: Color(white: 0.65))
        }
        .padding(6)
        .frame(width: 287, height: 96, alignment: .topLeading)
        .background(Color.black.opacity(0.55))
        .clipped()
    }

    // MARK: Fallback (no loaded PICT/button art — demo/no-data path)

    private var fallbackPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(targetName).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
            if cargoLines.isEmpty {
                Text("Cargo hold is empty.").novaFont(.body).foregroundStyle(Color(white: 0.6))
            } else {
                ForEach(cargoLines) { line in
                    HStack {
                        Text(line.label).novaFont(.body).foregroundStyle(.white)
                        Spacer()
                        Text(line.amount).novaFont(.body).foregroundStyle(.white)
                    }
                }
            }
            Text("\(creditsAboard) cr · \(ammoAboard) ammo · \(energyAboard) energy")
                .novaFont(.caption).foregroundStyle(Color(white: 0.65))
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                fallbackButton("Cargo", enabled: hasCargo, action: onTakeCargo)
                fallbackButton("Credits", enabled: creditsAboard > 0, action: onTakeCredits)
                fallbackButton("Ammo", enabled: ammoAboard > 0, action: onTakeAmmo)
                fallbackButton("Energy", enabled: energyAboard > 0, action: onTakeEnergy)
                fallbackButton("Demand Tribute", enabled: true, action: onDemandTribute)
                fallbackButton("Capture Ship", enabled: captureChance != nil, action: onCaptureShip)
            }
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
    }

    private func fallbackButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).novaFont(.button).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// `.novaPlace` takes a frame-centre offset (`cx, cy`); DITL rects give
/// top-left pixel coordinates. This converts directly at the call site so
/// each button above can cite its real DITL `left`/`top` verbatim instead of
/// pre-subtracted numbers.
private extension View {
    func ditlPlace(_ space: NovaSpace, left: CGFloat, top: CGFloat) -> some View {
        novaPlace(space, left - PlunderView.frameSize.width / 2, top - PlunderView.frameSize.height / 2)
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
        onCaptureShip: {}, onDemandTribute: {}, onDismiss: {})
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
        onCaptureShip: {}, onDemandTribute: {}, onDismiss: {})
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}
