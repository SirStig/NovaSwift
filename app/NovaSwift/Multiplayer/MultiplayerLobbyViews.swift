import SwiftUI
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftENet

/// Who can join a hosted game (the Host form's single choice, instead of four separate screens).
enum HostAudience: String, CaseIterable, Identifiable {
    case friends = "Friends"        // Game Center invite
    case publicLobby = "Online"     // Game Center + listed in the public CloudKit lobby list
    case nearby = "Nearby"          // MultipeerConnectivity, Apple devices on this Wi-Fi
    case direct = "Direct / IP"     // ENet: Godot players, dedicated-server style, anyone with the address
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .friends: return "Invite friends through Game Center. Apple devices only."
        case .publicLobby: return "Listed publicly; people ask to join and you approve each. Apple devices only."
        case .nearby: return "Anyone on this Wi-Fi network running NovaSwift on an Apple device."
        case .direct: return "Anyone with your address, including Linux, Windows and Steam Deck players. Needs the port reachable."
        }
    }
}

/// Everything the Host form collects.
struct HostRequest {
    var audience: HostAudience
    var name: String
    var rules: SessionRules
    var port: Int
    var password: String
    var maxPlayers: Int
    var announceOnLAN: Bool
}

/// Configure a lobby before it opens: its name and the session rules (stakes).
/// Presented when you tap "Host a Lobby". Responsive — a scrolling stack that
/// fits an iPhone and centres on larger screens.
struct HostSetupView: View {
    @Environment(\.dismiss) private var dismiss
    /// Offer the public-listing choice. Online only — a local lobby is already
    /// only visible to the Wi-Fi network it's on, so there's nothing to opt into.
    var showsPublicListing = false
    /// (lobbyName, rules, listPublicly) — start hosting. `listPublicly` is always
    /// false unless `showsPublicListing`.
    var onHost: (String, SessionRules, Bool) -> Void
    /// Non-empty: show the "Who can join" choice (and, for Direct / IP, port / password / players). The Host
    /// button then calls `onHostRequest` instead of `onHost`.
    var audiences: [HostAudience] = []
    var onHostRequest: ((HostRequest) -> Void)? = nil

    @State private var audience: HostAudience = .direct
    @State private var portText = String(CrossPlayProtocol.defaultPort)
    @State private var password = ""
    @State private var maxPlayers = 4
    @State private var announceOnLAN = true
    @State private var lobbyName = ""
    /// Off by default: publishing puts your pilot name and lobby name in a list
    /// every player can read, and that should be a decision, not a surprise.
    @State private var listPublicly = false
    @State private var preset: Preset = .fullStakes
    @State private var allowPvP = true
    @State private var friendlyFire = true
    @State private var pvpDamageReal = true
    @State private var deathReal = true
    @State private var allowTrade = true

