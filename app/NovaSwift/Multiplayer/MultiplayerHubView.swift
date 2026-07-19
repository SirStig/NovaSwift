import SwiftUI
import NovaSwiftKit
import NovaSwiftNet
#if canImport(GameKit)
import GameKit
#endif

/// The single Multiplayer entry point (from the in-game menu). Before a session
/// it lets you **host** or **join** a named lobby — Local (Wi-Fi) or Online (Game
/// Center) — after configuring the session rules. While in a session it shows the
/// lobby roster with host moderation (kick / ban). Fully responsive: a compact
/// stack on iPhone, comfortably centred on iPad / Mac.
struct MultiplayerHubView: View {
    @EnvironmentObject private var model: AppModel
    /// Called when a session has started and the player should drop back into flight.
    var onEnterFlight: () -> Void
    var onClose: () -> Void

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        NavigationStack {
            Group {
                if model.session.isActive {
                    LobbyRosterView(onEnterFlight: onEnterFlight, onClose: onClose)
                } else {
                    lobbyChooser
                }
            }
            .frame(maxWidth: 560)               // keep line-lengths sane on wide screens
            .frame(maxWidth: .infinity)
            .background(backdrop)
        }
        .sheet(isPresented: Binding(
            get: { model.session.pluginMismatch != nil },
            set: { if !$0 { model.session.pluginMismatch = nil } })) {
            if let mismatch = model.session.pluginMismatch {
                PluginMismatchView(lobbyName: model.session.pluginMismatchLobbyName,
                                   mismatch: mismatch)
            }
        }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var backdrop: some View {
        LinearGradient(colors: [.black, Color(red: 0.04, green: 0.05, blue: 0.09)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Pre-session: choose Local / Online

    @State private var tab: Tab = .local
    private enum Tab: String, CaseIterable, Identifiable { case local = "Local", online = "Online"; var id: String { rawValue } }

    private var lobbyChooser: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                Picker("Mode", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch tab {
                case .local:  LocalLobbySection(onEnterFlight: onEnterFlight)
                case .online: OnlineLobbySection(onEnterFlight: onEnterFlight)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.wave.2.fill").font(.system(size: 34)).foregroundStyle(amber)
            Text("Multiplayer").novaFont(.heading).foregroundStyle(.white)
            Text("Fly, fight, and quest together. Host a lobby or join a friend's.")
                .novaFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
        }
    }
}

// MARK: - Local lobbies (Wi-Fi)

private struct LocalLobbySection: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    @State private var showHostSetup = false

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }

    var body: some View {
        VStack(spacing: 14) {
            Button { showHostSetup = true } label: {
                HubActionLabel(icon: "plus.circle.fill", title: "Host a Lobby",
                               subtitle: "Create a lobby on this Wi-Fi network")
            }
            .buttonStyle(.novaPlain)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nearby Lobbies").novaFont(.button, weight: .medium).foregroundStyle(.white)
                    Spacer()
                    ProgressView().controlSize(.small).tint(amber)
                }
                if model.session.localLobbies.isEmpty {
                    Text("Searching the local network… ask your friend to Host a Lobby.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    ForEach(model.session.localLobbies) { lobby in
                        LobbyRow(lobby: lobby,
                                 compatible: isCompatible(lobby)) { join(lobby) }
                    }
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            .padding(.horizontal)
        }
        .onAppear { model.session.startBrowsingLocalLobbies() }
        .onDisappear { model.session.stopBrowsingLocalLobbies() }
        .sheet(isPresented: $showHostSetup) {
            HostSetupView { name, rules, _ in
                showHostSetup = false
                // The host's own game-speed becomes the whole lobby's shared
                // clock (see `SessionRules.gameSpeedMultiplier`) — guests adopt
                // it via the normal rules broadcast rather than each running
                // their own local setting.
                var rules = rules
                rules.gameSpeedMultiplier = model.settings.gameSpeed.multiplier
                model.session.hostLocalLobby(
                    lobbyName: name, displayName: hostDisplayName,
                    systemID: model.pilot.state.currentSystem,
                    shipTypeID: model.pilot.state.shipType, rules: rules)
                onEnterFlight()
            }
        }
    }

    private var hostDisplayName: String {
        var name = model.pilot.state.pilotName
        if name.isEmpty { name = "Captain" }
        if AppInstance.isSecondary { name += " #\(AppInstance.tag)" }
        return name
    }

    /// Whether our enabled plug-ins look compatible with a lobby, from the
    /// advertised signature (the authoritative check is the full manifest exchange
    /// on connect). Unknown (host advertised no signature) is treated as compatible.
    private func isCompatible(_ lobby: LobbyDescriptor) -> Bool {
        lobby.pluginSignature.isEmpty || lobby.pluginSignature == model.session.localPluginSignature
    }

    private func join(_ lobby: LobbyDescriptor) {
        let compatible = isCompatible(lobby)
        model.session.joinLocalLobby(
            lobby, displayName: hostDisplayName,
            systemID: model.pilot.state.currentSystem,
            shipTypeID: model.pilot.state.shipType)
        // Only drop into flight when compatible. If not, we still connect briefly so
        // the host's full manifest arrives — that populates `pluginMismatch` and the
        // hub shows exactly what to install/disable, without ever entering flight.
        if compatible {
            model.session.stopBrowsingLocalLobbies()
            onEnterFlight()
        }
    }
}

private struct LobbyRow: View {
    let lobby: LobbyDescriptor
    /// Whether our enabled plug-ins match the lobby's advertised set.
    var compatible: Bool
    var onJoin: () -> Void
    private var color: Color { GalaxyMapView.playerColor(for: lobby.id) }

