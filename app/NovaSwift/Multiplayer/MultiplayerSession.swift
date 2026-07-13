import Foundation
import Combine
import NovaSwiftNet

/// App-level owner of a live multiplayer `NetSession` (from `NovaSwiftNet`),
/// bridged into SwiftUI as an `ObservableObject`. Hangs off `AppModel` so every
/// view reaches it via `model.session`.
///
/// P0 scope: local (same-Wi-Fi) sessions over `MultipeerTransport`, presence, and
/// session-wide chat. Game Center / join-code transports and Layer-2 simulation
/// sync land in later phases; the `NetSession` seam underneath already supports
/// them.
@MainActor
final class MultiplayerSession: ObservableObject {
    /// A session is running (advertising/browsing + connected or waiting).
    @Published private(set) var isActive = false
    /// Session-wide chat history, oldest-first (mirrors `NetSession.chatLog`).
    @Published private(set) var chatLog: [ChatMessage] = []
    /// Everyone's presence, keyed by player id (mirrors `NetSession.presence`).
    @Published private(set) var presence: [String: PlayerPresence] = [:]
    /// Unread chat count while the panel is closed (drives the badge).
    @Published private(set) var unreadCount = 0
    /// The agreed session rules.
    @Published private(set) var rules: SessionRules = .fullStakes

    /// Stable per-launch id used as the transport peer id / Multipeer display
    /// name. Distinct from the pilot's display name (two friends can share a name).
    let localPlayerID: String = "p-" + String(UUID().uuidString.prefix(8))

    /// Set by the chat UI so incoming messages don't count as unread while open.
    var chatVisible = false {
        didSet { if chatVisible { unreadCount = 0 } }
    }

    private var net: NetSession?
    private var transport: Transport?

    // MARK: - Lifecycle

    /// Start a local same-network session and announce presence. Tears down any
    /// existing session first. No-op on platforms without MultipeerConnectivity.
    func startLocal(displayName: String, systemID: Int, rules: SessionRules = .fullStakes) {
        stop()
        #if canImport(MultipeerConnectivity)
        let mp = MultipeerTransport(playerID: localPlayerID)
        let session = NetSession(transport: mp, rules: rules)
        wire(session)
        transport = mp
        net = session
        self.rules = rules
        session.updateLocalPresence(name: displayName, systemID: systemID)
        session.broadcastRules(rules)
        mp.start()
        isActive = true
        syncPresence()
        #endif
    }

    /// Leave the session and clear all mirrored state.
    func stop() {
        transport?.disconnect()
        net = nil
        transport = nil
        isActive = false
        chatLog = []
        presence = [:]
        unreadCount = 0
    }

    // MARK: - Presence / chat API (used by the app)

    /// Push the local player's location — call on spawn and every system jump.
    /// Safe to call when no session is active.
    func updatePresence(systemID: Int, name: String) {
        net?.updateLocalPresence(name: name, systemID: systemID)
        syncPresence()
    }

    func sendChat(_ text: String) {
        net?.sendChat(text)
        // `onChat` fires for locally-sent too, refreshing `chatLog`.
    }

    /// Other players currently in a given system — for galaxy-map markers.
    func players(inSystem systemID: Int) -> [PlayerPresence] {
        net?.players(inSystem: systemID, excluding: localPlayerID) ?? []
    }

    var localDisplayName: String { net?.localDisplayName ?? "" }

    // MARK: - Wiring

    private func wire(_ session: NetSession) {
        session.onChat = { [weak self] message in
            guard let self else { return }
            self.chatLog = session.chatLog
            if !self.chatVisible && message.playerID != self.localPlayerID {
                self.unreadCount += 1
            }
        }
        session.onPresenceChanged = { [weak self] _ in self?.syncPresence() }
        session.onRulesChanged = { [weak self] rules in self?.rules = rules }
    }

    private func syncPresence() { presence = net?.presence ?? [:] }
}
