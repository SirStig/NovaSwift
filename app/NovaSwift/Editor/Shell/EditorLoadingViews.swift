#if os(macOS)
import SwiftUI

// Shared loading affordances for the Plugin Editor. Every surface that needs
// derived data (map geometry, browse lists, stats, story graph, previews)
// computes it off the main actor and shows one of these until it lands, so a
// click always responds on the next frame.

/// A soft pulsing placeholder bar.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.5, style: .continuous)
            .fill(Color.white.opacity(lit ? 0.11 : 0.05))
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
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
/// stale data stays on screen while a recompute after an edit runs.
struct EditorRefreshStrip: View {
    var active: Bool
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            if active {
                Capsule()
                    .fill(LinearGradient(colors: [.clear, novaAmber.opacity(0.8), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * 0.3, height: 2)
                    .offset(x: phase * geo.size.width)
                    .onAppear {
                        phase = -0.3
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                    }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
#endif