    private enum Preset: String, CaseIterable, Identifiable {
        case safe = "Co-op", fullStakes = "Full Stakes"
        var id: String { rawValue }
    }
    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !audiences.isEmpty {
                        field(title: "Who can join") {
                            NovaSegmentedPicker(selection: $audience, options: audiences) { $0.rawValue }
                            Text(audience.blurb).novaFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    field(title: "Lobby Name") {
                        #if os(tvOS)
                        // Cursor-clickable stand-in for the fullscreen
                        // keyboard (see TVTextEntry.swift).
                        TVCursorTextField(placeholder: "e.g. \"Ares Rescue\"", text: $lobbyName)
                        #else
                        TextField("e.g. \"Ares Rescue\"", text: $lobbyName)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                            .foregroundStyle(.white)
                            .padTextEntry("Lobby Name", text: $lobbyName)
                        #endif
                    }

                    field(title: "Stakes") {
                        NovaSegmentedPicker(selection: $preset, options: Array(Preset.allCases)) { $0.rawValue }
                        .onChange(of: preset) { _, new in
                            // Apply the preset's defaults, still tweakable below.
                            let r: SessionRules = new == .safe ? .safe : .fullStakes
                            allowPvP = r.allowPvP
                            friendlyFire = r.friendlyFire
                            pvpDamageReal = r.pvpDamageReal
                            deathReal = r.deathReal
                            allowTrade = r.allowTrade
                        }
                        Text(preset == .safe
                             ? "Friendly co-op. Players can't damage each other."
                             : "Real consequences. PvP and full damage are on.")
                            .novaFont(.caption).foregroundStyle(.secondary)
                    }

                    field(title: "Combat") {
                        Toggle("Allow PvP — players can attack each other", isOn: $allowPvP)
                            .cursorClickable { allowPvP.toggle() }
                        if allowPvP {
                            Toggle("Real PvP damage (off = friendly sparring)", isOn: $pvpDamageReal)
                                .cursorClickable { pvpDamageReal.toggle() }
                            Toggle("Splash damage hits allies (friendly fire)", isOn: $friendlyFire)
                                .cursorClickable { friendlyFire.toggle() }
                        }
                        Toggle("Permadeath — players' ships can be destroyed", isOn: $deathReal)
                            .cursorClickable { deathReal.toggle() }
                    }
                    .tint(amber)

                    field(title: "Options") {
                        Toggle("Allow trading between players", isOn: $allowTrade)
                            .cursorClickable { allowTrade.toggle() }
                    }
                    .tint(amber)

                    if !audiences.isEmpty && audience == .direct {
                        field(title: "Network") {
                            HStack {
                                Text("Port").novaFont(.body).foregroundStyle(.white)
                                Spacer()
                                NovaTextField(placeholder: "53735", text: $portText).frame(width: 110)
                            }
                            HStack {
                                Text("Password").novaFont(.body).foregroundStyle(.white)
                                Spacer()
                                NovaTextField(placeholder: "none", text: $password).frame(width: 180)
                            }
                            NovaMenuPicker(title: "Players", selection: $maxPlayers, options: [2, 3, 4, 6, 8, 12, 16]) { "\($0)" }
                            Toggle("Show on my local network", isOn: $announceOnLAN)
                                .cursorClickable { announceOnLAN.toggle() }
                            Text("UPnP isn't available on Apple devices: forward UDP \(portText.isEmpty ? "53735" : portText) (and \((Int(portText) ?? 53735) + 1) so the server list can ping you) on your router, or use a VPN such as Tailscale. For an always-on server, run the NovaSwift Dedicated Server instead.")
                                .novaFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(amber)
                    }

                    if showsPublicListing || (!audiences.isEmpty && audience == .publicLobby) {
                        field(title: "Visibility") {
                            Toggle("List this lobby publicly", isOn: $listPublicly)
                                .cursorClickable { listPublicly.toggle() }
                            Text(listPublicly
                                 ? "Anyone can see your lobby name and pilot name, and ask to join. You approve every request — nobody gets in without it."
                                 : "Invite-only. Your lobby stays private and you invite friends through Game Center.")
                                .novaFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(amber)
                    }

                    Button {
                        let name = lobbyName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let onHostRequest, !audiences.isEmpty {
                            onHostRequest(HostRequest(audience: audience, name: name, rules: rules,
                                                      port: min(max(Int(portText) ?? CrossPlayProtocol.defaultPort, 1), 65535),
                                                      password: password, maxPlayers: maxPlayers, announceOnLAN: announceOnLAN))
                        } else {
                            onHost(name, rules, showsPublicListing && listPublicly)
                        }
                    } label: {
                        Text("Open Lobby")
                            .novaFont(.button, weight: .medium)
                            .frame(maxWidth: .infinity).padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(amber))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.novaPlain)
                    .padding(.top, 4)

                    CursorButton { dismiss() } label: {
                        Text("Cancel").novaFont(.button).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .cursorScrollable()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Host Lobby")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        // Toolbar items are system chrome the cursor can't press: Ⓑ cancels instead.
        .cursorCancel { dismiss() }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var rules: SessionRules {
        var r: SessionRules = preset == .safe ? .safe : .fullStakes
        r.allowPvP = allowPvP
        r.friendlyFire = friendlyFire
        r.pvpDamageReal = pvpDamageReal
        r.deathReal = deathReal
        r.allowTrade = allowTrade
        return r
    }

    @ViewBuilder
    private func field<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).novaFont(.caption, weight: .bold).foregroundStyle(amber.opacity(0.9))
            content()
        }
    }
}

/// The in-session lobby roster: who's here, host moderation (kick / ban), the
/// active rules, and Leave. Reached from the Multiplayer hub while a session is
/// live. Responsive scrolling list.
struct LobbyRosterView: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    var onClose: () -> Void

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var session: MultiplayerSession { model.session }
    private var myName: String {
        let n = model.pilot.state.pilotName
        return n.isEmpty ? "Captain" : n
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(session.lobbyName.isEmpty ? "Lobby" : session.lobbyName)
                        .novaFont(.heading).foregroundStyle(.white)
                    Text("\(session.players.count) online · \(session.isHost ? "You are host" : "Joined")")
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                if let note = session.hostNotice ?? session.tradeNotice {
                    Label(note, systemImage: "info.circle.fill")
                        .novaFont(.caption).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.2))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Players").novaFont(.button, weight: .medium).foregroundStyle(.white)
                    ForEach(session.players, id: \.playerID) { player in
                        PlayerRosterRow(
                            player: player,
                            isYou: player.playerID == session.localPlayerID,
                            isHost: player.playerID == session.hostPlayerID,
                            canModerate: session.isHost && player.playerID != session.localPlayerID,
                            canTrade: session.canTrade(with: player.playerID),
                            onTrade: {
                                session.inviteTrade(with: player.playerID, myName: myName)
                                onEnterFlight()   // watch the trade window in flight
                            },
                            onKick: { session.kick(player.playerID) },
                            onBan: { session.ban(player.playerID) })
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
                .padding(.horizontal)

                #if canImport(CloudKit) && canImport(GameKit)
                JoinRequestsCard(directory: model.lobbyDirectory)
                #endif

                rulesCard

                VStack(spacing: 10) {
                    Button {
                        onEnterFlight()
                    } label: {
                        Label("Return to Flight", systemImage: "airplane.departure")
                            .novaFont(.button, weight: .medium)
                            .frame(maxWidth: .infinity).padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(amber))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.novaPlain)

                    Button {
                        session.stop()
                        onClose()
                    } label: {
                        Label("Leave Lobby", systemImage: "rectangle.portrait.and.arrow.right")
                            .novaFont(.button, weight: .medium)
                            .frame(maxWidth: .infinity).padding()
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.6)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.novaPlain)

