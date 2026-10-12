#if os(macOS)
import SwiftUI

// Shared loading affordances for the Plugin Editor. Every surface that needs
// derived data (map geometry, browse lists, stats, story graph, previews)
// computes it off the main actor and shows one of these until it lands, so a
// click always responds on the next frame.

/// A soft pulsing placeholder bar.
///
/// Animated by `TimelineView`, never `withAnimation(...repeatForever)`: a
/// repeating transaction started in `onAppear` leaks onto any layout change
/// that lands in the same update, which made whole headers slide back and
/// forth forever.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * .pi / 0.9) + 1) / 2          // 0…1, 1.8 s period
            RoundedRectangle(cornerRadius: height / 2.5, style: .continuous)
                .fill(Color.white.opacity(0.05 + 0.06 * pulse))
        }
        .frame(width: width, height: height)
    }
}

/// Placeholder rows for a list that's still loading (resource list, bit list…).
struct SkeletonList: View {
    var rows: Int = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 10) {
                    SkeletonBar(width: 38)
                    SkeletonBar(width: CGFloat(90 + (i * 37) % 110))
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityLabel("Loading")
    }
}

/// Placeholder for a form/inspector: a header plus grouped field rows.
struct SkeletonForm: View {
    var groups: Int = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SkeletonBar(width: 180, height: 16)
            ForEach(0..<groups, id: \.self) { g in
                VStack(alignment: .leading, spacing: 9) {
                    SkeletonBar(width: 110, height: 9)
                    ForEach(0..<(3 + g % 2), id: \.self) { _ in
                        HStack(spacing: 12) { SkeletonBar(width: 120); SkeletonBar() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityLabel("Loading")
    }
}

/// Centered spinner + label for canvases (galaxy map, story graph, previews).
struct EditorLoadingOverlay: View {
    var label: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular).tint(novaAmber)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// A thin indeterminate strip for "refreshing in the background" — shown when
/// stale data stays on screen while a recompute after an edit runs. Driven by
/// `TimelineView` (see `SkeletonBar` for why not `repeatForever`).
struct EditorRefreshStrip: View {
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            if active {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: 1.1)) / 1.1   // 0…1
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, novaAmber.opacity(0.8), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.3, height: 2)
                        .offset(x: (CGFloat(phase) * 1.3 - 0.3) * geo.size.width)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
    }
}
#endif