    private var pluginText: String {
        switch lobby.pluginCount {
        case 0: return "No plug-ins"
        case 1: return "1 plug-in"
        default: return "\(lobby.pluginCount) plug-ins"
        }
    }

    var body: some View {
        Button(action: onJoin) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lobby.name).novaFont(.button, weight: .medium).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text("Host: \(lobby.hostName)").novaFont(.caption).foregroundStyle(.secondary)
                        Text("·").novaFont(.caption).foregroundStyle(.secondary)
                        Label("\(lobby.playerCount)", systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                            .novaFont(.caption, weight: .medium)
                            .foregroundStyle(color)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: compatible ? "puzzlepiece.extension.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(compatible ? pluginText : "Plug-ins don't match")
                            .novaFont(.caption)
                    }
                    .foregroundStyle(compatible ? Color.secondary : Color(red: 1, green: 0.6, blue: 0.2))
                }
                Spacer()
                Text(compatible ? "Join" : "Details").novaFont(.caption, weight: .bold)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill((compatible ? color : Color(red: 1, green: 0.6, blue: 0.2)).opacity(0.25)))
                    .foregroundStyle(compatible ? color : Color(red: 1, green: 0.6, blue: 0.2))
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.novaPlain)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }
}

// MARK: - Online lobbies (Game Center)

