import SwiftUI
import AVKit
import EVNovaKit

/// The Bar's Gambling screen — the real "Galaxy Racing Network" holovid betting
/// game, not an invented mini-game. Confirmed authentic from the base data
/// itself: `STR# 150` #11/14/15 are literally "Gamble"/"Bet 1000"/"Bet 5000";
/// PICT 8529 is the "You're tuned to GRN: Galaxy Racing Network — Choose your
/// color for the next race" chooser backdrop; PICTs 8530-8533 are the four
/// contestant colors (Blue/Green/Yellow/Red) and 8550-8553 their "<Color> Wins"
/// banners; and the base install ships four holovid clips, `Race 1.mov`
/// through `Race 4.mov`, each one visually confirmed (via its opening frame)
/// to show that same color's ship leading — i.e. race outcome `n` plays
/// `Race n.mov`. The one thing genuinely undocumented anywhere (Bible or the
/// vendored NovaJS port, which implements neither) is the exact payout — no
/// odds/multiplier are recorded — so a 3× return on a correct pick (net +2×
/// the stake) is this port's own reasonable choice, not a ported value.
///
/// Layout re-derived from the real dialog resources (`evnova-extract dlog`/
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

    var body: some View {
        switch phase {
        case .choosing: choosingView
        case .racing:   racingView
        case .result:   resultView
        }
    }

    // MARK: Choosing — DITL #1023 "Race" against the real 470×230 PICT 8529 frame

    private var choosingView: some View {
        Group {
            if let bg = graphics.pict(8529) {
                NovaMenu(frame: bg) { space in
                    ForEach(RaceColor.allCases, id: \.rawValue) { colorButton($0, space) }
                    // Items 1/0: (129,196)-(228,221), (243,196)-(342,221), 99×25 —
                    // cx = itemLeft − 235, cy = 196 − 115 = 81.
                    stakeButton(1000, label: graphics.buttonLabel(SpaceportLabel.bet1000, fallback: "Bet 1000"))
                        .novaPlace(space, -106, 81)
                    stakeButton(5000, label: graphics.buttonLabel(SpaceportLabel.bet5000, fallback: "Bet 5000"))
                        .novaPlace(space, 8, 81)
                    // No DITL #1023 item covers credits/Leave — placed just below
                    // the real 4-box/2-button layout rather than invented mid-art.
                    NovaText(creditsLabel(pilot.state.credits), size: 12,
                             color: Color(red: 1, green: 0.85, blue: 0.4), width: 200, align: .center)
                        .novaPlace(space, -100, 106)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                               width: 42, action: onDone)
                        .novaPlace(space, -21, 128)
                }
            } else {
                fallbackChoosing
            }
        }
    }

    // DITL #1023 items 2-5: (13,88)-(113,188), (128,88)-(228,188),
    // (243,88)-(343,188), (357,88)-(457,188) — 100×100 each; cx = itemLeft − 235.
    private static let colorBoxCX: [RaceColor: CGFloat] = [.blue: -222, .green: -107, .yellow: 8, .red: 122]

    private func colorButton(_ color: RaceColor, _ space: NovaSpace) -> some View {
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
            .frame(width: 100, height: 100)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(clicked ? Color.yellow.opacity(0.85) : Color.clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .novaPlace(space, Self.colorBoxCX[color] ?? 0, -27)
    }

    private func stakeButton(_ amount: Int, label: String) -> some View {
        NovaButton(graphics: graphics, title: label, width: 73,
                   enabled: selectedColor != nil && pilot.state.credits >= amount) {
            placeBet(amount)
        }
    }

    private var fallbackChoosing: some View {
        VStack(spacing: 14) {
            Text("Galaxy Racing Network").foregroundStyle(.white)
            Text("Choose your color for the next race").foregroundStyle(Color(white: 0.7))
            HStack(spacing: 10) {
                ForEach(RaceColor.allCases, id: \.rawValue) { color in
                    Button(color.name) { selectedColor = color }
                        .buttonStyle(.bordered)
                        .tint(selectedColor == color ? .yellow : nil)
                }
            }
            HStack(spacing: 10) {
                Button(graphics.buttonLabel(SpaceportLabel.bet1000, fallback: "Bet 1000")) { placeBet(1000) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedColor == nil || pilot.state.credits < 1000)
                Button(graphics.buttonLabel(SpaceportLabel.bet5000, fallback: "Bet 5000")) { placeBet(5000) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedColor == nil || pilot.state.credits < 5000)
            }
            Text("You Have: \(creditsLabel(pilot.state.credits))").foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            Button(graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"), action: onDone).buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .novaResponsive()
    }

    private func placeBet(_ amount: Int) {
        guard selectedColor != nil, pilot.state.credits >= amount else { return }
        stake = amount
        pilot.state.credits -= amount
        pilot.save()
        let winIndex = Int.random(in: 1...4)
        winner = RaceColor(rawValue: winIndex)
        if let url = model.data.raceVideoURL(index: winIndex) {
            player = AVPlayer(url: url)
            player?.play()
        }
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
            } else {
                ProgressView().frame(width: 440, height: 260)
            }
            NovaButton(graphics: graphics, title: "Skip", width: 42, action: finishRace)
        }
        .padding(24)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .novaResponsive()
    }

    private func finishRace() {
        guard phase == .racing else { return }
        player?.pause()
        if winner == selectedColor { pilot.state.credits += stake * 3 }   // win: 3× stake back (net +2×)
        pilot.save()
        phase = .result
    }

    // MARK: Result — DITL #1015 "Gamble", 251×214, no backdrop art of its own

    private var resultView: some View {
        BareNovaPanel(size: CGSize(width: 251, height: 214)) { space in
            resultBoxes(space)
            if let winner {
                NovaText(winner == selectedColor
                         ? "You win \(creditsLabel(stake * 3))!"
                         : "\(winner.name) wins — you lose \(creditsLabel(stake)).",
                         size: 12,
                         color: winner == selectedColor ? Color(red: 0.5, green: 0.9, blue: 0.5) : Color(red: 1, green: 0.5, blue: 0.5),
                         width: 238, align: .center)
                    // Item 11: (6,125)-(244,173), 238×48 — cx = 6 − 125.5, cy = 125 − 107.
                    .novaPlace(space, -119.5, 18)
            }
            // Item 10 (leftmost, 6,182): Leave. Item 0 (rightmost, 169,182): Bet
            // Again. Item 1 (middle, 87,182) repurposed as the credits readout
            // rather than a third, unneeded button — all 3 real rects still used.
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"), width: 49, action: onDone)
                .novaPlace(space, -119.5, 75)
            NovaText(creditsLabel(pilot.state.credits), size: 10,
                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 75, align: .center)
                .novaPlace(space, -38.5, 79)
            NovaButton(graphics: graphics, title: "Bet Again", width: 49, action: resetForNextRace)
                .novaPlace(space, 43.5, 75)
        }
    }

    // DITL #1015 items 2-9 (56×48 each, x shared by both rows): top row
    // (items 2-5, y=5) is the real outcome; bottom row (items 6-9, y=67)
    // echoes the player's pick. cx = itemLeft − 125.5.
    private static let resultBoxCX: [RaceColor: CGFloat] = [.blue: -119.5, .green: -58.5, .yellow: 2.5, .red: 63.5]

    private func resultBoxes(_ space: NovaSpace) -> some View {
        ForEach(RaceColor.allCases, id: \.rawValue) { color in
            Group {
                if let img = graphics.pict(winner == color ? (8549 + color.rawValue) : (8559 + color.rawValue)) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(width: 56, height: 48)
                        .novaPlace(space, Self.resultBoxCX[color] ?? 0, -102)
                }
                if selectedColor == color, let img = graphics.pict(8539 + color.rawValue) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(width: 56, height: 48)
                        .novaPlace(space, Self.resultBoxCX[color] ?? 0, -40)
                }
            }
        }
    }

    private func resetForNextRace() {
        selectedColor = nil; stake = 0; winner = nil; player = nil; phase = .choosing
    }

    private func creditsLabel(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}

/// A frame-less, real-geometry panel for dialogs with no matching-size
/// backdrop PICT (DITL #1015 "Gamble" — see `GamblingView`'s header comment):
/// the same `NovaSpace`/`.novaPlace` coordinate contract and reference-scale
/// behavior as `NovaMenu` (`app/EVNova/Spaceport/NovaMenu.swift`), just
/// without an `Image` layer underneath.
private struct BareNovaPanel<Content: View>: View {
    let size: CGSize
    var maxScale: CGFloat = 2.2
    @ViewBuilder var content: (NovaSpace) -> Content

    var body: some View {
        let space = NovaSpace(width: size.width, height: size.height)
        GeometryReader { geo in
            let scale = min(min(geo.size.width / 1024, geo.size.height / 768), maxScale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15))
                content(space).novaTextScale(1)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
