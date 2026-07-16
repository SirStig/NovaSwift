#if canImport(GameKit)
import SwiftUI
import GameKit

/// Game Center sign-in **and invite delivery** for online co-op. Authenticating is
/// a launch-time concern (`RootView` kicks it off); the result gates the "Online"
/// entry.
///
/// Authentication may need to present a sign-in sheet — GameKit hands us a view
/// controller to show, which `GameCenterPresenter` puts on screen for either
/// platform. Once authenticated, the local player's `gamePlayerID` becomes the net
/// peer id (see `GameKitTransport`).
///
/// **Invites only arrive through `GKLocalPlayerListener`.** Registering it is what
/// makes an accepted invite reach the app at all — without the listener GameKit
/// still sends and accepts the invite, it just never tells us, so the invite looks
/// like it did nothing. We register once, at authentication, rather than from a
/// screen: an invite can land while the player is in flight, on the main menu, or
/// anywhere else, and it has to work from all of them.
@MainActor
final class GameCenterManager: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published var lastError: String?

    /// Called with a connected match whenever one forms out-of-band — i.e. the
    /// player accepted an invite, or started a match from the Game Center app.
    /// `hostID` is the `gamePlayerID` of the player who invited us (nil when we
    /// are the one who initiated, meaning we host). `AppModel` wires this to
    /// `MultiplayerSession.startGameCenter`.
    var onMatch: ((GKMatch, _ hostID: String?) -> Void)?

    /// Retained delegate for matchmaker controllers we present ourselves (invite
    /// flows). GameKit holds its delegate weakly, so this must outlive the call.
    private var inviteCoordinator: InviteMatchmakerCoordinator?

    /// Plug-in bucket (`PluginManifest.groupID`) for invites that arrive
    /// out-of-band, where no screen is around to supply one. Pulled on demand so it
    /// always reflects the currently enabled plug-ins — an invite can land long
    /// after the player last changed them. `AppModel` supplies it.
    var playerGroupProvider: (() -> Int)?

    /// Install the authentication handler and register for invites. Idempotent —
    /// GameKit calls the handler again on state changes, so we just keep
    /// `isAuthenticated` current and (re)register the listener once signed in.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.lastError = error.localizedDescription }
                if let viewController { GameCenterPresenter.present(viewController) }
                let wasAuthenticated = self.isAuthenticated
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                // Listener registration requires an authenticated local player, so
                // it can only happen here — not at init. `register` de-dupes the
                // same object, but only re-register on the transition to be safe.
                if self.isAuthenticated && !wasAuthenticated {
                    GKLocalPlayer.local.register(self)
                }
            }
        }
    }

    /// How many players recently looked for a match in our plug-in bucket. Drives
    /// honest matchmaking copy ("3 captains searching" vs. a bare spinner) instead
    /// of letting the player stare at a queue that nobody else is in.
    func queryPlayerCount(playerGroup: Int) async -> Int? {
        await withCheckedContinuation { continuation in
            GKMatchmaker.shared().queryPlayerGroupActivity(playerGroup) { count, error in
                continuation.resume(returning: error == nil ? count : nil)
            }
        }
    }

    /// Invite a player we've approved from the lobby directory.
    ///
    /// Two cases, because GameKit draws a hard line between "create a match" and
    /// "grow a match":
    /// - We already have a match (someone else joined earlier): `addPlayers` sends
    ///   the invite and folds them into the *existing* session, silently. This is
    ///   the path that matters — it's what lets a lobby accept a second and third
    ///   captain without disturbing the players already flying.
    /// - We're still alone: there's no match to add to, so we present a matchmaker
    ///   addressed to them, which creates one when they accept. `GKMatch` has no
    ///   concept of a one-player match to pre-create here.
    ///
    /// Either way we're the inviter, so we host and `onMatch` gets `hostID: nil`.
    func invite(playerID: String, into match: GKMatch?) async {
        let players = await Self.loadPlayers(ids: [playerID])
        guard !players.isEmpty else {
            lastError = "Couldn't find that player on Game Center."
            return
        }
        let request = makeMatchRequest(playerGroup: playerGroupProvider?() ?? 0)
        request.recipients = players
        if let match {
            do {
                try await GKMatchmaker.shared().addPlayers(to: match, matchRequest: request)
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            guard let vc = GKMatchmakerViewController(matchRequest: request) else {
                lastError = "Couldn't start that match."
                return
            }
            present(vc, hostID: nil)
        }
    }

    /// `GKPlayer.loadPlayers` is completion-handler only — no async overload.
    private static func loadPlayers(ids: [String]) async -> [GKPlayer] {
        await withCheckedContinuation { continuation in
            GKPlayer.loadPlayers(forIdentifiers: ids) { players, _ in
                continuation.resume(returning: players ?? [])
            }
        }
    }

    /// Present the matchmaker for an accepted invite and hand back the match. The
    /// inviter is the host — see `onMatch`.
    private func presentMatchmaker(for invite: GKInvite) {
        let hostID = invite.sender.gamePlayerID
        guard let vc = GKMatchmakerViewController(invite: invite) else {
            lastError = "Couldn't open that invite."
            return
        }
        present(vc, hostID: hostID)
    }

    /// Present the matchmaker pre-addressed to `recipients` — the player started a
    /// match with us from the Game Center app, so we're the one initiating and we
    /// host (`hostID` nil).
    private func presentMatchmaker(recipients: [GKPlayer], playerGroup: Int) {
        let request = makeMatchRequest(playerGroup: playerGroup)
        request.recipients = recipients
        guard let vc = GKMatchmakerViewController(matchRequest: request) else {
            lastError = "Couldn't start that match."
            return
        }
        present(vc, hostID: nil)
    }

    private func present(_ vc: GKMatchmakerViewController, hostID: String?) {
        let coordinator = InviteMatchmakerCoordinator { [weak self] result in
            guard let self else { return }
            self.inviteCoordinator = nil
            switch result {
            case .matched(let match): self.onMatch?(match, hostID)
            case .cancelled: break
            case .failed(let message): self.lastError = message
            }
        }
        inviteCoordinator = coordinator
        vc.matchmakerDelegate = coordinator
        GameCenterPresenter.present(vc)
    }
}

