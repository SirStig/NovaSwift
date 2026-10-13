import SwiftUI
import AVKit
import NovaSwiftKit

/// A `dësc` record's movie, played the way the original's text dialogs do
/// (`Ui_LoadDescAndPlayMovie` 0x0049e3c0, `Ui_RunTravelSelectionDialog` 0x004982a0,
/// `Ui_PlayMovieFileModal` 0x0049db00): before the text unless the dësc Flags say 0x0001
/// (after it); Flags 0x0002 plays at double size, 0x0004 blanks the screen first. Off with
/// the "QuickTime Movies" preference (`GameDataController.videoURL`), so a user who never
/// has movies gets exactly what they had.
@MainActor
final class DescMoviePlayback: ObservableObject {
    struct Clip {
        let descID: Int
        let url: URL
        let afterText: Bool
        let doubleSize: Bool
        let fillScreen: Bool
    }

    @Published private(set) var player: AVPlayer?
    @Published private(set) var gif: URL?
    @Published private(set) var clip: Clip?
    private var then: (() -> Void)?

    var isPlaying: Bool { player != nil || gif != nil }

    /// The movie `descID` names, resolved to a file, or nil (no movie, pref off, file missing).
    static func clip(for descID: Int?, data: GameDataController) -> Clip? {
        guard let descID, descID >= 0,
              let d = data.game?.desc(descID), let name = d.movieFilename?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, let url = data.videoURL(named: name) else { return nil }
        return Clip(descID: descID, url: url, afterText: d.moviePlaysAfterText,
                    doubleSize: d.movieDoubleSize, fillScreen: d.movieFillsScreen)
    }

    /// Plays a before-text movie as the text opens; an after-text movie waits for `finish`.
    /// `always`: play whatever the Flags say about "after the text" (docking, `FUN_0049e3c0`, plays at once).
    func begin(descID: Int?, data: GameDataController, always: Bool = false, then: (() -> Void)? = nil) {
        guard let c = Self.clip(for: descID, data: data), always || !c.afterText else { then?(); return }
        start(c, then: then)
    }

    /// Runs `action` once the text is closed, after its movie when the dësc puts the movie last.
    func finish(descID: Int?, data: GameDataController, then action: @escaping () -> Void) {
        if isPlaying { return }
        if let c = Self.clip(for: descID, data: data), c.afterText {
            start(c, then: action)
        } else {
            action()
        }
    }

    private func start(_ c: Clip, then: (() -> Void)?) {
        self.then = then
        clip = c
        if c.url.pathExtension.lowercased() == "gif" { gif = c.url; return }
        let p = AVPlayer(url: c.url)
        player = p
        p.play()
    }

    func dismiss() {
        guard isPlaying else { return }
        player?.pause()
        player = nil; gif = nil; clip = nil
        let t = then; then = nil
        t?()
    }
}

/// The full-screen movie surface for `DescMoviePlayback` (Skip, or it ends / fails).
struct DescMovieOverlay: View {
    @ObservedObject var playback: DescMoviePlayback

    var body: some View {
        if playback.isPlaying {
            let c = playback.clip
            let w: CGFloat = (c?.doubleSize ?? false) ? 960 : 480
            let h: CGFloat = (c?.doubleSize ?? false) ? 720 : 360
            ZStack {
                Color.black.opacity((c?.fillScreen ?? false) ? 1 : 0.92).ignoresSafeArea()
                VStack(spacing: 14) {
                    if let gif = playback.gif {
                        AnimatedGIFView(url: gif, onFinish: { playback.dismiss() })
                            .frame(maxWidth: w, maxHeight: h)
                    } else if let player = playback.player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: w, maxHeight: h)
                            .onReceive(NotificationCenter.default.publisher(
                                for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in playback.dismiss() }
                            .onReceive(NotificationCenter.default.publisher(
                                for: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)) { _ in playback.dismiss() }
                    }
                    Button("Skip") { playback.dismiss() }
                }
            }
            .cursorModal()
            .cursorCancel { playback.dismiss() }
        }
    }
}
