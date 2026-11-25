import SwiftUI
import AVFoundation

/// A bare `AVPlayerLayer` surface for the game's movies (dësc movies, mission-BBS clips,
/// the gambling holovid).
///
/// Deliberately NOT SwiftUI's `VideoPlayer`: that lives in the `_AVKit_SwiftUI`
/// cross-import overlay, and on macOS 26.x (seen on Intel, TestFlight build 466) the
/// overlay can load without AVKit's own `AVPlayerView` class resolving, so instantiating
/// `VideoPlayerView`'s metadata hits `getSuperclassMetadata` → `fatalError` → SIGABRT the
/// moment a movie view enters the hierarchy. The original movies need no transport
/// controls (the screens supply Skip), so a plain layer view is all we need, and it only
/// depends on AVFoundation.
struct MoviePlayerView: View {
    let player: AVPlayer

    var body: some View {
        // Callers start/stop playback themselves (as they did with VideoPlayer).
        PlayerLayerRepresentable(player: player)
    }
}

#if os(macOS)
private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct PlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
    static func dismantleNSView(_ nsView: PlayerLayerNSView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}
#else
private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
}

private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
    static func dismantleUIView(_ uiView: PlayerLayerUIView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}
#endif
