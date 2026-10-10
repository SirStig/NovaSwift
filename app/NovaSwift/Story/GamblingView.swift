import SwiftUI
import AVKit
import NovaSwiftKit
import NovaSwiftStory

/// The Bar's Gambling screen — the real "Galaxy Racing Network" holovid betting
/// game, not an invented mini-game. Confirmed authentic from the base data
/// itself: `STR# 150` #11/14/15 are literally "Gamble"/"Bet 1000"/"Bet 5000";
/// PICT 8529 is the "You're tuned to GRN: Galaxy Racing Network — Choose your
/// color for the next race" chooser backdrop; PICTs 8530-8533 are the four
/// contestant colors (Blue/Green/Yellow/Red) and 8550-8553 their "<Color> Wins"
/// banners; and the base install ships four holovid clips, `Race 1.mov`
/// through `Race 4.mov`, each one visually confirmed (via its opening frame)
/// to show that same color's ship leading — i.e. race outcome `n` plays
/// `Race n.mov`. The rules are the original's (`FUN_0047dc50`, EC-26; see
/// `LandedServices.RaceBet`): the standard wager is `min(credits, 1000)`, the
/// typed amount is capped at `min(credits, 10000)`, a win pays four times the
/// wager, and a race whose first roll repeats the previous winner is a
/// guaranteed loss.
///
/// Layout re-derived from the real dialog resources (`novaswift-extract dlog`/
/// `ditl`, re-verified against the base install, not transcribed):
///  - DITL #1023 "Race" (DLOG bounds 470×230) drives `choosingView`: 4 color
///    boxes, 100×100, at left=13/128/243/357, top=88; 2 buttons, 99×25, at
///    left=129/243, top=196. PICT 8529's own picFrame decodes to
///    (0,0)-(230,470) — an exact pixel match for DLOG #1023's own bounds —
///    confirming it *is* this dialog's backdrop, not a generic banner (the
///    prior 90×90 color boxes were an approximation; the real ones are 100×100).
///  - DITL #1015 "Gamble" (DLOG bounds 251×214) drives `resultView`: two rows
///    of four 56×48 boxes, a 238×48 text item, and 3 buttons, 75×25, at
///    left=6/87/169, top=182. No matching-size backdrop PICT turned up
///    anywhere near the racing PICT range, so this one has no frame art —
///    just real item positions on a plain panel. The two box rows are put to
///    use rather than left blank: the top row shows the actual outcome
///    (winner in its "win state" PICT 8550-8553, the rest "disabled"
///    8560-8563) and the bottom row echoes the player's own pick in its
///    "clicked" state (8540-8543) — real, otherwise-unused assets from the
///    same 8530/8540/8550/8560 button-state family the chooser already uses.
///  - Every item in both DITLs is a bare, unlabeled `userItem`, so which rect
///    is "Leave" vs "Bet 1000" vs "Bet Again" isn't recoverable from the
///    resource itself; it's inferred left-to-right in reading order (Leave
///    leftmost, ascending stakes/primary action to its right), matching this
///    port's pre-existing choice of labels.
///  - Racing (holovid playback) has no corresponding DITL — the base game's
///    movie presumably drew into a plain custom rect the resource fork
///    doesn't describe — so that phase keeps a reasonable, undocumented size.
struct GamblingView: View {
    let graphics: SpaceportGraphics
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    @EnvironmentObject private var model: AppModel

    private enum RaceColor: Int, CaseIterable {
        case blue = 1, green = 2, yellow = 3, red = 4
        var name: String {
            switch self {
            case .blue: return "Blue"
            case .green: return "Green"
            case .yellow: return "Yellow"
            case .red: return "Red"
            }
        }
    }

    private enum Phase { case choosing, racing, result }

    @State private var selectedColor: RaceColor?
    @State private var stake: Int = 0
    @State private var phase: Phase = .choosing
    @State private var winner: RaceColor?
    @State private var player: AVPlayer?
    /// Bumped per race so the racing-phase watchdog (`.task(id:)`) restarts for
    /// each new bet rather than reusing the previous run.
    @State private var raceID = 0
    @State private var showAmountPrompt = false
    /// The previous race's winner, kept for the app's lifetime like the
    /// original's global (it is not saved).
    @MainActor private static var raceBet = LandedServices.RaceBet()
    @State private var payout = 0

