import Foundation
import Combine
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftENet

/// One row of the Multiplayer hub's combined Browse list. ENet servers (saved / LAN / public), Apple-only
/// MultipeerConnectivity lobbies, public CloudKit lobbies and Game Center all render through the same row UI.
struct BrowseEntry: Identifiable, Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case saved = "Saved", nearby = "Nearby", publicServer = "Public", gameCenter = "Game Center", onlineLobby = "Online lobby"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .saved: return "star.fill"
            case .nearby: return "wifi"
            case .publicServer: return "globe"
            case .gameCenter: return "gamecontroller.fill"
            case .onlineLobby: return "person.3.fill"
            }
        }
    }

    /// What Join does.
    enum Kind: Equatable {
        case enet(ServerRow)          // direct ENet join (Godot players, dedicated servers, other Apple devices)
        case multipeer(LobbyDescriptor)
        case onlineLobby(String)      // CloudKit lobby, by its host player id (join = a request the host approves)
        case gameCenterQuickMatch
    }

    var id: String
    /// Primary source first; extra tags appear when the same server is in several lists (merged duplicates).
    var sources: [Source]
    var name: String
    var detail: String
    var players: Int
    var maxPlayers: Int
    var pingMilliseconds: Int
    var locked: Bool
    var online: Bool
    var compatible: Bool
    var differentVersion: Bool
    var region: String
    var kind: Kind
    /// Plug-ins the server requires (ENet rows), for the "Requires:" line with ✓ / ✗.
    var requirements: PluginRequirements?
    var rules: String

    var primary: Source { sources.first ?? .publicServer }
    var address: CrossPlayAddress? { if case .enet(let r) = kind { return r.address } else { return nil } }
}

/// The user's browse filters (chips + search), shared by the hub and tests.
struct BrowseFilter: Equatable {
    var search = ""
    /// nil = All.
    var source: BrowseEntry.Source?
    var compatibleOnly = false
    var hasPlayers = false
    var noPassword = false
    var region: String?

    func apply(_ entries: [BrowseEntry]) -> [BrowseEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            if let source {
                // The Game Center chip also covers public CloudKit lobbies (both are Apple-only online play).
                let match = source == .gameCenter ? (e.sources.contains(.gameCenter) || e.sources.contains(.onlineLobby)) : e.sources.contains(source)
                if !match { return false }
            }
            if compatibleOnly, !e.compatible { return false }
            if hasPlayers, e.players < 1 { return false }
            if noPassword, e.locked { return false }
            if let region, !region.isEmpty, e.region != region { return false }
            if !q.isEmpty, !(e.name.lowercased().contains(q) || e.detail.lowercased().contains(q)) { return false }
            return true
        }
    }
}

/// An open public CloudKit lobby, reduced to what the combined list needs (the CloudKit types are not available everywhere).
struct OnlineLobbyInfo: Equatable {
    var id: String            // host player id
    var name: String
    var hostName: String
    var players: Int
    var maxPlayers: Int
    var allowPvP: Bool
    var compatible: Bool
}

/// Cross-play state behind the hub: the combined server list (saved / LAN / public directory, each live-pinged),
/// favourites + recent addresses, and the plug-in "borrow the server's set" flow.
@MainActor
final class CrossPlayModel: ObservableObject {
    // Server lists
    @Published private(set) var savedServers: [SavedServer]
    @Published private(set) var recent: [CrossPlayAddress]
    @Published private(set) var directoryStatus: ServerDirectoryClient.Status = .idle
    @Published private(set) var directory: [DirectoryServer] = []
    @Published private(set) var lan: [LANServer] = []
    @Published private(set) var lanError = ""
    /// Live answers keyed by "host:port" (lower-case).
    @Published private(set) var live: [String: (beacon: ServerBeacon, rtt: Int)] = [:]
    @Published private(set) var probing = false
    private var probed: Set<String> = []
    /// This install's gameplay plug-ins, for the ✓ / ✗ on rows. Refreshed by the hub.
    @Published var localRequirements = PluginRequirements()

    // Join + plug-in flow
    /// A short message for the hub banner (join failures, restore notes).
    @Published var notice: String?
    /// The plug-in dialog, when joining needs the player's plug-ins changed.
    @Published var pluginPlan: PluginJoinPlan?
    /// A join in progress (connecting / installing), for the hub overlay.
    @Published var busy: String?
    /// The player's own enabled plug-ins, remembered while a server's set is borrowed; nil = not borrowed.
    var borrowedFrom: Set<String>?
    /// The ENet join in flight (or last attempted), so a late "plug-ins" refusal can be retried.
    var lastJoin: PendingENetJoin?
    /// True from tapping Join until the session is up or fails: the hub closes itself when it goes live.
    @Published var joinInFlight = false
    var cancellables = Set<AnyCancellable>()

