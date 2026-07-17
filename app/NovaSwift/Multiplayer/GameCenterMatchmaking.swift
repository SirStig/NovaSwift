#if canImport(GameKit)
import SwiftUI
import GameKit

/// Who owns a forming online session's lobby.
///
/// A `GKMatch` has no host, so we establish one — and the rule has to be something
/// **both peers independently reach the same answer with**, or the session ends up
/// with two hosts (conflicting rules, mutual plug-in kicks) or none (nobody
/// broadcasts rules, so the host's chosen stakes are silently dropped).
///
/// An invite gives both sides the same fact to key off: the inviter hosts, and each
/// side knows which one it was. Auto-match has no invite and no intent to appeal
/// to, so both sides fall back to the same arbitrary-but-identical rule instead.
enum OnlineRole: Equatable {
    /// We sent the invite, so we host.
    case hosting
    /// We accepted an invite; the sender hosts.
    case guest(hostID: String)
    /// Nobody invited anybody (Quick Match): lowest `gamePlayerID` hosts.
    case autoMatch
}

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
    /// `AppModel` wires this to `MultiplayerSession.startGameCenter`.
    var onMatch: ((GKMatch, OnlineRole) -> Void)?

    /// Retained delegates for matchmaker controllers we present ourselves (invite
    /// flows). `matchmakerDelegate` is weak, so these must outlive the call — and
    /// there can be more than one at a time (two friends invite you at once), so a
    /// single slot would deallocate the first controller's delegate and leave its
    /// sheet on screen with dead buttons.
    private var inviteCoordinators: [ObjectIdentifier: InviteMatchmakerCoordinator] = [:]

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
    /// Either way we're the inviter, so we host (`OnlineRole.hosting`).
    ///
    /// Returns whether the invite actually went out — the caller must not treat a
    /// knock as answered when it didn't, or the player is dismissed from the host's
    /// list having never been sent anything.
    @discardableResult
    func invite(playerID: String, into match: GKMatch?) async -> Bool {
        let players = await Self.loadPlayers(ids: [playerID])
        guard !players.isEmpty else {
            lastError = "Couldn't find that player on Game Center."
            return false
        }
        let request = makeMatchRequest(playerGroup: playerGroupProvider?() ?? 0)
        request.recipients = players
        if let match {
            do {
                try await GKMatchmaker.shared().addPlayers(to: match, matchRequest: request)
                return true
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        guard let vc = GKMatchmakerViewController(matchRequest: request) else {
            lastError = "Couldn't start that match."
            return false
        }
        present(vc, role: .hosting)
        return true
    }

    /// `GKPlayer.loadPlayers(forIdentifiers:withCompletionHandler:)` is
    /// `NS_SWIFT_DISABLE_ASYNC` — Swift never bridges it to an `async`
    /// overload — and deprecated in favor of `GKLocalPlayer.loadFriends`,
    /// which isn't a real substitute here: it only returns the local player's
    /// *friends*, not an arbitrary Game Center id, which breaks inviting
    /// anyone who isn't already a friend. There's no general replacement, so
    /// this stays on the completion-handler API; marking this wrapper itself
    /// `deprecated` is what silences the warning at its one call site above
    /// without also silencing genuinely-new deprecated-API usage elsewhere.
    @available(*, deprecated, message: "GameKit has no async, non-friends-only replacement for loadPlayers(forIdentifiers:)")
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
        present(vc, role: .guest(hostID: hostID))
    }

    /// Present the matchmaker pre-addressed to `recipients` — the player started a
    /// match with us from the Game Center app, so we're initiating and we host.
    private func presentMatchmaker(recipients: [GKPlayer], playerGroup: Int) {
        let request = makeMatchRequest(playerGroup: playerGroup)
        request.recipients = recipients
        guard let vc = GKMatchmakerViewController(matchRequest: request) else {
            lastError = "Couldn't start that match."
            return
        }
        present(vc, role: .hosting)
    }

    private func present(_ vc: GKMatchmakerViewController, role: OnlineRole) {
        let key = ObjectIdentifier(vc)
        let coordinator = InviteMatchmakerCoordinator { [weak self] result in
            guard let self else { return }
            self.inviteCoordinators[key] = nil      // only this one — others may still be up
            switch result {
            case .matched(let match): self.onMatch?(match, role)
            case .cancelled: break
            case .failed(let message): self.lastError = message
            }
        }
        inviteCoordinators[key] = coordinator
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
