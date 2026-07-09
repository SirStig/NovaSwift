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
        Group {
            switch phase {
            case .choosing: choosingView
            case .racing:   racingView
            case .result:   resultView
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .novaResponsive()
    }

    // MARK: Choosing

    private var choosingView: some View {
        VStack(spacing: 14) {
            if let bg = graphics.pict(8529) {
                Image(decorative: bg, scale: 1).resizable().scaledToFit().frame(height: 110)
            } else {
                Text("Galaxy Racing Network").novaFont(.heading).foregroundStyle(.white)
                Text("Choose your color for the next race").novaFont(.body).foregroundStyle(Color(white: 0.7))
            }
            HStack(spacing: 10) {
                ForEach(RaceColor.allCases, id: \.rawValue) { colorButton($0) }
            }
            HStack(spacing: 10) {
                stakeButton(1000, label: graphics.buttonLabel(SpaceportLabel.bet1000, fallback: "Bet 1000"))
                stakeButton(5000, label: graphics.buttonLabel(SpaceportLabel.bet5000, fallback: "Bet 5000"))
            }
            Text("You Have: \(creditsLabel(pilot.state.credits))")
                .novaFont(.body).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            Button("Leave", action: onDone).buttonStyle(.bordered)
        }
    }

    private func colorButton(_ color: RaceColor) -> some View {
        Button { selectedColor = color } label: {
            Group {
                if let img = graphics.pict(8529 + color.rawValue) {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                } else {
                    Text(color.name).foregroundStyle(.white)
                }
            }
            .frame(width: 90, height: 90)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selectedColor == color ? Color.yellow : Color.white.opacity(0.2), lineWidth: 3))
        }
        .buttonStyle(.plain)
    }

    private func stakeButton(_ amount: Int, label: String) -> some View {
        Button(label) { placeBet(amount) }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.75, green: 0.15, blue: 0.15))
            .disabled(selectedColor == nil || pilot.state.credits < amount)
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

    // MARK: Racing

    private var racingView: some View {
        VStack(spacing: 14) {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .onReceive(NotificationCenter.default.publisher(
                        for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
                        finishRace()
                    }
            } else {
                ProgressView().frame(height: 260)
            }
            Button("Skip", action: finishRace).buttonStyle(.bordered)
        }
    }

    private func finishRace() {
        guard phase == .racing else { return }
        player?.pause()
        if winner == selectedColor { pilot.state.credits += stake * 3 }   // win: 3× stake back (net +2×)
        pilot.save()
        phase = .result
    }

    // MARK: Result

    private var resultView: some View {
        VStack(spacing: 14) {
            if let winner, let img = graphics.pict(8549 + winner.rawValue) {
                Image(decorative: img, scale: 1).resizable().scaledToFit().frame(width: 160, height: 160)
            }
            if let winner {
                Text(winner == selectedColor ? "You win \(creditsLabel(stake * 3))!" : "\(winner.name) wins — you lose \(creditsLabel(stake)).")
                    .novaFont(.heading, weight: .bold)
                    .foregroundStyle(winner == selectedColor ? Color(red: 0.5, green: 0.9, blue: 0.5) : Color(red: 1, green: 0.5, blue: 0.5))
            }
            Text("You Have: \(creditsLabel(pilot.state.credits))")
                .novaFont(.body).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            HStack(spacing: 10) {
                Button("Bet Again", action: resetForNextRace).buttonStyle(.borderedProminent)
                Button("Leave", action: onDone).buttonStyle(.bordered)
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
