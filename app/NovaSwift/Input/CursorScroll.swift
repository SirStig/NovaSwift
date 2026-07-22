import SwiftUI

/// Registry of controller-scrollable areas, mirroring `CursorTargets`:
/// scrollable containers opt in with `.cursorScrollable()`, which records
/// their global-space frame and a scroll-by-delta closure; the cursor
/// overlay's right-stick handling drives the area under the cursor.
@MainActor
final class CursorScrollTargets {
    static let shared = CursorScrollTargets()

    struct Target {
        var frame: CGRect
        var scrollBy: (CGFloat) -> Void
    }

    private(set) var targets: [UUID: Target] = [:]

    func update(_ id: UUID, frame: CGRect, scrollBy: @escaping (CGFloat) -> Void) {
        targets[id] = Target(frame: frame, scrollBy: scrollBy)
    }

    func remove(_ id: UUID) { targets.removeValue(forKey: id) }

    /// The scrollable under a point — smallest containing frame wins, so a
    /// nested list beats the panel registered behind it.
    func target(at point: CGPoint) -> Target? {
        targets.values
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

extension View {
    /// Lets the controller cursor scroll the scrollable container in this
    /// view: right thumbstick while the cursor hovers it. Needs the
    /// `ScrollPosition` API — on OS versions before iOS/tvOS 18 (macOS 15)
    /// this is a no-op and the container scrolls by touch/trackpad only.
    @ViewBuilder
    func cursorScrollable() -> some View {
        if #available(iOS 18.0, tvOS 18.0, macOS 15.0, *) {
            modifier(CursorScrollable())
        } else {
            self
        }
    }
}

@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)
private struct CursorScrollable: ViewModifier {
    @State private var id = UUID()
    @State private var position = ScrollPosition()
    /// Live scroll metrics from `onScrollGeometryChange`; the delta handler
    /// clamps against them so stick scrolling stops crisply at either end
    /// instead of piling up out-of-range offsets.
    @State private var offsetY: CGFloat = 0
    @State private var minY: CGFloat = 0
    @State private var maxY: CGFloat = 0
    /// Ancestor `cursorScaleEffect` — hit frames register where the
    /// container is *drawn*, same mapping as `CursorClickable`.
    @Environment(\.cursorFrameTransform) private var frameTransform

    private struct Metrics: Equatable {
        var offsetY: CGFloat, minY: CGFloat, maxY: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geo in
                Metrics(offsetY: geo.contentOffset.y,
                        minY: -geo.contentInsets.top,
                        maxY: max(-geo.contentInsets.top,
                                  geo.contentSize.height + geo.contentInsets.bottom
                                      - geo.containerSize.height))
            } action: { _, m in
                offsetY = m.offsetY; minY = m.minY; maxY = m.maxY
            }
            .background(
                GeometryReader { geo in
                    // Refreshed every layout pass, like CursorClickable's
                    // registration — the registry publishes nothing, so this
                    // is safe during view updates.
                    let _ = {
                        if frameTransform.ready {
                            CursorScrollTargets.shared.update(
                                id, frame: frameTransform.apply(geo.frame(in: .global)),
                                scrollBy: { dy in
                                    let target = min(max(offsetY + dy, minY), maxY)
                                    position.scrollTo(y: target)
                                    // Advance locally: the next 60 Hz tick can't
                                    // wait for the geometry callback round-trip.
                                    offsetY = target
                                })
                        } else {
                            CursorScrollTargets.shared.remove(id)
                        }
                    }()
                    Color.clear.onDisappear { CursorScrollTargets.shared.remove(id) }
                }
            )
    }
}
