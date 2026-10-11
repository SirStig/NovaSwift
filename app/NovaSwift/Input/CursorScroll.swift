import SwiftUI

/// Registry of controller-scrollable areas, mirroring `CursorTargets`:
/// scrollable containers opt in with `.cursorScrollable()` (a `ScrollView` /
/// `List`) or `.cursorPannable { delta in … }` (anything that pages or pans
/// itself — the outfit/ship grids, the star map), which record their global-
/// space frame and a scroll-by-delta closure. The cursor overlay's right stick
/// (and the d-pad, past the last control in a direction) drives the area
/// under the cursor. Scoped by host and modal layer exactly like click targets,
/// so a list behind a dialog can't be scrolled.
@MainActor
final class CursorScrollTargets {
    static let shared = CursorScrollTargets()

    struct Target {
        var frame: CGRect
        var host = CursorTargets.rootHost
        var layer = 0
        /// Content-offset delta: +dy reveals what's further down, +dx what's
        /// further right.
        var scrollBy: (CGVector) -> Void
    }

    private(set) var targets: [UUID: Target] = [:]

    func update(_ id: UUID, frame: CGRect, host: UUID, layer: Int,
                scrollBy: @escaping (CGVector) -> Void) {
        targets[id] = Target(frame: frame, host: host, layer: layer, scrollBy: scrollBy)
    }

    func remove(_ id: UUID) { targets.removeValue(forKey: id) }

    /// Scrollables on the host's live modal layer.
    func live(in host: UUID) -> [Target] {
        let top = CursorTargets.shared.topLayer(in: host)
        return targets.values.filter { $0.host == host && $0.layer == top }
    }

    /// The scrollable under a point — smallest containing frame wins, so a
    /// nested list beats the panel registered behind it. With the cursor over
    /// none, the largest live one (the screen's main list) so the right stick
    /// always scrolls *something* sensible.
    func target(at point: CGPoint, in host: UUID) -> Target? {
        let candidates = live(in: host)
        return candidates
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

extension View {
    /// Lets the controller scroll the scrollable container in this view: right
    /// thumbstick while the cursor hovers it (or the d-pad past its last
    /// control). Vertical, plus horizontal for horizontal scroll views. Needs
    /// the `ScrollPosition` API — on OS versions before iOS/tvOS 18 (macOS 15)
    /// this is a no-op and the container scrolls by touch/trackpad only.
    @ViewBuilder
    func cursorScrollable() -> some View {
        if #available(iOS 18.0, tvOS 18.0, macOS 15.0, *) {
            modifier(CursorScrollable())
        } else {
            self
        }
    }

    /// Registers a custom-scrolling area (paged grid, pannable map) with the
    /// controller: `scrollBy` receives content-offset deltas in points from
    /// the right stick (continuous) and the d-pad (80 pt steps).
    func cursorPannable(_ scrollBy: @escaping (CGVector) -> Void) -> some View {
        modifier(CursorPannable(scrollBy: scrollBy))
    }
}

private struct CursorPannable: ViewModifier {
    let scrollBy: (CGVector) -> Void
    @State private var id = UUID()
    @Environment(\.cursorHost) private var host
    @Environment(\.cursorLayer) private var layer

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                // Drawn-space global frame, registered verbatim (see
                // `CursorClickable`). Refreshed every layout pass.
                let _ = CursorScrollTargets.shared.update(
                    id, frame: geo.frame(in: .global), host: host, layer: layer,
                    scrollBy: scrollBy)
                Color.clear.onDisappear { CursorScrollTargets.shared.remove(id) }
            }
        )
    }
}

@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)
private struct CursorScrollable: ViewModifier {
    @State private var id = UUID()
    @State private var position = ScrollPosition()
    @Environment(\.cursorHost) private var host
    @Environment(\.cursorLayer) private var layer
    /// Live scroll metrics from `onScrollGeometryChange`; the delta handler
    /// clamps against them so stick scrolling stops crisply at either end
    /// instead of piling up out-of-range offsets.
    @State private var offset: CGPoint = .zero
    @State private var minOffset: CGPoint = .zero
    @State private var maxOffset: CGPoint = .zero
    private struct Metrics: Equatable {
        var offset: CGPoint, minOffset: CGPoint, maxOffset: CGPoint
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geo in
                let minX = -geo.contentInsets.leading, minY = -geo.contentInsets.top
                return Metrics(
                    offset: geo.contentOffset,
                    minOffset: CGPoint(x: minX, y: minY),
                    maxOffset: CGPoint(
                        x: max(minX, geo.contentSize.width + geo.contentInsets.trailing
                                   - geo.containerSize.width),
                        y: max(minY, geo.contentSize.height + geo.contentInsets.bottom
                                   - geo.containerSize.height)))
            } action: { _, m in
                offset = m.offset; minOffset = m.minOffset; maxOffset = m.maxOffset
            }
            .background(
                GeometryReader { geo in
                    // Refreshed every layout pass, like CursorClickable's
                    // registration — the registry publishes nothing, so this
                    // is safe during view updates.
                    let _ = {
                        // Already drawn-space (ancestor scaleEffect/offset folded
                        // in by SwiftUI) — register verbatim, same as
                        // `CursorClickable`.
                        CursorScrollTargets.shared.update(
                            id, frame: geo.frame(in: .global), host: host, layer: layer,
                            scrollBy: { d in
                                // Only the axis that actually overflows moves, so a
                                // vertical list ignores sideways stick and vice versa.
                                let canX = maxOffset.x > minOffset.x
                                let canY = maxOffset.y > minOffset.y
                                guard canX || canY else { return }
                                let target = CGPoint(
                                    x: canX ? min(max(offset.x + d.dx, minOffset.x), maxOffset.x) : offset.x,
                                    y: canY ? min(max(offset.y + d.dy, minOffset.y), maxOffset.y) : offset.y)
                                position.scrollTo(point: target)
                                // Advance locally: the next 60 Hz tick can't
                                // wait for the geometry callback round-trip.
                                offset = target
                            })
                    }()
                    Color.clear.onDisappear { CursorScrollTargets.shared.remove(id) }
                }
            )
    }
}