    var body: some View {
        Group {
            switch phase {
            case .choosing: choosingView
            case .racing:   racingView
            case .result:   resultView
            }
        }
        .sheet(isPresented: $showAmountPrompt) { amountPrompt }
    }

    // MARK: Choosing — DITL #1023 "Race" against the real 470×230 PICT 8529 frame

    private var choosingView: some View {
        Group {
            if let bg = graphics.pict(8529) {
                // `overlay: true`: gambling stacks over the bar (which provides
                // the dim backdrop), it doesn't black out the whole screen.
                // Rects resolve through DITL #1023 (stock rects as fallback).
                let d = DITLPlacement(graphics.game, 1023, frame: bg)
                NovaMenu(frame: bg, overlay: true) { space in
                    ForEach(RaceColor.allCases, id: \.rawValue) { colorButton($0, space, d) }
                    // Items 1/0: (129,196)-(228,221), (243,196)-(342,221), 99×25.
                    let bet1 = d.rect(1, top: 196, left: 129, bottom: 221, right: 228)
                    stakeButton(graphics.buttonLabel(SpaceportLabel.bet1000, fallback: "Bet 1000"), bet1) {
                        placeBet(LandedServices.RaceBet.standardWager(credits: pilot.state.credits))
                    }
                    .ditlPlace(space, d, bet1)
                    // The original's modifier-key bet: type any amount up to
                    // min(credits, 10000).
                    let bet = d.rect(0, top: 196, left: 243, bottom: 221, right: 342)
                    stakeButton(graphics.buttonLabel(SpaceportLabel.bet, fallback: "Bet"), bet) {
                        showAmountPrompt = true
                    }
                    .ditlPlace(space, d, bet)
                    // DITL #1023 defines no credits/Leave items; they share the
                    // real button row (y=196) flanking the two stake buttons —
                    // INSIDE the 230px-tall frame (the old cy=106/128 spots put
                    // Leave past the frame's bottom edge, floating on nothing).
                    NovaText(pilot.state.credits.creditsAbbreviated, size: 10,
                             color: Color(red: 1, green: 0.85, blue: 0.4), width: 100, align: .center)
                        .novaPlace(space, -222, 88)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                               width: 73, action: onDone)
                        .novaPlace(space, 122, 81)
                }
            } else {
                fallbackChoosing
            }
        }
    }

    // DITL #1023 items 2-5: (13,88)-(113,188), (128,88)-(228,188),
    // (243,88)-(343,188), (357,88)-(457,188) — 100×100 each.
    private static let colorBox: [RaceColor: (index: Int, left: CGFloat)] =
        [.blue: (2, 13), .green: (3, 128), .yellow: (4, 243), .red: (5, 357)]

    private func colorButton(_ color: RaceColor, _ space: NovaSpace, _ d: DITLPlacement) -> some View {
        let box = Self.colorBox[color] ?? (2, 13)
        let rect = d.rect(box.index, x: box.left, y: 88, w: 100, h: 100)
        let clicked = selectedColor == color
        let picID = (clicked ? 8540 : 8530) + (color.rawValue - 1)
        return Button {
            selectedColor = color
        } label: {
            Group {
                if let img = graphics.pict(picID) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                } else {
                    Text(color.name).foregroundStyle(.white)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(clicked ? Color.yellow.opacity(0.85) : Color.clear, lineWidth: 3))
        }
        .buttonStyle(.novaPlain)
        .ditlPlace(space, d, rect)
    }

    private func stakeButton(_ label: String, _ rect: CGRect, action: @escaping () -> Void) -> some View {
        NovaButton(graphics: graphics, title: label, ditl: rect,
                   enabled: selectedColor != nil && pilot.state.credits > 0, action: action)
    }

    /// STR# 2002 #372 "Amount to bet:", capped at min(credits, 10000).
    private var amountPrompt: some View {
        let cap = max(1, LandedServices.RaceBet.maxPromptedWager(credits: pilot.state.credits))
        return TradeQuantityPrompt(title: graphics.game.stringList(2002)?.string(at: 372) ?? "Amount to bet:",
                                   range: 1...cap, initial: min(1000, cap), unitLabel: "credits",
                                   onConfirm: { amount in showAmountPrompt = false; placeBet(amount) },
                                   onCancel: { showAmountPrompt = false })
    }

    private var fallbackChoosing: some View {
        VStack(spacing: 14) {
            Text("Galaxy Racing Network").foregroundStyle(.white)
            Text("Choose your color for the next race").foregroundStyle(Color(white: 0.7))
            HStack(spacing: 10) {
                ForEach(RaceColor.allCases, id: \.rawValue) { color in
                    Button(color.name) { selectedColor = color }
                        .novaBorderedButton()
                        .tint(selectedColor == color ? .yellow : nil)
                }
            }
            HStack(spacing: 10) {
                Button(graphics.buttonLabel(SpaceportLabel.bet1000, fallback: "Bet 1000")) {
                    placeBet(LandedServices.RaceBet.standardWager(credits: pilot.state.credits))
                }
                .novaProminentButton()
                .disabled(selectedColor == nil || pilot.state.credits < 1)
                Button(graphics.buttonLabel(SpaceportLabel.bet, fallback: "Bet")) { showAmountPrompt = true }
                    .novaProminentButton()
                    .disabled(selectedColor == nil || pilot.state.credits < 1)
            }
            Text("You Have: \(pilot.state.credits.creditsAbbreviated)").foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            Button(graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"), action: onDone).novaBorderedButton()
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .novaResponsive()
        .shrinkToFitViewport()
    }

    private func placeBet(_ amount: Int) {
        guard let pick = selectedColor, amount > 0, pilot.state.credits >= amount else { return }
        stake = amount
        pilot.state.credits -= amount
        let race = Self.raceBet.race(pick: pick.rawValue - 1, wager: amount) { Int.random(in: 0..<$0) }
        payout = race.payout
        let winIndex = race.winner + 1
        winner = RaceColor(rawValue: winIndex)
        if let url = model.data.raceVideoURL(index: winIndex) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            player = nil
        }
        raceID += 1
        phase = .racing
    }

    // MARK: Racing — no corresponding DITL; the holovid itself is dynamic content

    private var racingView: some View {
        VStack(spacing: 14) {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: 440, height: 260)
                    .onReceive(NotificationCenter.default.publisher(
                        for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
                        finishRace()
                    }
                    // A clip that can't be decoded fires this instead of the
                    // "did play to end" note — treat it the same, don't hang.
                    .onReceive(NotificationCenter.default.publisher(
                        for: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)) { _ in
                        finishRace()
                    }
            } else {
                ProgressView().frame(width: 440, height: 260)
            }
            NovaButton(graphics: graphics, title: "Skip", width: 42, action: finishRace)
        }
        .padding(24)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        // No `.novaResponsive()` here: its GeometryReader greedily fills the
        // screen and pins this fixed-size card to the top-left corner. The card
        // has no ambient NovaText to scale anyway, so drop it and let
        // `shrinkToFitViewport` (which fills *and centres*) place the dialog.
        .shrinkToFitViewport()
        // Safety net so the holovid can never sit on a spinner forever: advance
        // to the result on decode failure, on a missing clip, or after a hard
        // time cap — see `watchRace`. Re-runs each time we (re-)enter racing.
        .task(id: raceID) { await watchRace() }
    }

    /// Backstop for the racing phase. The four base clips run ~4.5s and normally
    /// end via `.AVPlayerItemDidPlayToEndTime`; this guarantees the screen still
    /// advances if that never arrives — the clip stalls, can't be decoded, or
    /// wasn't found on disk at all (`player == nil`).
    private func watchRace() async {
        guard let item = player?.currentItem else {
            // No clip resolved (e.g. base data imported before the holovids were
            // copied in). Don't sit on a spinner — show the outcome promptly.
            try? await Task.sleep(nanoseconds: 800_000_000)
            finishRace()
            return
        }
        // ~8s cap (comfortably past the ~4.5s clips); break out early the moment
        // the item reports a hard decode failure.
        for _ in 0..<32 {
            if phase != .racing { return }
            if item.status == .failed { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        finishRace()
    }

    private func finishRace() {
        guard phase == .racing else { return }
        player?.pause()
        pilot.state.credits += payout   // a win pays four times the wager (STR# 2002 #370)
        phase = .result
    }

    // MARK: Result — DITL #1015 "Gamble", 251×214, no backdrop art of its own

    private var resultView: some View {
        // DLOG/DITL #1015 from the loaded data: the panel takes the DLOG size
        // and each item its DITL rect (stock values as fallback).
        let stock = DITLPlacement(graphics.game, 1015, window: CGSize(width: 251, height: 214))
        let d = DITLPlacement(graphics.game, 1015, window: stock.windowSize)
        return BareNovaPanel(size: d.window) { space in
            resultBoxes(space, d)
            if let winner {
                // Item 11: (6,125)-(244,173), 238×48.
                let line = d.rect(11, top: 125, left: 6, bottom: 173, right: 244)
                NovaText(winner == selectedColor
                         ? "\(graphics.game.stringList(2002)?.string(at: 370) ?? "Your winnings"): \(payout.creditsAbbreviated)"
                         : "\(winner.name) wins — you lose \(stake.creditsAbbreviated).",
                         size: 12,
                         color: winner == selectedColor ? Color(red: 0.5, green: 0.9, blue: 0.5) : Color(red: 1, green: 0.5, blue: 0.5),
                         width: line.width, align: .center)
                    .ditlPlace(space, d, line)
            }
            // Item 10 (leftmost, 6,182): Leave. Item 0 (rightmost, 169,182): Bet
            // Again. Item 1 (middle, 87,182) repurposed as the credits readout
            // rather than a third, unneeded button — all 3 real rects still used.
            let leave = d.rect(10, top: 182, left: 6, bottom: 207, right: 81)
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                       ditl: leave, action: onDone)
                .ditlPlace(space, d, leave)
            let credits = d.rect(1, top: 182, left: 87, bottom: 207, right: 162)
            NovaText(pilot.state.credits.creditsAbbreviated, size: 10,
                     color: Color(red: 1, green: 0.85, blue: 0.4), width: credits.width, align: .center)
                .ditlPlace(space, d, credits.offsetBy(dx: 0, dy: 4))
            let again = d.rect(0, top: 182, left: 169, bottom: 207, right: 244)
            NovaButton(graphics: graphics, title: "Bet Again", ditl: again, action: resetForNextRace)
                .ditlPlace(space, d, again)
        }
    }

    // DITL #1015 items 2-9 (56×48 each, x shared by both rows): top row
    // (items 2-5, y=5) is the real outcome; bottom row (items 6-9, y=67)
    // echoes the player's pick.
    private static let resultBoxLeft: [RaceColor: CGFloat] = [.blue: 6, .green: 67, .yellow: 128, .red: 189]

    private func resultBoxes(_ space: NovaSpace, _ d: DITLPlacement) -> some View {
        ForEach(RaceColor.allCases, id: \.rawValue) { color in
            let left = Self.resultBoxLeft[color] ?? 6
            let top = d.rect(1 + color.rawValue, x: left, y: 5, w: 56, h: 48)
            let pick = d.rect(5 + color.rawValue, x: left, y: 67, w: 56, h: 48)
            Group {
                if let img = graphics.pict(winner == color ? (8549 + color.rawValue) : (8559 + color.rawValue)) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(width: top.width, height: top.height)
                        .ditlPlace(space, d, top)
                }
                if selectedColor == color, let img = graphics.pict(8539 + color.rawValue) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(width: pick.width, height: pick.height)
                        .ditlPlace(space, d, pick)
                }
            }
        }
    }

    private func resetForNextRace() {
        selectedColor = nil; stake = 0; payout = 0; winner = nil; player = nil; phase = .choosing
    }

}

/// A frame-less, real-geometry panel for dialogs with no matching-size
/// backdrop PICT (DITL #1015 "Gamble" — see `GamblingView`'s header comment):
/// the same `NovaSpace`/`.novaPlace` coordinate contract and reference-scale
/// behavior as `NovaMenu` (`app/NovaSwift/Spaceport/NovaMenu.swift`), just
/// without an `Image` layer underneath.
private struct BareNovaPanel<Content: View>: View {
    let size: CGSize
    var maxScale: CGFloat = 2.6
    @Environment(\.novaDebugEnabled) private var novaDebug
    @ViewBuilder var content: (NovaSpace) -> Content

    var body: some View {
        let space = NovaSpace(width: size.width, height: size.height)
        GeometryReader { geo in
            let scale = novaFrameScale(frame: size, viewport: geo.size, maxScale: maxScale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15))
                content(space).novaTextScale(1)
                if novaDebug { NovaDebugGrid.forSpace(space) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .cursorScaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        // No opaque background — this panel overlays the bar screen, which
        // already dims what's behind it (matching NovaMenu's overlay mode).
    }
}
