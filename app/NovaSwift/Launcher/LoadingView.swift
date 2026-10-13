import SwiftUI
import NovaSwiftKit

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

    /// Which tip is showing. Starts random, then steps on every few seconds;
    /// kept in state so the ~30 progress updates a second don't re-roll it.
    @State private var tipIndex = Int.random(in: 0..<LoadingView.tips.count)
    @State private var logoShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            LoadingScene(animated: !reduceMotion)

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                BurningWordmark(animated: !reduceMotion)
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 40)
                    .opacity(logoShown ? 1 : 0)
                    .scaleEffect(logoShown ? 1 : 0.94)
                Spacer(minLength: 24)
                statusPanel
                    .padding(.horizontal, 32)
                    .padding(.bottom, 34)
            }
            HUDBrackets()
                .padding(18)
                .allowsHitTesting(false)
        }
        .novaResponsive()
        .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 1.1)) { logoShown = true } }
        .task {
            // Step through the tips while loading lasts.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.5)) { tipIndex = (tipIndex + 1) % Self.tips.count }
            }
        }
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

    /// The ship's-computer readout: what's loading, how far along, and a tip.
    private var statusPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(phaseLabel.uppercased())
                        .novaFont(.caption, weight: .semibold)
                        .tracking(2.2)
                        .foregroundStyle(novaAmber.opacity(0.9))
                    Spacer(minLength: 12)
                    // Monospaced digits + a reserved slot: the count changes
                    // every few frames and would otherwise shimmy the label.
                    Text(countLabel ?? " ")
                        .novaFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(Int((progress * 100).rounded()))%")
                        .novaFont(.caption, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(novaAmber.opacity(0.9))
                        .frame(minWidth: 40, alignment: .trailing)
                }
                if model.settings.modernMainMenu {
                    SegmentedProgressBar(value: progress)
                } else {
                    ClassicProgressBar(value: progress, rect: model.data.game?.colr()?.progressBar)
                }
            }
            .frame(maxWidth: 520)
            .animation(.easeOut(duration: 0.25), value: progress)

            VStack(spacing: 6) {
                Text("TIP")
                    .novaFont(.caption, weight: .semibold)
                    .tracking(3)
                    .foregroundStyle(novaAmber.opacity(0.7))
                Text(Self.tips[tipIndex])
                    .novaFont(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(tipIndex)
                    .transition(.opacity)
            }
            .frame(maxWidth: 460)
            // Reserve two lines so a short tip doesn't jump the bar up.
            .frame(minHeight: 52, alignment: .top)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(novaAmber.opacity(0.22), lineWidth: 1))
        )
    }
}

/// The key art, alive: the scene drifts slowly (a long, gentle push-in and
/// sway) while three depths of stars slide past in front of it.
private struct LoadingScene: View {
    var animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geo in
                ZStack {
                    Image("LaunchBanner")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.06 + 0.03 * sin(t / 23))
                        .offset(x: 14 * sin(t / 31), y: 8 * cos(t / 37))
                        .clipped()
                    Canvas { ctx, size in
                        for star in StarField.stars {
                            // Nearer stars move faster and shine brighter (parallax).
                            let x = (star.x - t * star.speed).truncatingRemainder(dividingBy: 1)
                            let px = (x < 0 ? x + 1 : x) * size.width
                            let r = star.size
                            ctx.fill(Path(ellipseIn: CGRect(x: px - r / 2, y: star.y * size.height - r / 2, width: r, height: r)),
                                     with: .color(.white.opacity(star.alpha)))
                        }
                    }
                    // Darken toward the bottom so the readout stays legible.
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                }
            }
            // Driven by the clock alone. Without this, an animated change
            // elsewhere on the screen (the tip swapping every 7 s) re-tweened
            // the drift from a stale value: the backdrop jumped back, then on.
            .transaction { $0.animation = nil }
        }
        .ignoresSafeArea()
    }
}

/// A fixed, seeded field of drifting stars at three depths.
private enum StarField {
    struct Star { let x, y, speed, size, alpha: Double }
    static let stars: [Star] = {
        var g = SeededGenerator(seed: 7)
        return (0..<170).map { _ in
            let depth = Double.random(in: 0...1, using: &g)
            return Star(x: .random(in: 0...1, using: &g), y: .random(in: 0...1, using: &g),
                        speed: 0.002 + depth * depth * 0.014, size: 0.8 + depth * 1.8,
                        alpha: 0.25 + depth * 0.6)
        }
    }()

