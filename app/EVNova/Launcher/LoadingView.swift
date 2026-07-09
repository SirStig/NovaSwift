import SwiftUI

/// The transition between the launcher and the game: loads/merges the data set
/// while showing progress, so entering the game feels distinct and never blocks
/// on a blank screen.
struct LoadingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var progress = 0.05

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let tips = [
        "Trade high-tech goods to frontier worlds for profit.",
        "Disable a ship, then board it to plunder its cargo.",
        "Your reputation with each government shapes who shoots first.",
        "Outfit expansions and afterburners change everything.",
        "Some missions only appear at the right time and place.",
    ]

    var body: some View {
        ZStack {
            StarfieldBackground()
            VStack(spacing: 22) {
                AppMark().frame(width: 96, height: 96)
                Text("EV NOVA")
                    .novaFont(.title, weight: .heavy, size: 34).tracking(6)
                    .foregroundStyle(.white)
                ProgressView(value: progress)
                    .frame(width: 240)
                    .tint(amber)
                Text(model.data.status)
                    .novaFont(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Text(tips.randomElement() ?? "")
                    .novaFont(.caption).italic().foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)
            }
            .padding(40)
        }
        .novaResponsive()
        .task {
            withAnimation(.easeOut(duration: 0.3)) { progress = 0.35 }
            // Load/merge the data set (base + enabled plug-ins).
            model.data.reloadIfNeeded()
            withAnimation(.easeOut(duration: 0.7)) { progress = 0.7 }
            // Fully decode the catalog + hull sprites now, off the main thread,
            // so gameplay never pays that cost lazily mid-frame (first Shipyard/
            // Outfitter visit, first time a hull is seen after a jump).
            await model.data.prewarm()
            withAnimation(.easeOut(duration: 0.3)) { progress = 1.0 }
            model.finishLoadingIntoGame()
        }
    }
}
