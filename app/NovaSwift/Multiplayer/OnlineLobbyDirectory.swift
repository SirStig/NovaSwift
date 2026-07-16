#if canImport(CloudKit) && canImport(GameKit)
import Foundation
import CloudKit
import GameKit
import NovaSwiftNet

/// A public directory of open online lobbies, so players can *find* a game instead
/// of only being invited to one.
///
/// **Why this exists at all:** GameKit has no way to browse other people's open
/// matches over the internet. `GKMatchmaker.queryActivity` returns a bare count,
/// and `startBrowsingForNearbyPlayers` is local Wi-Fi only. So the lobby list has
/// to live somewhere else. CloudKit's public database is that somewhere: Apple
/// hosts it, which keeps the project's "we host no servers" rule (docs/MULTIPLAYER.md)
/// intact.
///
/// **The division of labour:** CloudKit only ever carries *discovery* — an advert
/// and a knock at the door. It never carries gameplay. Once a host accepts a knock
/// it sends a real Game Center invite, and the match, the transport, and every byte
/// of simulation still ride `GKMatch` exactly as before. That keeps the directory
/// off the hot path: if CloudKit is slow or unavailable, invites and quick match
/// still work and only the browsable list degrades.
///
/// **Join is accept-gated.** Listing a lobby doesn't let you into it. A join writes
/// a `JoinRequest` the host sees and must approve; the host's Game Center invite is
/// the only thing that actually forms the match. A stranger can therefore never
/// pull themselves into your game, and your `gamePlayerID` is all they ever learn.
///
/// **Setup this depends on (can't be done from code):** the CloudKit container
/// `iCloud.com.houseofkac.novaswift` needs the `Lobby` and `JoinRequest` record
/// types with queryable/sortable indexes, and the schema promoted to Production
/// before a release build can see it. See `docs/MULTIPLAYER.md`.
@MainActor
final class OnlineLobbyDirectory: ObservableObject {
    /// Open lobbies, freshest first, already filtered for staleness.
    @Published private(set) var lobbies: [OnlineLobby] = []
    /// Knocks at our door — populated only while we're hosting a published lobby.
    @Published private(set) var joinRequests: [OnlineJoinRequest] = []
    /// Where our own outgoing knock stands, for the browser UI.
    @Published var outgoingRequest: OutgoingRequestState = .none
    /// Directory-level trouble (no iCloud account, schema missing, offline). Never
    /// fatal — invites and quick match don't route through here.
    @Published var status: DirectoryStatus = .idle

    enum DirectoryStatus: Equatable {
        case idle
        case loading
        /// The directory is unusable; the message explains why, in player terms.
        case unavailable(String)
        case ready
    }

    enum OutgoingRequestState: Equatable {
        case none
        case sending
        /// Waiting on the host to accept; the invite arrives through GameKit.
        case waiting(lobbyID: String)
        case rejected
        case failed(String)
    }

    /// A lobby record goes stale if its host stops heartbeating — the host crashed,
    /// quit, or lost signal. Two missed beats and we stop listing it, so the browser
    /// never offers a lobby that can't answer.
    private static let heartbeatInterval: TimeInterval = 30
    private static let staleAfter: TimeInterval = 75
    /// How long an unanswered knock stays visible to a host. Long enough to be
    /// noticed between jumps, short enough that abandoned ones disappear.
    private static let requestExpiry: TimeInterval = 180

    /// Pulls the hosted lobby's live roster count and whether it still admits
    /// people, for each heartbeat. Pulled rather than captured at publish time —
    /// a captured count would advertise "1 player" forever no matter who joined.
    var liveStateProvider: (() -> (playerCount: Int, isOpen: Bool))?

    private let database = CKContainer(identifier: "iCloud.com.houseofkac.novaswift").publicCloudDatabase
    private var heartbeatTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var requestPollTask: Task<Void, Never>?
    /// The lobby we currently host, so we can heartbeat and later withdraw it.
    private var publishedLobbyID: CKRecord.ID?
    /// Knocks we've already answered. Needed because we can't delete a record we
    /// didn't create, so an answered request keeps coming back from the query.
    private var dismissedRequestIDs: Set<String> = []

    // MARK: - Hosting

