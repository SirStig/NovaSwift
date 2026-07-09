import SwiftUI
import EVNovaKit

/// The Bar's Gambling mini-game. `STR# 150` (button labels) confirms this is
/// authentic to the shipped game — entries 11/14/15 are literally "Gamble",
/// "Bet 1000", "Bet 5000" — but neither the Nova Bible nor the vendored
/// NovaJS port document odds, a resource field, or a dedicated interface
/// PICT for it, so the two fixed stakes are real but the win chance/visuals
/// here are original: a simple, slightly house-favored coin flip, shown as a
/// plain dark panel rather than an authentic frame (none was found in the
/// base data to draw from).
struct GamblingView: View {
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    /// Nudged below 50/50, as any house game would be, absent a documented rate.
    private let winChance = 0.45
    @State private var lastResult: String?
    @State private var lastResultWon = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Gambling").novaFont(.heading, weight: .bold).foregroundStyle(.white)
            Text("You Have: \(creditsLabel(pilot.state.credits))")
                .novaFont(.body).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))

            if let lastResult {
                Text(lastResult)
                    .novaFont(.body, weight: .semibold)
                    .foregroundStyle(lastResultWon ? Color(red: 0.5, green: 0.9, blue: 0.5) : Color(red: 1, green: 0.5, blue: 0.5))
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                betButton(1000)
                betButton(5000)
            }

            Button("Leave", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.75, green: 0.15, blue: 0.15))
        }
        .padding(28)
        .frame(width: 320)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .novaResponsive()
        .animation(.easeInOut(duration: 0.15), value: lastResult)
    }

    private func betButton(_ stake: Int) -> some View {
        Button("Bet \(stake) cr") { bet(stake) }
            .buttonStyle(.bordered)
            .disabled(pilot.state.credits < stake)
    }

    private func bet(_ stake: Int) {
        guard pilot.state.credits >= stake else { return }
        let won = Double.random(in: 0..<1) < winChance
        if won {
            pilot.state.credits += stake
            lastResult = "You win \(creditsLabel(stake))!"
        } else {
            pilot.state.credits -= stake
            lastResult = "You lose \(creditsLabel(stake))."
        }
        lastResultWon = won
        pilot.save()
    }

    private func creditsLabel(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}