/// Online is split into the two things a player actually wants to do — open a
/// lobby of your own and invite people, or join someone. The old single "Play
/// Online" button hid both behind one ambiguous tap into a bare GameKit sheet.
private struct OnlineLobbySection: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    #if canImport(GameKit)
    @State private var showHostSetup = false
    @State private var showMatchmaker = false
    /// Which button opened the matchmaker. Hosting means we own the lobby; Quick
    /// Match means nobody invited anybody and both peers resolve a host by id.
    @State private var pendingRole: OnlineRole = .autoMatch
    /// Nil until the activity query answers; drives honest quick-match copy.
    @State private var playersSearching: Int?
    #endif

    var body: some View {
        VStack(spacing: 14) {
            #if canImport(GameKit)
            if model.gameCenter.isAuthenticated {
                authenticatedActions
            } else {
                HubActionLabel(icon: "globe.badge.chevron.backward", title: "Sign in to Game Center",
                               subtitle: "Online play needs Game Center. Sign in from the system Settings, then reopen this.")
                    .opacity(0.7)
            }
            if let errorText = model.gameCenter.lastError {
                errorCard(errorText)
            }
            #else
            HubActionLabel(icon: "globe.slash", title: "Online unavailable",
                           subtitle: "Game Center isn't available on this platform.").opacity(0.6)
            #endif
        }
        .padding(.horizontal)
        #if canImport(GameKit)
        .task { await refreshActivity() }
        .sheet(isPresented: $showHostSetup) {
            HostSetupView(showsPublicListing: true) { name, rules, listPublicly in
                showHostSetup = false
                beginHosting(name: name, rules: rules, listPublicly: listPublicly)
            }
        }
        .sheet(isPresented: $showMatchmaker) {
            GameCenterMatchmakerView(
                playerGroup: model.currentPluginManifest().groupID,
                onMatch: { match in
                    showMatchmaker = false
                    model.startOnlineSession(match: match, role: pendingRole)
                    onEnterFlight()
                },
                onCancel: { showMatchmaker = false; model.onlineHostConfig = nil },
                onError: { showMatchmaker = false; model.gameCenter.lastError = $0 })
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)   // the matchmaker needs real height
                #endif
        }
        #endif
    }

    #if canImport(GameKit)
    @ViewBuilder
    private var authenticatedActions: some View {
        Button { showHostSetup = true } label: {
            HubActionLabel(icon: "plus.circle.fill", title: "Host a Lobby",
                           subtitle: "Name it, set the stakes, then invite friends over Game Center")
        }
        .buttonStyle(.novaPlain)

        Button {
            model.onlineHostConfig = nil        // joining, not hosting
            model.gameCenter.lastError = nil
            pendingRole = .autoMatch
            showMatchmaker = true
        } label: {
            HubActionLabel(icon: "bolt.horizontal.circle.fill", title: "Quick Match",
                           subtitle: quickMatchSubtitle)
        }
        .buttonStyle(.novaPlain)

        Text("Invites from friends open automatically — you don't need this screen for them.")
            .novaFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

        #if canImport(CloudKit)
        PublicLobbyList(directory: model.lobbyDirectory)
        #endif
    }

    /// Tells the player what the queue actually looks like. An empty queue is the
    /// normal case for a small game, and it isn't an error — saying so beats a
    /// spinner that looks broken.
    private var quickMatchSubtitle: String {
        switch playersSearching {
        case .none: return "Match with anyone running your exact plug-in set"
        case .some(0): return "Nobody's searching right now — you'd be first in the queue"
        case .some(1): return "1 captain searching with your plug-in set"
        case .some(let n): return "\(n) captains searching with your plug-in set"
        }
    }

    private func refreshActivity() async {
        playersSearching = await model.gameCenter.queryPlayerCount(
            playerGroup: model.currentPluginManifest().groupID)
    }

    private func beginHosting(name: String, rules: SessionRules, listPublicly: Bool) {
        var rules = rules
        // The host's own game-speed becomes the lobby's shared clock, exactly as
        // local hosting does (see `SessionRules.gameSpeedMultiplier`).
        rules.gameSpeedMultiplier = model.settings.gameSpeed.multiplier
        // Stashed until the match forms — matchmaking is slow and the invite may
        // even be accepted from outside the app.
        let config = AppModel.OnlineHostConfig(lobbyName: name, rules: rules,
                                               listPublicly: listPublicly)
        model.onlineHostConfig = config
        model.gameCenter.lastError = nil
        pendingRole = .hosting
        #if canImport(CloudKit)
        // Advertise now, not after a match forms: an empty lobby is precisely the
        // one worth listing, and there's no match until someone has joined.
        if listPublicly {
            Task { await model.publishOnlineLobby(config) }
        }
        #endif
        showMatchmaker = true
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Game Center couldn't do that", systemImage: "exclamationmark.triangle.fill")
                .novaFont(.caption, weight: .bold)
                .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.2))
            Text(text).novaFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") { model.gameCenter.lastError = nil }
                .novaFont(.caption).buttonStyle(.novaPlain).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }
    #endif
}

// MARK: - Public lobby list