    /// SplitMix64 — deterministic, so the field is the same every launch.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The NOVA SWIFT wordmark with its fire alive: the flames layer (drawn
/// behind the gunmetal letters) flickers in height and brightness.
private struct BurningWordmark: View {
    var animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            // A few unrelated sines read as irregular flicker, not a pulse.
            let lift = 1 + 0.035 * sin(t * 7.1) + 0.022 * sin(t * 12.7 + 1.3) + 0.012 * sin(t * 23.3 + 0.4)
            let glow = 0.86 + 0.08 * sin(t * 9.3 + 2.1) + 0.06 * sin(t * 15.9)
            ZStack {
                Image("WordmarkFlames")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: 1 + 0.01 * sin(t * 5.3), y: lift, anchor: .bottom)
                    .opacity(glow)
                Image("Wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .shadow(color: Color(red: 1, green: 0.45, blue: 0.1).opacity(0.25 * glow), radius: 30)
            .transaction { $0.animation = nil }   // the flicker follows the clock only (see LoadingScene)
        }
        .accessibilityElement()
        .accessibilityLabel("NovaSwift")
    }
}

/// Amber targeting brackets in the corners — the cockpit framing.
private struct HUDBrackets: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = min(56, size.width * 0.06), w: CGFloat = 2
            var p = Path()
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 1, 1), (size.width, 0, -1, 1),
                                                                  (0, size.height, 1, -1), (size.width, size.height, -1, -1)]
            for (x, y, sx, sy) in corners {
                p.move(to: CGPoint(x: x + sx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + sy * l))
            }
            ctx.stroke(p, with: .color(novaAmber.opacity(0.7)), lineWidth: w)
        }
    }
}

/// The loading bar as a row of amber cells, like a cockpit gauge: lit cells
/// glow, the leading one brightest; unlit cells stay as dim outlines.
private struct SegmentedProgressBar: View {
    var value: Double
    private let cells = 36

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let w = (geo.size.width - gap * CGFloat(cells - 1)) / CGFloat(cells)
            let lit = Int((min(max(value, 0), 1) * Double(cells)).rounded(.down))
            HStack(spacing: gap) {
                ForEach(0..<cells, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < lit ? novaAmber.opacity(i == lit - 1 ? 1 : 0.82) : novaAmber.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(novaAmber.opacity(i < lit ? 0 : 0.28), lineWidth: 1))
                        .shadow(color: novaAmber.opacity(i < lit ? 0.55 : 0), radius: 4)
                        .frame(width: max(1, w))
                }
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// The original's flat loading bar (see `LoadingProgressBar`): ProgOutline
/// frame, ProgBright fill inside a 1-px ProgDim frame out to
/// `left + 1 + fraction·198`, black beyond, sized by cölr ProgressBar and
/// opening from its middle row one pixel per 2 ticks.
private struct ClassicProgressBar: View {
    var value: Double
    var rect: NovaRect?
    @Environment(\.novaTheme) private var theme
    @State private var openingStep = 0

    private var width: Int { max(rect?.width ?? 204, 4) }
    private var height: Int { max(rect?.height ?? 10, 4) }

    var body: some View {
        let w = width, h = height
        Canvas { ctx, _ in
            func px(_ l: Int, _ t: Int, _ r: Int, _ b: Int) -> CGRect {
                CGRect(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
            }
            func frame(_ r: CGRect, _ c: Color) {
                guard r.width > 0, r.height > 0 else { return }
                ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(c), lineWidth: 1)
            }
            if let open = LoadingProgressBar.openingExtent(top: 0, bottom: h, step: openingStep) {
                frame(px(0, open.top, w, open.bottom), theme.progOutline)
                ctx.fill(Path(px(1, open.top + 1, w - 1, open.bottom - 1)), with: .color(.black))
                return
            }
            frame(px(0, 0, w, h), theme.progOutline)
            let fill = LoadingProgressBar.fillRight(left: 0, right: w, done: min(max(value, 0), 1), total: 1)
            ctx.fill(Path(px(2, 2, fill - 1, h - 2)), with: .color(theme.progBright))
            frame(px(1, 1, fill, h - 1), theme.progDim)
            ctx.fill(Path(px(fill, 1, w - 1, h - 1)), with: .color(.black))
        }
        .frame(width: CGFloat(w), height: CGFloat(h))
        .task {
            // 2 ticks of the original's 60 Hz clock per opening step.
            while LoadingProgressBar.openingExtent(top: 0, bottom: h, step: openingStep) != nil {
                try? await Task.sleep(for: .milliseconds(33))
                if Task.isCancelled { return }
                openingStep += 1
            }
        }
    }
}
