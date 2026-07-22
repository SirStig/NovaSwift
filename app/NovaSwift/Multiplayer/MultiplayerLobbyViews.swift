import SwiftUI
import NovaSwiftKit
import NovaSwiftNet

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
                        #endif
                    }

                    field(title: "Stakes") {
                        Picker("Stakes", selection: $preset) {
                            ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
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
                        if allowPvP {
                            Toggle("Real PvP damage (off = friendly sparring)", isOn: $pvpDamageReal)
                            Toggle("Splash damage hits allies (friendly fire)", isOn: $friendlyFire)
                        }
                        Toggle("Permadeath — players' ships can be destroyed", isOn: $deathReal)
                    }
                    .tint(amber)

                    field(title: "Options") {
                        Toggle("Allow trading between players", isOn: $allowTrade)
                    }
                    .tint(amber)

                    if showsPublicListing {
                        field(title: "Visibility") {
                            Toggle("List this lobby publicly", isOn: $listPublicly)
                            Text(listPublicly
                                 ? "Anyone can see your lobby name and pilot name, and ask to join. You approve every request — nobody gets in without it."
                                 : "Invite-only. Your lobby stays private and you invite friends through Game Center.")
                                .novaFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(amber)
                    }

                    Button {
                        onHost(lobbyName.trimmingCharacters(in: .whitespacesAndNewlines), rules,
                               showsPublicListing && listPublicly)
                    } label: {
                        Text("Open Lobby")
                            .novaFont(.button, weight: .medium)
                            .frame(maxWidth: .infinity).padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(amber))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.novaPlain)
                    .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Host Lobby")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
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
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
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
                Menu {
                    Button(role: .destructive, action: onKick) { Label("Kick", systemImage: "boot") }
                    Button(role: .destructive, action: onBan) { Label("Ban", systemImage: "nosign") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