    /// Advertise a lobby we're hosting and start watching for join requests.
    /// Best-effort: a directory failure leaves the session perfectly playable by
    /// invite, so it reports status rather than throwing.
    func publish(_ lobby: OnlineLobby) async {
        let recordID = CKRecord.ID(recordName: lobby.hostPlayerID)   // one lobby per host
        let record = CKRecord(recordType: "Lobby", recordID: recordID)
        lobby.apply(to: record)
        publishedLobbyID = recordID
        do {
            // .allKeys replaces our own previous advert (same host, new lobby)
            // instead of failing on a conflict.
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .allKeys).saveResults
            status = .ready
            startHeartbeat()
            startPollingJoinRequests(lobbyID: lobby.hostPlayerID)
        } catch {
            publishedLobbyID = nil
            status = .unavailable(Self.explain(error))
        }
    }

    /// Keep our advert fresh and its player count honest.
    func updatePublished(playerCount: Int, isOpen: Bool) async {
        guard let recordID = publishedLobbyID else { return }
        do {
            let record = try await database.record(for: recordID)
            record["playerCount"] = playerCount as CKRecordValue
            record["isOpen"] = (isOpen ? 1 : 0) as CKRecordValue
            record["updatedAt"] = Date() as CKRecordValue
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .allKeys).saveResults
        } catch {
            // A failed beat is not worth bothering the player about — the record
            // simply goes stale and drops off other people's lists.
        }
    }

    /// Withdraw our advert and stop all hosting traffic. Called when the session
    /// ends; also on a clean quit.
    func withdraw() async {
        heartbeatTask?.cancel(); heartbeatTask = nil
        requestPollTask?.cancel(); requestPollTask = nil
        joinRequests = []
        guard let recordID = publishedLobbyID else { return }
        publishedLobbyID = nil
        _ = try? await database.modifyRecords(saving: [], deleting: [recordID])
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard let self, !Task.isCancelled else { return }
                let live = self.liveStateProvider?() ?? (playerCount: 1, isOpen: true)
                await self.updatePublished(playerCount: live.playerCount, isOpen: live.isOpen)
            }
        }
    }

    // MARK: - Browsing

    /// Start listing open lobbies. Polls, because CloudKit push subscriptions would
    /// need APNs plumbing for something a lobby list refreshes fine without.
    func startBrowsing(pluginSignature: String) {
        browseTask?.cancel()
        status = .loading
        browseTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLobbies(pluginSignature: pluginSignature)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func stopBrowsing() {
        browseTask?.cancel(); browseTask = nil
        lobbies = []
    }

    private func refreshLobbies(pluginSignature: String) async {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let predicate = NSPredicate(format: "isOpen == 1 AND updatedAt > %@", cutoff as NSDate)
        let query = CKQuery(recordType: "Lobby", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 50)
            let found = results.compactMap { try? $0.1.get() }.compactMap(OnlineLobby.init(record:))
            // Never list our own advert back to us.
            let mine = publishedLobbyID?.recordName
            lobbies = found.filter { $0.hostPlayerID != mine }
            status = .ready
        } catch {
            status = .unavailable(Self.explain(error))
        }
    }

    // MARK: - Join handshake

    /// Knock on a lobby's door. This does **not** join anything — it asks. If the
    /// host accepts, their Game Center invite arrives through
    /// `GameCenterManager`'s listener and starts the session from there.
    func requestJoin(lobby: OnlineLobby, playerID: String, playerName: String,
                     pluginSignature: String) async {
        outgoingRequest = .sending
        let record = CKRecord(recordType: "JoinRequest",
                              recordID: CKRecord.ID(recordName: "\(lobby.hostPlayerID)-\(playerID)"))
        record["lobbyID"] = lobby.hostPlayerID as CKRecordValue
        record["playerID"] = playerID as CKRecordValue
        record["playerName"] = playerName as CKRecordValue
        record["pluginSignature"] = pluginSignature as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .allKeys).saveResults
            outgoingRequest = .waiting(lobbyID: lobby.hostPlayerID)
        } catch {
            outgoingRequest = .failed(Self.explain(error))
        }
    }

    /// Give up on a pending knock.
    func cancelJoinRequest(lobbyID: String, playerID: String) async {
        outgoingRequest = .none
        let id = CKRecord.ID(recordName: "\(lobbyID)-\(playerID)")
        _ = try? await database.modifyRecords(saving: [], deleting: [id])
    }

    private func startPollingJoinRequests(lobbyID: String) {
        requestPollTask?.cancel()
        requestPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshJoinRequests(lobbyID: lobbyID)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshJoinRequests(lobbyID: String) async {
        // Only knocks we haven't answered, and only recent ones: a guest who quit
        // without cleaning up leaves a record we're not allowed to delete, so it has
        // to age out rather than sit in the host's face forever.
        let cutoff = Date().addingTimeInterval(-Self.requestExpiry)
        let predicate = NSPredicate(format: "lobbyID == %@ AND createdAt > %@",
                                    lobbyID, cutoff as NSDate)
        let query = CKQuery(recordType: "JoinRequest", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let (results, _) = try? await database.records(matching: query, resultsLimit: 20)
        else { return }
        joinRequests = results.compactMap { try? $0.1.get() }
            .compactMap(OnlineJoinRequest.init(record:))
            .filter { !dismissedRequestIDs.contains($0.id) }
    }

    /// Answer a knock (accepted or declined) so it stops showing.
    ///
    /// Local-only on purpose. CloudKit's public database gives `_world` read but
    /// reserves write to a record's `_creator`, so a host *cannot* delete a guest's
    /// `JoinRequest` — trying would just fail. So we drop it from our own view and
    /// remember it, the guest deletes its own record once it's in (or cancels), and
    /// anything orphaned by a guest that quit ages out of `refreshJoinRequests`.
    func resolveJoinRequest(_ request: OnlineJoinRequest) async {
        dismissedRequestIDs.insert(request.id)
        joinRequests.removeAll { $0.id == request.id }
    }

    /// Delete our own pending knock — we're in, or we gave up. We're the creator,
    /// so this is the one direction CloudKit does allow.
    func clearMyJoinRequest(playerID: String) async {
        guard case .waiting(let lobbyID) = outgoingRequest else {
            outgoingRequest = .none
            return
        }
        await cancelJoinRequest(lobbyID: lobbyID, playerID: playerID)
    }

    /// Turn a CloudKit failure into something a player can act on. The default
    /// `localizedDescription` for a missing schema or a signed-out account is
    /// inscrutable, and this is exactly where the old code left people stuck.
    private static func explain(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated:
            return "Sign in to iCloud to browse online lobbies. Invites and Quick Match still work without it."
        case .networkUnavailable, .networkFailure:
            return "Can't reach iCloud. Check your connection."
        case .quotaExceeded:
            return "iCloud quota exceeded."
        case .unknownItem:
            return "The lobby directory isn't set up for this build yet."
        case .serverRejectedRequest, .invalidArguments:
            return "iCloud rejected the request — the lobby directory may not be deployed for this build."
        default:
            return ck.localizedDescription
        }
    }
}

