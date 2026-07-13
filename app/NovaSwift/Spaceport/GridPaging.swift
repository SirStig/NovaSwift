import SwiftUI
import GameController
#if os(macOS)
import AppKit
#endif

/// Scrolls the Outfitter/Shipyard item grid through every input method a
/// player actually has, not just the on-screen arrow buttons: mouse wheel /
/// trackpad scroll and arrow keys on macOS, touch swipe on iOS/iPadOS, and a
/// connected game controller's d-pad/left-stick on both. Each step is one
/// unit of whatever the caller passes — the grids pass top-row indices, so
/// every input scrolls one ROW at a time like the real game's arrows.
struct GridPagingModifier: ViewModifier {
    let currentPage: Int
    let pageCount: Int
    let onChange: (Int) -> Void

    @State private var controllerWasUp = false
    @State private var controllerWasDown = false

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background(ScrollWheelCatcher { delta in
                if delta < -2 { step(1) } else if delta > 2 { step(-1) }
            })
            #endif
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        // Swipe up (content moves up) = next page, matching
                        // how a scroll/swipe reveals content further down.
                        if value.translation.height < -40 { step(1) }
                        else if value.translation.height > 40 { step(-1) }
                    }
            )
            .focusable()
            // Suppress the macOS default focus ring — it draws a yellow border around
            // the grid that lingers past the panel during the dismiss transition. Same
            // pattern as GameContainerView / TutorialContainerView. Paging still works.
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .onKeyPress(.downArrow) { step(1); return .handled }
            .task(id: "grid-controller-poll") { await pollController() }
    }

    private func step(_ delta: Int) {
        let next = min(max(currentPage + delta, 0), pageCount - 1)
        if next != currentPage { onChange(next) }
    }

    /// Discrete-press d-pad/left-stick polling, independent of the paused
    /// flight scene's own per-frame `GameControllerInput.poll()` (which never
    /// runs while landed) — this view has its own lifetime-scoped loop so a
    /// controller works for menu paging even with the scene frozen.
    private func pollController() async {
        while !Task.isCancelled {
            if let pad = GCController.current?.extendedGamepad {
                let up = pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5
                let down = pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5
                if up, !controllerWasUp { step(-1) }
                if down, !controllerWasDown { step(1) }
                controllerWasUp = up
                controllerWasDown = down
            }
            try? await Task.sleep(nanoseconds: 130_000_000)   // ~7-8 polls/sec: snappy, not spammy
        }
    }
}

extension View {
    /// See `GridPagingModifier`.
    func gridPaging(currentPage: Int, pageCount: Int, onChange: @escaping (Int) -> Void) -> some View {
        modifier(GridPagingModifier(currentPage: currentPage, pageCount: pageCount, onChange: onChange))
    }
}

#if os(macOS)
/// An invisible `NSView` that only ever answers hit-tests for scroll-wheel
/// events (checked via the current `NSApp` event, since `hitTest` itself
/// isn't told which event it's routing) — so it can sit behind the grid and
/// catch trackpad/mouse-wheel scrolling without ever stealing a tile tap.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaY)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? self : nil
        }
    }
}
#endif
