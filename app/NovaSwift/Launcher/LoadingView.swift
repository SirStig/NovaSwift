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
        "Land on a planet or station to trade, refuel, repair, and take on missions.",
        "Check the Mission BBS and the Bar at each port — that's where jobs and storylines begin.",
        "Every hyperspace jump burns fuel. Refuel when you land before heading back out.",
        "Disable a ship with weapons fire, then board it to plunder its cargo and credits.",
        "Your standing with each government decides who greets you and who opens fire.",
        "Spend credits at the Outfitter — afterburners, shields and weapons change how you fight.",
        "Open the galaxy map to plot a course; your ship jumps through it one system at a time.",
        "Buy goods cheap on industrial worlds and sell them dear out on the frontier.",
        "Hire escorts at the Bar to fight at your side — they draw a daily wage.",
        "Cargo and courier missions pay on delivery, and some run against a deadline.",
        "Some missions only appear at the right place and time, or once a government trusts you.",
        "New to the cockpit? Replay Flight Training any time from the main menu.",
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

            // The key art, sitting on the starfield. It already carries the
            // NOVA branding, so there's no separate logo or title over it — the
            // progress and tip are layered onto the art's lower edge instead.
            Image("LaunchBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 1100)
                .overlay(alignment: .bottom) { statusOverlay }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: novaAmber.opacity(0.22), radius: 44)
                .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
                .padding(.horizontal, 28)
        }
        .novaResponsive()
        .task {
            withAnimation(.easeOut(duration: 0.5)) { openingProgress = prewarmShare }
            // Load/merge the data set (base + enabled plug-ins) off the main
            // thread, so the loading screen keeps animating while the ~60 MB of
            // containers is read and parsed.
            await model.data.reloadIfNeededAsync()
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

    /// Progress bar + tip, welded to the bottom edge of the key art. A scrim
    /// fades the busy lower band of the image into darkness so the text and bar
    /// stay legible over it.
    private var statusOverlay: some View {
        VStack(spacing: 16) {
            VStack(spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(phaseLabel)
                        .novaFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    // Monospaced digits + a reserved trailing slot: the count
                    // changes every few frames and would otherwise shimmy the
                    // phase label around as digits grow.
                    Text(countLabel ?? " ")
                        .novaFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                NovaProgressBar(value: progress)
            }
            .frame(maxWidth: 380)
            // The phase label swaps between stages; crossfade it rather than
            // letting it pop.
            .animation(.easeOut(duration: 0.25), value: progress)

            tipBlock
        }
        .padding(.horizontal, 30)
        .padding(.top, 60)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.35),
                                    .black.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
        )
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
                // Let the tip wrap to as many lines as it needs and report its
                // full height, so a longer line is never clipped by the block.
                .fixedSize(horizontal: false, vertical: true)
        }
        // Wider so most tips fit in two lines, and centred on the art.
        .frame(maxWidth: 420)
        // Reserve the two-line case (so a short tip doesn't jump the bar up) but
        // allow growth — the block is bottom-anchored, so a taller tip expands
        // upward rather than spilling past the art's clipped bottom edge.
        .frame(minHeight: 52, alignment: .top)
    }
}

/// EV Nova's beveled, inset progress well: a dark recess lit by an amber fill
/// with a specular highlight along its top edge.
private struct NovaProgressBar: View {
    var value: Double
    @Environment(\.novaTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let filled = geo.size.width * min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.progDim)
                    .overlay(
                        Capsule().strokeBorder(theme.progOutline, lineWidth: 1)
                    )

                Capsule()
                    .fill(LinearGradient(colors: [theme.progBright, theme.progBright.opacity(0.72)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: 1.5)
                            .padding(.horizontal, 4)
                            .padding(.top, 1.5)
                    }
                    .frame(width: filled)
                    .shadow(color: theme.progBright.opacity(0.45), radius: 7)
                    // Zero-width capsules still paint a sliver of glow; hide the
                    // fill entirely until there's something to show.
                    .opacity(filled > 0.5 ? 1 : 0)
            }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.28), value: value)
    }
}
