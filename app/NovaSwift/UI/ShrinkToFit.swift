import SwiftUI

/// Downscale-only fit-to-viewport for fixed-size overlay dialogs.
///
/// The authentic PICT-framed screens (spaceport, galaxy map, mission info) route
/// through `novaFrameScale`, which already caps them to the viewport. But the
/// port's own dialog wrappers — `NovaDialog` (fixed width, content-hug height)
/// and `DialogChrome` (fixed 660×620) — have no such cap, so on a small iPhone
/// they overflow the screen and their footer/Done button becomes unreachable.
///
/// This modifier measures the content's natural size and, only when it exceeds
/// the available space, shrinks it with a `scaleEffect` so the whole card fits
/// (with a small margin). It never scales *up* — a small dialog stays its
/// designed size on a big screen. The measurement is a render-independent layout
/// read (scaleEffect is a draw-time transform, so it can't feed back into the
/// measured size), so there's no oscillation.
private struct ShrinkToFitViewport: ViewModifier {
    var margin: CGFloat = 16
    @State private var contentSize: CGSize = .zero

    func body(content: Content) -> some View {
        GeometryReader { geo in
            // A dialog may be presented inside a container that forces it wider
            // than the device (a sheet with `.frame(minWidth: 640)`, say), so the
            // local geometry over-reports the space. Cap to the real screen, and
            // subtract the safe-area insets so nothing clips under the notch or
            // home indicator.
            let insets = geo.safeAreaInsets
            let boundW = min(geo.size.width, Self.screenSize.width)
            let boundH = min(geo.size.height, Self.screenSize.height)
            let availW = max(1, boundW - insets.leading - insets.trailing - margin * 2)
            let availH = max(1, boundH - insets.top - insets.bottom - margin * 2)
            let scale: CGFloat = (contentSize.width > 0 && contentSize.height > 0)
                ? min(1, min(availW / contentSize.width, availH / contentSize.height))
                : 1
            content
                .background(GeometryReader { inner in
                    Color.clear.preference(key: DialogSizeKey.self, value: inner.size)
                })
                .scaleEffect(scale)
                // Fill the container and centre — matches the enclosing dialog
                // ZStack's own centring, so nothing shifts when scale == 1.
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .onPreferenceChange(DialogSizeKey.self) { contentSize = $0 }
    }

    /// The device screen size (a hard ceiling on the available space, whatever a
    /// parent claims to offer). Falls back to the local geometry on macOS.
    private static var screenSize: CGSize {
        #if os(iOS)
        return UIScreen.main.bounds.size
        #else
        return CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        #endif
    }
}

private struct DialogSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// Shrink this view to fit the enclosing geometry when it would otherwise
    /// overflow (never enlarges). Apply to fixed-size overlay dialog cards so
    /// they stay fully on-screen — and closable — on compact iOS screens.
    func shrinkToFitViewport(margin: CGFloat = 16) -> some View {
        modifier(ShrinkToFitViewport(margin: margin))
    }
}