// MARK: - Records

/// One advertised lobby. Deliberately thin: enough to decide "do I want in", and
/// nothing that isn't already visible to anyone you'd play with.
struct OnlineLobby: Identifiable, Equatable {
    var id: String { hostPlayerID }
    /// Game Center `gamePlayerID` of the host — the record name, and who an
    /// accepted joiner gets invited by.
    var hostPlayerID: String
    var name: String
    var hostName: String
    var playerCount: Int
    var maxPlayers: Int
    var pluginCount: Int
    /// `PluginManifest.signature`, so the browser can flag an incompatible lobby
    /// before knocking. The full manifest handshake on connect stays authoritative.
    var pluginSignature: String
    var allowPvP: Bool
    var isOpen: Bool
    var updatedAt: Date

    var isFull: Bool { playerCount >= maxPlayers }

    func apply(to record: CKRecord) {
        record["name"] = name as CKRecordValue
        record["hostName"] = hostName as CKRecordValue
        record["hostPlayerID"] = hostPlayerID as CKRecordValue
        record["playerCount"] = playerCount as CKRecordValue
        record["maxPlayers"] = maxPlayers as CKRecordValue
        record["pluginCount"] = pluginCount as CKRecordValue
        record["pluginSignature"] = pluginSignature as CKRecordValue
        record["allowPvP"] = (allowPvP ? 1 : 0) as CKRecordValue
        record["isOpen"] = (isOpen ? 1 : 0) as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    init(hostPlayerID: String, name: String, hostName: String, playerCount: Int,
         maxPlayers: Int, pluginCount: Int, pluginSignature: String,
         allowPvP: Bool, isOpen: Bool = true, updatedAt: Date = Date()) {
        self.hostPlayerID = hostPlayerID
        self.name = name
        self.hostName = hostName
        self.playerCount = playerCount
        self.maxPlayers = maxPlayers
        self.pluginCount = pluginCount
        self.pluginSignature = pluginSignature
        self.allowPvP = allowPvP
        self.isOpen = isOpen
        self.updatedAt = updatedAt
    }

    init?(record: CKRecord) {
        guard let hostPlayerID = record["hostPlayerID"] as? String,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        self.hostPlayerID = hostPlayerID
        self.updatedAt = updatedAt
        name = record["name"] as? String ?? "Lobby"
        hostName = record["hostName"] as? String ?? "Captain"
        playerCount = record["playerCount"] as? Int ?? 1
        maxPlayers = record["maxPlayers"] as? Int ?? 4
        pluginCount = record["pluginCount"] as? Int ?? 0
        pluginSignature = record["pluginSignature"] as? String ?? ""
        allowPvP = (record["allowPvP"] as? Int ?? 0) == 1
        isOpen = (record["isOpen"] as? Int ?? 1) == 1
    }
}

/// A knock at a host's door. The host approves it into a Game Center invite.
struct OnlineJoinRequest: Identifiable, Equatable {
    /// Record name, `"<lobbyID>-<playerID>"` — one pending knock per player per
    /// lobby, so spamming Join can't flood a host.
    var id: String
    var lobbyID: String
    var playerID: String
    var playerName: String
    var pluginSignature: String
    var createdAt: Date

    init?(record: CKRecord) {
        guard let lobbyID = record["lobbyID"] as? String,
              let playerID = record["playerID"] as? String else { return nil }
        id = record.recordID.recordName
        self.lobbyID = lobbyID
        self.playerID = playerID
        playerName = record["playerName"] as? String ?? "Captain"
        pluginSignature = record["pluginSignature"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? Date()
    }
}
#endif