// MARK: - Invite delivery

/// The half of `GKLocalPlayerListener` that matters for real-time matches. Both
/// callbacks are the *only* way an invite reaches the app.
extension GameCenterManager: GKLocalPlayerListener {
    /// The player tapped an invite (banner, Game Center app, or our own send).
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in self.presentMatchmaker(for: invite) }
    }

    /// Someone picked us in the Game Center app's "play with friends" flow.
    nonisolated func player(_ player: GKPlayer, didRequestMatchWithRecipients recipients: [GKPlayer]) {
        Task { @MainActor in
            self.presentMatchmaker(recipients: recipients,
                                   playerGroup: self.playerGroupProvider?() ?? 0)
        }
    }
}

/// Outcome of a matchmaker we drove ourselves.
private enum MatchmakerResult {
    case matched(GKMatch)
    case cancelled
    case failed(String)
}

/// Delegate for matchmakers presented outside SwiftUI (invite flows). Dismisses
/// the controller itself — nothing else owns it.
private final class InviteMatchmakerCoordinator: NSObject, GKMatchmakerViewControllerDelegate {
    private let onResult: (MatchmakerResult) -> Void
    init(onResult: @escaping (MatchmakerResult) -> Void) { self.onResult = onResult }

    func matchmakerViewControllerWasCancelled(_ vc: GKMatchmakerViewController) {
        GameCenterPresenter.dismiss(vc)
        onResult(.cancelled)
    }

    func matchmakerViewController(_ vc: GKMatchmakerViewController, didFailWithError error: Error) {
        GameCenterPresenter.dismiss(vc)
        onResult(.failed(error.localizedDescription))
    }

    func matchmakerViewController(_ vc: GKMatchmakerViewController, didFind match: GKMatch) {
        GameCenterPresenter.dismiss(vc)
        onResult(.matched(match))
    }
}

/// Presents (and dismisses) a GameKit-supplied view controller on either platform.
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

    static func dismiss(_ vc: UIViewController) { vc.dismiss(animated: true) }
    #elseif os(macOS)
    static func present(_ vc: NSViewController) {
        guard let content = NSApp.keyWindow?.contentViewController else { return }
        content.presentAsSheet(vc)
    }

    static func dismiss(_ vc: NSViewController) { vc.dismiss(vc) }
    #endif
}

/// A default 2–4 player request for a friends/auto co-op match. `playerGroup`
/// buckets auto-matchmaking by the enabled plug-in set (`PluginManifest.groupID`)
/// so only players with the same plug-ins are auto-matched — invites still get the
/// full manifest handshake, since `playerGroup` doesn't gate them.
func makeMatchRequest(playerGroup: Int) -> GKMatchRequest {
    let request = GKMatchRequest()
    request.minPlayers = 2
    request.maxPlayers = 4
    request.playerGroup = playerGroup
    request.inviteMessage = "Fly with me in Nova Swift."
    return request
}

/// SwiftUI wrapper around `GKMatchmakerViewController`. Host it in a `.sheet`; it
/// calls `onMatch` with a connected `GKMatch` (hand it to
/// `MultiplayerSession.startGameCenter`), or `onCancel` if the user backs out.
/// Used for player-initiated matchmaking; invites come through `GameCenterManager`.
#if os(iOS)
struct GameCenterMatchmakerView: UIViewControllerRepresentable {
    /// Plug-in-set bucket for auto-match (see `makeMatchRequest`).
    var playerGroup: Int = 0
    /// Pre-address the invite to specific friends (empty = open auto-match).
    var recipients: [GKPlayer] = []
    var onMatch: (GKMatch) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> GKMatchmakerViewController {
        let request = makeMatchRequest(playerGroup: playerGroup)
        if !recipients.isEmpty { request.recipients = recipients }
        let vc = GKMatchmakerViewController(matchRequest: request) ?? GKMatchmakerViewController()
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
    /// Pre-address the invite to specific friends (empty = open auto-match).
    var recipients: [GKPlayer] = []
    var onMatch: (GKMatch) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> GKMatchmakerViewController {
        let request = makeMatchRequest(playerGroup: playerGroup)
        if !recipients.isEmpty { request.recipients = recipients }
        let vc = GKMatchmakerViewController(matchRequest: request) ?? GKMatchmakerViewController()
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
