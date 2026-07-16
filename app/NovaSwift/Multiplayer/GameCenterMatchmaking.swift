#if canImport(GameKit)
import SwiftUI
import GameKit

/// Game Center sign-in state for online co-op. Authenticating is a launch-time
/// concern (`RootView` kicks it off); the result gates the "Online Co-op" entry.
///
/// Authentication may need to present a sign-in sheet — GameKit hands us a view
/// controller to show, which `GameCenterPresenter` puts on screen for either
/// platform. Once authenticated, the local player's `gamePlayerID` becomes the
/// net peer id (see `GameKitTransport`).
@MainActor
final class GameCenterManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published var lastError: String?

    /// Install the authentication handler. Idempotent — GameKit calls the handler
    /// again on state changes, so we just keep `isAuthenticated` current.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                if let viewController { GameCenterPresenter.present(viewController) }
                self?.isAuthenticated = GKLocalPlayer.local.isAuthenticated
            }
        }
    }
}

/// Presents a GameKit-supplied view controller (sign-in) on whichever platform.
enum GameCenterPresenter {
    #if os(iOS)
    static func present(_ vc: UIViewController) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        // Walk to the top-most presented controller so we don't present on a busy one.
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }
    #elseif os(macOS)
    static func present(_ vc: NSViewController) {
        guard let content = NSApp.keyWindow?.contentViewController else { return }
        content.presentAsSheet(vc)
    }
    #endif
}

/// A default 2–4 player request for a friends/auto co-op match. `playerGroup`
/// buckets auto-matchmaking by the enabled-plug-in set (`PluginManifest.groupID`)
/// so only players with the same plug-ins are auto-matched — invites still get the
/// full manifest handshake, since `playerGroup` doesn't gate them.
private func makeMatchRequest(playerGroup: Int) -> GKMatchRequest {
    let request = GKMatchRequest()
    request.minPlayers = 2
    request.maxPlayers = 4
    request.playerGroup = playerGroup
    return request
}

/// SwiftUI wrapper around `GKMatchmakerViewController`. Host it in a `.sheet`; it
/// calls `onMatch` with a connected `GKMatch` (hand it to
/// `MultiplayerSession.startGameCenter`), or `onCancel` if the user backs out.
#if os(iOS)
struct GameCenterMatchmakerView: UIViewControllerRepresentable {
    /// Plug-in-set bucket for auto-match (see `makeMatchRequest`).
    var playerGroup: Int = 0
    var onMatch: (GKMatch) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> GKMatchmakerViewController {
        let vc = GKMatchmakerViewController(matchRequest: makeMatchRequest(playerGroup: playerGroup))
            ?? GKMatchmakerViewController()
        vc.matchmakerDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: GKMatchmakerViewController, context: Context) {}

    final class Coordinator: NSObject, GKMatchmakerViewControllerDelegate {
        let parent: GameCenterMatchmakerView
        init(_ parent: GameCenterMatchmakerView) { self.parent = parent }
        func matchmakerViewControllerWasCancelled(_ vc: GKMatchmakerViewController) { parent.onCancel() }
        func matchmakerViewController(_ vc: GKMatchmakerViewController, didFailWithError error: Error) {
            parent.onError(error.localizedDescription)
        }
        func matchmakerViewController(_ vc: GKMatchmakerViewController, didFind match: GKMatch) {
            parent.onMatch(match)
        }
    }
}
#elseif os(macOS)
struct GameCenterMatchmakerView: NSViewControllerRepresentable {
    /// Plug-in-set bucket for auto-match (see `makeMatchRequest`).
    var playerGroup: Int = 0
    var onMatch: (GKMatch) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> GKMatchmakerViewController {
        let vc = GKMatchmakerViewController(matchRequest: makeMatchRequest(playerGroup: playerGroup))
            ?? GKMatchmakerViewController()
        vc.matchmakerDelegate = context.coordinator
        return vc
    }

    func updateNSViewController(_ vc: GKMatchmakerViewController, context: Context) {}

    final class Coordinator: NSObject, GKMatchmakerViewControllerDelegate {
        let parent: GameCenterMatchmakerView
        init(_ parent: GameCenterMatchmakerView) { self.parent = parent }
        func matchmakerViewControllerWasCancelled(_ vc: GKMatchmakerViewController) { parent.onCancel() }
        func matchmakerViewController(_ vc: GKMatchmakerViewController, didFailWithError error: Error) {
            parent.onError(error.localizedDescription)
        }
        func matchmakerViewController(_ vc: GKMatchmakerViewController, didFind match: GKMatch) {
            parent.onMatch(match)
        }
    }
}
#endif
#endif
