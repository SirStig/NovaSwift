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
            .buttonStyle(.plain)

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
                        LobbyRow(lobby: lobby) { join(lobby) }
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
            HostSetupView { name, rules in
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

    private func join(_ lobby: LobbyDescriptor) {
        model.session.stopBrowsingLocalLobbies()
        model.session.joinLocalLobby(
            lobby, displayName: hostDisplayName,
            systemID: model.pilot.state.currentSystem,
            shipTypeID: model.pilot.state.shipType)
        onEnterFlight()
    }
}

private struct LobbyRow: View {
    let lobby: LobbyDescriptor
    var onJoin: () -> Void
    private var color: Color { GalaxyMapView.playerColor(for: lobby.id) }

    var body: some View {
        Button(action: onJoin) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lobby.name).novaFont(.button, weight: .medium).foregroundStyle(.white)
                    Text("Host: \(lobby.hostName)").novaFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Join").novaFont(.caption, weight: .bold)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.25)))
                    .foregroundStyle(color)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }
}

// MARK: - Online lobbies (Game Center)

private struct OnlineLobbySection: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    #if canImport(GameKit)
    @State private var showMatchmaker = false
    @State private var errorText: String?
    #endif

    var body: some View {
        VStack(spacing: 14) {
            #if canImport(GameKit)
            if model.gameCenter.isAuthenticated {
                Button { showMatchmaker = true } label: {
                    HubActionLabel(icon: "globe", title: "Play Online",
                                   subtitle: "Invite friends or auto-match over the internet")
                }
                .buttonStyle(.plain)
                if let errorText {
                    Text(errorText).novaFont(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
            } else {
                HubActionLabel(icon: "globe.badge.chevron.backward", title: "Sign in to Game Center",
                               subtitle: "Online play needs Game Center. Sign in from the system Settings, then reopen this.")
                    .opacity(0.7)
            }
            #else
            HubActionLabel(icon: "globe.slash", title: "Online unavailable",
                           subtitle: "Game Center isn't available on this platform.").opacity(0.6)
            #endif
        }
        .padding(.horizontal)
        #if canImport(GameKit)
        .sheet(isPresented: $showMatchmaker) {
            GameCenterMatchmakerView(
                onMatch: { match in
                    showMatchmaker = false
                    model.session.startGameCenter(
                        match: match, displayName: onlineDisplayName,
                        systemID: model.pilot.state.currentSystem,
                        shipTypeID: model.pilot.state.shipType)
                    onEnterFlight()
                },
                onCancel: { showMatchmaker = false },
                onError: { showMatchmaker = false; errorText = $0 })
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)   // the matchmaker needs real height
                #endif
        }
        #endif
    }

    #if canImport(GameKit)
    private var onlineDisplayName: String {
        let name = model.pilot.state.pilotName
        return name.isEmpty ? "Captain" : name
    }
    #endif
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