    let savedStore = SavedServersStore()
    private let directoryClient = ServerDirectoryClient()
    private let prober = ServerStatusProber()
    private let lanService = LANBeaconService()

    init() {
        savedServers = savedStore.saved
        recent = savedStore.recent
    }

    // MARK: Lifecycle (hub appears / disappears)

    func start() {
        directory = directoryClient.servers
        lanService.onServers = { [weak self] list in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lan = list } }
        }
        if !lanService.startListening() { lanError = lanService.lastError }
        refreshDirectory(force: false)
        probe()
    }

    func stop() {
        lanService.onServers = nil
        lanService.stop()
        prober.cancel()
        probing = false
        lan = []
    }

    /// The beacon announcer used while hosting (kept here so it outlives the hub).
    let announcer = LANBeaconService()

    func refreshDirectory(force: Bool) {
        directoryClient.refresh(force: force) { [weak self] status, servers in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.directoryStatus = status
                    self.directory = servers
                    self.probe()
                }
            }
        }
    }

    /// Live-pings the saved servers and the directory (at most 60 per cycle, like the Godot browser).
    func probe() {
        let addrs = savedServers.map(\.address) + directory.map(\.address)
        var seen = Set<String>()
        let unique = addrs.filter { seen.insert("\($0.host.lowercased()):\($0.port)").inserted }
        guard !unique.isEmpty else { probing = false; return }
        probing = true
        probed = Set(unique.prefix(ServerStatusProber.maxPerCycle).map { "\($0.host.lowercased()):\($0.port)" })
        var pending = probed.count
        prober.probe(unique) { [weak self] addr, result in
            guard let self else { return }
            let key = "\(addr.host.lowercased()):\(addr.port)"
            if let result { self.live[key] = (result.beacon, result.rttMilliseconds) } else { self.live[key] = nil }
            self.probed.remove(key)
            pending -= 1
            if pending <= 0 { self.probing = false }
        }
    }

    // MARK: Favourites / recent

    func save(_ s: SavedServer) { savedServers = savedStore.save(s); probe() }
    func removeSaved(host: String, port: Int) { savedServers = savedStore.remove(host: host, port: port) }
    func isSaved(_ a: CrossPlayAddress) -> Bool { savedStore.isSaved(host: a.host, port: a.port) }
    func noteRecent(_ a: CrossPlayAddress) { recent = savedStore.addRecent(a) }
    func clearRecent() { savedStore.clearRecent(); recent = [] }

    // MARK: Combined list

    private func key(_ a: CrossPlayAddress) -> String { "\(a.host.lowercased()):\(a.port)" }

    private func row(address: CrossPlayAddress, name: String, entry: DirectoryServer?) -> ServerRow {
        let k = key(address)
        let l = live[k]
        let checking = probed.contains(k)
        if let entry { return ServerRow(entry: entry, live: l?.beacon, rtt: l?.rtt, checking: checking) }
        return ServerRow(address: address, name: name, live: l?.beacon, rtt: l?.rtt, checking: checking)
    }

    /// Saved first, then Nearby (LAN beacons + Apple-only lobbies), then Public, then Game Center / online lobbies.
    /// The same host:port in several lists collapses to one row carrying every source tag.
    func entries(multipeer: [LobbyDescriptor], onlineLobbies: [OnlineLobbyInfo], gameCenterAvailable: Bool,
                 localPluginSignature: String) -> [BrowseEntry] {
        var out: [BrowseEntry] = []
        var index: [String: Int] = [:]

        func add(_ e: BrowseEntry, key: String?) {
            if let key, let i = index[key] {
                for s in e.sources where !out[i].sources.contains(s) { out[i].sources.append(s) }
                // Prefer the live answer's richer data.
                if out[i].requirements == nil { out[i].requirements = e.requirements }
                if out[i].region.isEmpty { out[i].region = e.region }
                if out[i].detail.isEmpty { out[i].detail = e.detail }
                return
            }
            if let key { index[key] = out.count }
            out.append(e)
        }

        func enet(_ row: ServerRow, source: BrowseEntry.Source, detail: String) -> BrowseEntry {
            BrowseEntry(id: "enet:" + row.id, sources: [source], name: row.name, detail: detail,
                        players: row.players, maxPlayers: row.maxPlayers, pingMilliseconds: row.pingMilliseconds,
                        locked: row.passwordProtected, online: row.state == .online, compatible: row.state != .offline && row.isCompatible || row.state == .checking,
                        differentVersion: row.differentAppVersion, region: row.region, kind: .enet(row),
                        requirements: row.requirements, rules: row.rules)
        }

        // Saved
        for s in savedServers {
            let dir = directory.first { $0.key == key(s.address) }
            let r = row(address: s.address, name: s.name, entry: dir)
            var rr = r; rr.name = s.name
            add(enet(rr, source: .saved, detail: s.address.formatted), key: key(s.address))
        }
        // Nearby: ENet beacons
        for l in lan {
            let r = ServerRow(address: l.address, name: l.beacon.name, live: l.beacon, rtt: nil, checking: false)
            add(enet(r, source: .nearby, detail: l.address.formatted + (l.beacon.dedicated ? " · dedicated" : "")), key: key(l.address))
        }
        // Nearby: Apple-only (Multipeer) lobbies
        for m in multipeer {
            let compatible = m.pluginSignature.isEmpty || m.pluginSignature == localPluginSignature
            add(BrowseEntry(id: "mp:" + m.id, sources: [.nearby], name: m.name, detail: "Host: \(m.hostName) · Apple devices",
                            players: m.playerCount, maxPlayers: 0, pingMilliseconds: -1, locked: false, online: true,
                            compatible: compatible, differentVersion: false, region: "", kind: .multipeer(m),
                            requirements: nil, rules: ""), key: nil)
        }
        // Public directory
        for d in directory {
            let r = row(address: d.address, name: d.name, entry: d)
            let detail = [ServerDirectory.regionTitle(d.region), d.ownerName.isEmpty ? nil : "by \(d.ownerName)"].compactMap { $0 }.joined(separator: " · ")
            add(enet(r, source: .publicServer, detail: detail), key: key(d.address))
        }
        // Game Center + public CloudKit lobbies
        if gameCenterAvailable {
            add(BrowseEntry(id: "gc:quickmatch", sources: [.gameCenter], name: "Quick Match",
                            detail: "Match with any captain running your plug-in set · invites open by themselves",
                            players: 0, maxPlayers: 0, pingMilliseconds: -1, locked: false, online: true, compatible: true,
                            differentVersion: false, region: "", kind: .gameCenterQuickMatch, requirements: nil, rules: ""), key: nil)
        }
        for o in onlineLobbies {
            add(BrowseEntry(id: "ck:" + o.id, sources: [.onlineLobby], name: o.name,
                            detail: "Host: \(o.hostName)" + (o.allowPvP ? " · PvP" : ""),
                            players: o.players, maxPlayers: o.maxPlayers, pingMilliseconds: -1, locked: false, online: true,
                            compatible: o.compatible, differentVersion: false, region: "", kind: .onlineLobby(o.id),
                            requirements: nil, rules: ""), key: nil)
        }
        return out.sorted(by: Self.order)
    }

    /// Saved pinned on top, then Nearby, Public, Game Center; inside a group online first by ping, then name.
    static func order(_ a: BrowseEntry, _ b: BrowseEntry) -> Bool {
        let sources = BrowseEntry.Source.allCases
        let ga = a.sources.contains(.saved) ? -1 : (sources.firstIndex(of: a.primary) ?? 9)
        let gb = b.sources.contains(.saved) ? -1 : (sources.firstIndex(of: b.primary) ?? 9)
        if ga != gb { return ga < gb }
        if a.online != b.online { return a.online }
        if a.online, a.pingMilliseconds >= 0, b.pingMilliseconds >= 0, a.pingMilliseconds != b.pingMilliseconds {
            return a.pingMilliseconds < b.pingMilliseconds
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// The regions present in the directory, for the region chip.
    var availableRegions: [String] { Array(Set(directory.map(\.region))).sorted() }
}

/// Everything the plug-in dialog needs: what the server requires, how this install differs, and what can be fixed
/// automatically from the plug-in catalog.
struct PluginJoinPlan: Identifiable {
    let id = UUID()
    var serverName: String
    var requirements: PluginRequirements
    var compatibility: PluginCompatibility
    /// Required plug-ins already installed here but switched off: they only need enabling for the session.
    var installedDisabled: [PluginRequirement]
    /// Required plug-ins missing or at another version that ARE in the catalog (can be installed in one click).
    var installable: [PluginRequirement]
    /// Required plug-ins that are NOT in the catalog (the player must find them).
    var unavailable: [PluginRequirement]
    /// The server's total conversion is installed here but not enabled.
    var tcInstalledLocally: Bool
    var join: PendingENetJoin
    var working: String?
    var error: String?

    /// Everything required is in the catalog (or already installed): the simple one-click dialog applies.
    var isSimple: Bool { unavailable.isEmpty && (compatibility.wrongTotalConversion == nil || tcInstalledLocally || installable.contains { $0.id == compatibility.wrongTotalConversion }) }
}

/// A queued ENet join, kept while the plug-in dialog or the data swap runs.
struct PendingENetJoin {
    var address: CrossPlayAddress
    var name: String
    var password: String
    var save: SavedServer?
}