#if canImport(CloudKit) && canImport(GameKit)
/// Open lobbies other players have chosen to advertise. Joining is a *request* —
/// the host approves it and their Game Center invite is what actually admits you,
/// so this list can never pull you into a game (or anyone into yours).
private struct PublicLobbyList: View {
    @EnvironmentObject private var model: AppModel
    /// Observed directly: the directory is its own `ObservableObject` and `AppModel`
    /// doesn't forward its changes.
    @ObservedObject var directory: OnlineLobbyDirectory

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var warn: Color { Color(red: 1, green: 0.6, blue: 0.2) }
    private var mySignature: String { model.currentPluginManifest().signature }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Public Lobbies").novaFont(.button, weight: .medium).foregroundStyle(.white)
                Spacer()
                if case .loading = directory.status {
                    ProgressView().controlSize(.small).tint(amber)
                }
            }

            if case .failed(let why) = directory.outgoingRequest {
                Text(why).novaFont(.caption).foregroundStyle(warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch directory.status {
            case .unavailable(let why):
                Text(why).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            default:
                if directory.lobbies.isEmpty {
                    Text("No public lobbies right now. Host one, or have a friend invite you.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                } else {
                    ForEach(directory.lobbies) { lobby in
                        row(lobby)
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        .task { directory.startBrowsing() }
        .onDisappear { directory.stopBrowsing() }
    }

    @ViewBuilder
    private func row(_ lobby: OnlineLobby) -> some View {
        let compatible = lobby.pluginSignature.isEmpty || lobby.pluginSignature == mySignature
        let waiting = directory.outgoingRequest == .waiting(lobbyID: lobby.hostPlayerID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle().fill(GalaxyMapView.playerColor(for: lobby.hostPlayerID))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lobby.name).novaFont(.button, weight: .medium).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text("Host: \(lobby.hostName)").novaFont(.caption).foregroundStyle(.secondary)
                        Text("·").novaFont(.caption).foregroundStyle(.secondary)
                        Text("\(lobby.playerCount)/\(lobby.maxPlayers)")
                            .novaFont(.caption, weight: .medium).foregroundStyle(.secondary)
                        if lobby.allowPvP {
                            Text("· PvP").novaFont(.caption, weight: .medium).foregroundStyle(warn)
                        }
                    }
                    if !compatible {
                        Label("Plug-ins don't match", systemImage: "exclamationmark.triangle.fill")
                            .novaFont(.caption).foregroundStyle(warn)
                    }
                }
                Spacer(minLength: 0)
                joinButton(lobby, compatible: compatible, waiting: waiting)
            }
            if waiting {
                Text("Waiting for \(lobby.hostName) to let you in. The invite opens by itself.")
                    .novaFont(.caption).foregroundStyle(amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    @ViewBuilder
    private func joinButton(_ lobby: OnlineLobby, compatible: Bool, waiting: Bool) -> some View {
        if waiting {
            Button("Cancel") {
                Task {
                    await directory.cancelJoinRequest(lobbyID: lobby.hostPlayerID,
                                                      playerID: GKLocalPlayer.local.gamePlayerID)
                }
            }
            .novaFont(.caption, weight: .bold).buttonStyle(.novaPlain).foregroundStyle(.secondary)
        } else if lobby.isFull {
            pill("Full", .gray)
        } else if !compatible {
            pill("Can't join", warn)
        } else {
            Button {
                Task {
                    await directory.requestJoin(
                        lobby: lobby,
                        playerID: GKLocalPlayer.local.gamePlayerID,
                        playerName: model.multiplayerDisplayName,
                        pluginSignature: mySignature)
                }
            } label: {
                pill("Ask to Join", amber)
            }
            .buttonStyle(.novaPlain)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).novaFont(.caption, weight: .bold)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.25)))
            .foregroundStyle(color)
    }
}
#endif

// MARK: - Plug-in mismatch

/// Explains why a join was refused and exactly what to change: which plug-ins to
/// install + enable, which to disable, and which are the wrong version. Shown when
/// a joiner's enabled-plug-in set doesn't match the host's.
private struct PluginMismatchView: View {
    @Environment(\.dismiss) private var dismiss
    let lobbyName: String
    let mismatch: PluginMismatch

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var warn: Color { Color(red: 1.0, green: 0.6, blue: 0.2) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 34)).foregroundStyle(warn)
                        Text("Plug-ins don't match")
                            .novaFont(.heading).foregroundStyle(.white)
                        Text("To join \(lobbyName.isEmpty ? "this lobby" : "“\(lobbyName)”") you need the same enabled plug-ins as the host.")
                            .novaFont(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    section("Install & enable", systemImage: "arrow.down.circle.fill",
                            color: .green, plugins: mismatch.missing,
                            note: "The host has these — get them from the Plug-ins screen and enable them.")
                    section("Disable", systemImage: "minus.circle.fill",
                            color: warn, plugins: mismatch.extra,
                            note: "The host isn't running these — turn them off in the Plug-ins screen.")
                    section("Update to the host's version", systemImage: "arrow.triangle.2.circlepath",
                            color: amber, plugins: mismatch.wrongVersion,
                            note: "You have these, but a different version. Reinstall the host's copy.")

                    Text("Change plug-ins from the main menu’s Plug-ins screen, then reopen Multiplayer.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Can't Join")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String, color: Color,
                         plugins: [PluginRequirement], note: String) -> some View {
        if !plugins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .novaFont(.button, weight: .medium).foregroundStyle(color)
                ForEach(plugins, id: \.id) { p in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(p.name.isEmpty ? p.id : p.name)
                            .novaFont(.caption, weight: .medium).foregroundStyle(.white)
                    }
                }
                Text(note).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        }
    }
}

// MARK: - Shared bits

/// A large, tappable action card used across the hub.
private struct HubActionLabel: View {
    let icon: String, title: String, subtitle: String
    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(amber).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).novaFont(.button, weight: .medium).foregroundStyle(.white)
                Text(subtitle).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(amber.opacity(0.25)))
        .padding(.horizontal)
    }
}