                    CursorButton(action: onClose) {
                        Text("Close").novaFont(.button).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .cursorScrollable()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        // Toolbar items are system chrome the cursor can't press: Ⓑ closes instead.
        .cursorCancel(onClose)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Rules").novaFont(.button, weight: .medium).foregroundStyle(.white)
            HStack(spacing: 8) {
                RulePill(label: session.rules.allowPvP ? "PvP On" : "Co-op (no PvP)",
                         on: session.rules.allowPvP)
                RulePill(label: session.rules.allowTrade ? "Trade On" : "No Trade",
                         on: session.rules.allowTrade)
            }
            if !session.isHost {
                Text("The host controls the rules.").novaFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        .padding(.horizontal)
    }
}

#if canImport(CloudKit) && canImport(GameKit)
/// Knocks from the public lobby list, and the gate itself: nobody advertised-to
/// gets in until the host taps Accept here, which sends the Game Center invite
/// that actually forms the connection. Only ever populated while hosting a lobby
/// the player chose to list publicly.
private struct JoinRequestsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var directory: OnlineLobbyDirectory

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var warn: Color { Color(red: 1, green: 0.6, blue: 0.2) }

    var body: some View {
        if !directory.joinRequests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wants to Join").novaFont(.button, weight: .medium).foregroundStyle(.white)
                ForEach(directory.joinRequests) { request in
                    row(request)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            .padding(.horizontal)
        }
    }

    private func row(_ request: OnlineJoinRequest) -> some View {
        let compatible = request.pluginSignature == model.currentPluginManifest().signature
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle().fill(GalaxyMapView.playerColor(for: request.playerID))
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.playerName).novaFont(.button, weight: .medium).foregroundStyle(.white)
                    if !compatible {
                        Label("Different plug-ins — they'd be dropped on connect",
                              systemImage: "exclamationmark.triangle.fill")
                            .novaFont(.caption).foregroundStyle(warn)
                    }
                }
                Spacer(minLength: 0)
                Button("Decline") { Task { await model.declineJoinRequest(request) } }
                    .novaFont(.caption, weight: .bold)
                    .buttonStyle(.novaPlain).foregroundStyle(.secondary)
                Button {
                    Task { await model.acceptJoinRequest(request) }
                } label: {
                    Text("Accept").novaFont(.caption, weight: .bold)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(amber.opacity(compatible ? 0.3 : 0.15)))
                        .foregroundStyle(compatible ? amber : .secondary)
                }
                .buttonStyle(.novaPlain)
                .disabled(!compatible)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }
}
#endif

private struct RulePill: View {
    let label: String, on: Bool
    var body: some View {
        Text(label).novaFont(.caption, weight: .bold)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill((on ? Color.green : Color.gray).opacity(0.22)))
            .foregroundStyle(on ? .green : .gray)
    }
}

private struct PlayerRosterRow: View {
    let player: PlayerPresence
    let isYou: Bool
    let isHost: Bool
    let canModerate: Bool
    let canTrade: Bool
    var onTrade: () -> Void
    var onKick: () -> Void
    var onBan: () -> Void

    private var color: Color { GalaxyMapView.playerColor(for: player.playerID) }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(player.name.isEmpty ? "Captain" : player.name)
                        .novaFont(.button, weight: .medium).foregroundStyle(.white)
                    if isYou { tag("You", .cyan) }
                    if isHost { tag("Host", Color(red: 1, green: 0.7, blue: 0.28)) }
                }
                Text("System \(player.currentSystemID)").novaFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canTrade {
                Button(action: onTrade) {
                    Label("Trade", systemImage: "arrow.left.arrow.right")
                        .labelStyle(.iconOnly).font(.title3)
                        .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.28))
                }
                .buttonStyle(.novaPlain)
            }
            if canModerate {
                // Two plain buttons, not a `Menu`: the cursor can't open a popup.
                CursorButton(action: onKick) {
                    Image(systemName: "boot").font(.title3).foregroundStyle(.red.opacity(0.85))
                }
                .accessibilityLabel("Kick")
                CursorButton(action: onBan) {
                    Image(systemName: "nosign").font(.title3).foregroundStyle(.red.opacity(0.85))
                }
                .accessibilityLabel("Ban")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    private func tag(_ text: String, _ c: Color) -> some View {
        Text(text).novaFont(.caption, weight: .bold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.25))).foregroundStyle(c)
    }
}
