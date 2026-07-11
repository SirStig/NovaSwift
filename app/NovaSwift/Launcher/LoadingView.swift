import SwiftUI

/// The transition between the launcher and the game: loads/merges the data set
/// while showing progress, so entering the game feels distinct and never blocks
/// on a blank screen.
struct LoadingView: View {
    @EnvironmentObject private var model: AppModel

    /// Whether finishing the prewarm should enter the game. True on the real
    /// launcher→game transition (`screen == .loading`); **false** when this view
    /// is only standing in as the brief placeholder while the main-menu art
    /// decodes (`RootView`'s `.mainMenu` branch). Without this, decoding the menu
    /// art would silently launch straight into the saved pilot — the menu should
    /// appear and stay put until the player chooses.
    var entersGame = true

    /// How far the bar has crept while the data set merges. `reloadIfNeeded` is
    /// synchronous and reports nothing, so this stretch is a time-based tease;
    /// everything from `prewarmShare` on is driven by real counts.
    @State private var openingProgress = 0.03

    /// Rolled once, when the view is created. Rolling inside `body` would
    /// re-roll on every published progress update — roughly thirty times a
    /// second — leaving the line unreadable.
    @State private var tip = LoadingView.tips.randomElement() ?? ""

    /// The fraction of the bar the (unmeasurable) data-set merge occupies.
    private let prewarmShare = 0.12

    private static let tips = [
        "Trade high-tech goods to frontier worlds for profit.",
        "Disable a ship, then board it to plunder its cargo.",
        "Your reputation with each government shapes who shoots first.",
        "Outfit expansions and afterburners change everything.",
        "Some missions only appear at the right time and place.",
    ]

    /// Monotonic by construction: the opening tease is capped at `prewarmShare`,
    /// and `prewarmFraction` is itself clamped to never decrease.
    private var progress: Double {
        guard model.data.prewarmProgress != nil else { return openingProgress }
        return prewarmShare + (1 - prewarmShare) * model.data.prewarmFraction
    }

    private var phaseLabel: String {
        model.data.prewarmProgress?.phase ?? "Loading data set"
    }

    /// `nil` until the first real report, so the slot stays empty rather than
    /// flashing a meaningless "0 / 0".
    private var countLabel: String? {
        guard let p = model.data.prewarmProgress, p.total > 0 else { return nil }
        return "\(p.completed) / \(p.total)"
    }

    var body: some View {
        ZStack {
            StarfieldBackground()

            VStack(spacing: 0) {
                Spacer()

                AppMark()
                    .frame(width: 104, height: 104)
                    .shadow(color: novaAmber.opacity(0.28), radius: 28)

                Text("EV NOVA")
                    .novaFont(.title, weight: .heavy, size: 34)
                    .tracking(8)
                    .foregroundStyle(.white)
                    .padding(.top, 18)

                hairline.padding(.top, 16)

                Spacer()

                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(phaseLabel)
                            .novaFont(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        // Monospaced digits + a reserved trailing slot: the
                        // count changes every few frames and would otherwise
                        // shimmy the phase label around as digits grow.
                        Text(countLabel ?? " ")
                            .novaFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    NovaProgressBar(value: progress)
                }
                .frame(maxWidth: 380)
                // The phase label swaps between stages; crossfade it rather
                // than letting it pop.
                .animation(.easeOut(duration: 0.25), value: progress)

                tipBlock.padding(.top, 34)

                Spacer()
            }
            .padding(40)
        }
        .novaResponsive()
        .task {
            withAnimation(.easeOut(duration: 0.5)) { openingProgress = prewarmShare }
            // Load/merge the data set (base + enabled plug-ins).
            model.data.reloadIfNeeded()
            // Fully decode the catalog + hull sprites now, off the main thread,
            // so gameplay never pays that cost lazily mid-frame (first Shipyard/
            // Outfitter visit, first time a hull is seen after a jump).
            await model.data.prewarm()
            // Let the bar visibly land on full before the screen swaps out.
            try? await Task.sleep(for: .milliseconds(260))
            // Only advance into the game on the real load; if the task was
            // cancelled (e.g. the menu art finished decoding and this placeholder
            // was replaced), don't yank the player out of the menu. The `try?`
            // above swallows cancellation, so check it explicitly here.
            guard entersGame, !Task.isCancelled else { return }
            model.finishLoadingIntoGame()
        }
    }

    /// A rule that fades out at both ends, echoing the engraved dividers on the
    /// game's own dialogs.
    private var hairline: some View {
        LinearGradient(colors: [.clear, novaAmber.opacity(0.55), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: 260, height: 1)
    }

    private var tipBlock: some View {
        VStack(spacing: 7) {
            Text("TIP")
                .novaFont(.caption, weight: .semibold)
                .tracking(3)
                .foregroundStyle(novaAmber.opacity(0.7))
            Text(tip)
                .novaFont(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        // Reserve the taller two-line case so a wrapping tip can't shove the
        // progress bar upward mid-load.
        .frame(height: 52, alignment: .top)
    }
}

/// EV Nova's beveled, inset progress well: a dark recess lit by an amber fill
/// with a specular highlight along its top edge.
private struct NovaProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            let filled = geo.size.width * min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.05))
                    .overlay(
                        Capsule().strokeBorder(Color(white: 0.30), lineWidth: 1)
                    )

                Capsule()
                    .fill(LinearGradient(colors: [novaAmber, novaAmber.opacity(0.72)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: 1.5)
                            .padding(.horizontal, 4)
                            .padding(.top, 1.5)
                    }
                    .frame(width: filled)
                    .shadow(color: novaAmber.opacity(0.45), radius: 7)
                    // Zero-width capsules still paint a sliver of glow; hide the
                    // fill entirely until there's something to show.
                    .opacity(filled > 0.5 ? 1 : 0)
            }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.28), value: value)
    }
}
