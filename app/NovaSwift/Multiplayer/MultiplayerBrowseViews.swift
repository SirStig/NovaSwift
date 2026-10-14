import SwiftUI
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftENet
#if canImport(GameKit)
import GameKit
#endif

// The Multiplayer hub's Browse and Host sections, Quick Connect, and the plug-in dialog. Same information
// architecture as the Godot hub (one combined list with source tags, filter chips, Quick Connect in the header,
// Host as its own section) with Game Center and CloudKit lobbies mixed in.

private let hubAmber = Color(red: 1.0, green: 0.7, blue: 0.28)
private let hubWarn = Color(red: 1.0, green: 0.6, blue: 0.2)

// MARK: - Game Center flow (matchmaker sheet state)

#if canImport(GameKit)
/// Holds the Game Center matchmaker sheet state shared by Browse (Quick Match) and Host (invite friends / public lobby).
@MainActor
final class GameCenterFlow: ObservableObject {
    @Published var showMatchmaker = false
    @Published var role: OnlineRole = .autoMatch
}
#endif

// MARK: - Browse

struct MultiplayerBrowseView: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    var onQuickConnect: () -> Void
    #if canImport(GameKit)
    @ObservedObject var gcFlow: GameCenterFlow
    #endif

    @State private var filter = BrowseFilter()
    @State private var passwordTarget: BrowseEntry?
    @State private var passwordText = ""
    @State private var passwordShown = false

    private var crossPlay: CrossPlayModel { model.crossPlay }

    var body: some View {
        VStack(spacing: 12) {
            NovaTextField(placeholder: "Search servers", text: $filter.search)
                .padding(.horizontal)
            chips
            if let notice = crossPlay.notice {
                banner(notice) { crossPlay.notice = nil }
            }
            #if canImport(CloudKit) && canImport(GameKit)
            OnlineRequestBanner(directory: model.lobbyDirectory)
            #endif
            if let busy = crossPlay.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small).tint(hubAmber); Text(busy).novaFont(.caption).foregroundStyle(.secondary) }
            }
            if let c = model.session.connectingTo {
                HStack(spacing: 8) { ProgressView().controlSize(.small).tint(hubAmber); Text("Connecting to \(c)…").novaFont(.caption).foregroundStyle(.secondary) }
            }
            list
        }
        .onAppear {
            crossPlay.start()
            model.session.startBrowsingLocalLobbies()
            #if canImport(CloudKit) && canImport(GameKit)
            if model.gameCenter.isAuthenticated { model.lobbyDirectory.startBrowsing() }
            #endif
            Task {
                await model.warmPluginManifest()
                crossPlay.localRequirements = model.currentPluginRequirements()
            }
        }
        .onDisappear {
            crossPlay.stop()
            model.session.stopBrowsingLocalLobbies()
            #if canImport(CloudKit) && canImport(GameKit)
            model.lobbyDirectory.stopBrowsing()
            #endif
        }
        .novaAlert("Password", isPresented: $passwordShown,
                   message: "\(passwordTarget?.name ?? "This server") needs a password.", text: $passwordText,
                   buttons: [.cancel("Cancel"), NovaAlertButton(title: "Join") {
                       if let e = passwordTarget { join(e, password: passwordText) }
                   }])
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", on: filter.source == nil) { filter.source = nil }
                ForEach([BrowseEntry.Source.saved, .nearby, .publicServer, .gameCenter]) { s in
                    chip(s.rawValue, icon: s.icon, on: filter.source == s) { filter.source = filter.source == s ? nil : s }
                }
                chip("Compatible", on: filter.compatibleOnly) { filter.compatibleOnly.toggle() }
                chip("Has players", on: filter.hasPlayers) { filter.hasPlayers.toggle() }
                chip("No password", on: filter.noPassword) { filter.noPassword.toggle() }
                if !crossPlay.availableRegions.isEmpty {
                    ForEach(crossPlay.availableRegions, id: \.self) { r in
                        chip(ServerDirectory.regionTitle(r), on: filter.region == r) { filter.region = filter.region == r ? nil : r }
                    }
                }
            }
            .padding(.horizontal)
        }
        .cursorScrollable()
    }

    private func chip(_ title: String, icon: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        CursorButton(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(title).novaFont(.caption, weight: .semibold)
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? hubAmber : Color(white: 0.14)))
        }
    }

    private func banner(_ text: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(hubWarn)
            Text(text).novaFont(.caption).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CursorButton(action: dismiss) { Image(systemName: "xmark").foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hubWarn.opacity(0.15)))
        .padding(.horizontal)
    }

    // MARK: List

    private var onlineLobbies: [OnlineLobbyInfo] {
        #if canImport(CloudKit) && canImport(GameKit)
        let mine = model.currentPluginManifest().signature
        return model.lobbyDirectory.lobbies.map {
            OnlineLobbyInfo(id: $0.hostPlayerID, name: $0.name, hostName: $0.hostName, players: $0.playerCount,
                            maxPlayers: $0.maxPlayers, allowPvP: $0.allowPvP,
                            compatible: !$0.isFull && ($0.pluginSignature.isEmpty || $0.pluginSignature == mine))
        }
        #else
        return []
        #endif
    }

    private var gameCenterAvailable: Bool {
        #if canImport(GameKit)
        return model.gameCenter.isAuthenticated
        #else
        return false
        #endif
    }

    private var entries: [BrowseEntry] {
        filter.apply(crossPlay.entries(multipeer: model.session.localLobbies, onlineLobbies: onlineLobbies,
                                       gameCenterAvailable: gameCenterAvailable,
                                       localPluginSignature: model.session.localPluginSignature))
    }

    @ViewBuilder private var list: some View {
        let rows = entries
        ScrollView {
            LazyVStack(spacing: 8) {
                if rows.isEmpty {
                    empty
                } else {
                    ForEach(rows) { e in
                        BrowseRowView(entry: e, local: crossPlay.localRequirements,
                                      saved: e.address.map { crossPlay.isSaved($0) } ?? false,
                                      onJoin: { join(e, password: nil) },
                                      onToggleSave: { toggleSave(e) })
                    }
                }
                footer
            }
            .padding(.horizontal)
        }
        .cursorScrollable()
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "network").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(filterActive ? "No servers match these filters." : "No servers found yet.")
                .novaFont(.button, weight: .medium).foregroundStyle(.white)
            Text(crossPlay.probing ? "Checking the public list…" : "Connect to a friend's address, host your own game, or wait for games on your network to appear.")
                .novaFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            CursorButton(action: onQuickConnect) {
                Text("Quick Connect").novaFont(.button, weight: .medium).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(hubAmber))
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var filterActive: Bool { filter != BrowseFilter() }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 4) {
            switch crossPlay.directoryStatus {
            case .offline(let m), .failed(let m): Text(m).novaFont(.caption).foregroundStyle(hubWarn)
            case .loading: Text("Updating the public server list…").novaFont(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if !crossPlay.lanError.isEmpty {
                Text(crossPlay.lanError).novaFont(.caption).foregroundStyle(.secondary)
            }
            CursorButton { crossPlay.refreshDirectory(force: true) } label: {
                Text("Refresh").novaFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func toggleSave(_ e: BrowseEntry) {
        guard let a = e.address else { return }
        if crossPlay.isSaved(a) { crossPlay.removeSaved(host: a.host, port: a.port) }
        else { crossPlay.save(SavedServer(name: e.name, host: a.host, port: a.port)) }
    }

    private func join(_ e: BrowseEntry, password: String?) {
        switch e.kind {
        case .enet(let row):
            if row.encrypted { crossPlay.notice = AppModel.encryptedNotice; return }
            let saved = crossPlay.savedServers.first { $0.id == row.id }
            let pw = password ?? saved?.password ?? ""
            if row.passwordProtected, pw.isEmpty {
                passwordTarget = e; passwordText = ""; passwordShown = true
                return
            }
            var save: SavedServer?
            if let saved, saved.password != pw, !pw.isEmpty { save = SavedServer(name: saved.name, host: saved.host, port: saved.port, password: pw) }
            model.connectToServer(PendingENetJoin(address: row.address, name: e.name, password: pw, save: save), row: row)
        case .multipeer(let lobby):
            let compatible = lobby.pluginSignature.isEmpty || lobby.pluginSignature == model.session.localPluginSignature
            model.session.joinLocalLobby(lobby, displayName: model.multiplayerDisplayName,
                                         systemID: model.pilot.state.currentSystem, shipTypeID: model.pilot.state.shipType)
            if compatible { model.session.stopBrowsingLocalLobbies(); onEnterFlight() }
        case .onlineLobby(let hostID):
            #if canImport(CloudKit) && canImport(GameKit)
            if let lobby = model.lobbyDirectory.lobbies.first(where: { $0.hostPlayerID == hostID }) {
                Task {
                    await model.lobbyDirectory.requestJoin(
                        lobby: lobby, playerID: GKLocalPlayer.local.gamePlayerID,
                        playerName: model.multiplayerDisplayName,
                        pluginSignature: model.currentPluginManifest().signature)
                }
                crossPlay.notice = "Asked to join \(lobby.name). The host approves requests; the invite opens by itself."
            }
            #endif
        case .gameCenterQuickMatch:
            #if canImport(GameKit)
            model.onlineHostConfig = nil
            model.gameCenter.lastError = nil
            gcFlow.role = .autoMatch
            gcFlow.showMatchmaker = true
            #endif
        }
    }
}

// MARK: - One row

struct BrowseRowView: View {
    let entry: BrowseEntry
    let local: PluginRequirements
    let saved: Bool
    var onJoin: () -> Void
    var onToggleSave: () -> Void

    private var color: Color { GalaxyMapView.playerColor(for: entry.id) }
    private var encrypted: Bool { if case .enet(let r) = entry.kind { return r.encrypted } else { return false } }
    private var checking: Bool { if case .enet(let r) = entry.kind { return r.state == .checking } else { return false } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(entry.online ? color : Color.gray).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).novaFont(.button, weight: .medium).foregroundStyle(.white).lineLimit(1)
                    if entry.locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                tags
                if !entry.detail.isEmpty {
                    Text(entry.detail).novaFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                status
                requirementsLine
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                joinPill
                if entry.address != nil {
                    CursorButton(action: onToggleSave) {
                        Image(systemName: saved ? "star.fill" : "star").font(.system(size: 14))
                            .foregroundStyle(saved ? hubAmber : Color.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
        .opacity(entry.online || checking ? 1 : 0.55)
    }

    private var tags: some View {
        HStack(spacing: 4) {
            ForEach(entry.sources) { s in tag(s.rawValue, icon: s.icon, color: hubAmber) }
            if encrypted { tag("Encrypted", icon: "lock.shield.fill", color: hubWarn) }
            else if entry.differentVersion { tag("Different version", icon: "info.circle", color: .secondary) }
            if case .enet(let r) = entry.kind, !r.protocolOK { tag("Update needed", icon: "exclamationmark.triangle.fill", color: hubWarn) }
            if case .enet(let r) = entry.kind, r.dedicated { tag("Dedicated", icon: "server.rack", color: .secondary) }
        }
    }

    private func tag(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).novaFont(.caption, size: 10)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder private var status: some View {
        if checking {
            Text("Checking…").novaFont(.caption).foregroundStyle(.secondary)
        } else if !entry.online {
            Text("Offline").novaFont(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                if entry.players > 0 || entry.maxPlayers > 0 {
                    Label(entry.maxPlayers > 0 ? "\(entry.players)/\(entry.maxPlayers)" : "\(entry.players)", systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon).novaFont(.caption, weight: .medium).foregroundStyle(color)
                }
                if entry.pingMilliseconds >= 0 {
                    Text("\(entry.pingMilliseconds) ms").novaFont(.caption).foregroundStyle(pingColor)
                }
                if !entry.rules.isEmpty { Text(entry.rules.capitalized).novaFont(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var pingColor: Color { entry.pingMilliseconds < 80 ? .green : (entry.pingMilliseconds < 160 ? hubAmber : hubWarn) }

    /// "Requires: A ✓  B ✗" against the local install; the server's total conversion first.
    @ViewBuilder private var requirementsLine: some View {
        if let req = entry.requirements, !req.isEmpty {
            let compat = PluginCompatibility.evaluate(local: local, server: req)
            let marks = Dictionary(PluginCompatibility.checklist(local: local, server: req).map { ($0.requirement.id, $0.ok) }, uniquingKeysWith: { a, _ in a })
            VStack(alignment: .leading, spacing: 2) {
                if let tc = req.totalConversion {
                    (Text("Total conversion: \(tc) ") + Text(local.totalConversion == tc ? "✓" : "✗")
                        .foregroundColor(local.totalConversion == tc ? .green : hubWarn))
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
                if !req.plugins.isEmpty {
                    req.plugins.reduce(Text("Requires: ")) { acc, p in
                        let ok = marks[p.id] ?? false
                        return acc + Text((p.name.isEmpty ? p.id : p.name) + (ok ? " ✓  " : " ✗  ")).foregroundColor(ok ? .green : hubWarn)
                    }
                    .novaFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if !compat.extra.isEmpty {
                    Text("You'd switch off: " + compat.extra.map { $0.name.isEmpty ? $0.id : $0.name }.joined(separator: ", "))
                        .novaFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else if case .enet(let r) = entry.kind, r.state == .online, r.requirements == nil, !r.pluginSignature.isEmpty {
            let same = PluginCompatibility.signatureHint(local: local, serverSignature: r.pluginSignature)
            if same == false { Text("Plug-ins differ from yours").novaFont(.caption).foregroundStyle(hubWarn) }
        }
    }

    private var joinPill: some View {
        let ok = entry.compatible && !encrypted
        let full = entry.maxPlayers > 0 && entry.players >= entry.maxPlayers && entry.online
        // An offline row stays joinable: the status port (game port + 1) is often not forwarded while the game port is.
        let enabled = (entry.online || checking || entry.address != nil) && !encrypted && !full
        let tint: Color = ok ? color : hubWarn
        return CursorButton(action: onJoin) {
            Text(full ? "Full" : (encrypted ? "Encrypted" : (!entry.online && !checking ? "Try" : (ok ? "Join" : "Details"))))
                .novaFont(.caption, weight: .bold)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(tint.opacity(0.25)))
                .foregroundStyle(tint)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - Quick Connect

struct QuickConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onConnect: () -> Void

    @State private var address = ""
    @State private var password = ""
    @State private var save = false
    @State private var saveName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Join a game by address. Friends on Linux, Windows or Steam Deck, and dedicated servers, work too.")
                        .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    labeled("Address") {
                        NovaTextField(placeholder: "host or host:port", text: $address)
                    }
                    labeled("Password (if any)") {
                        NovaTextField(placeholder: "optional", text: $password)
                    }
                    Toggle("Save this server", isOn: $save).cursorClickable { save.toggle() }.tint(hubAmber)
                        .novaFont(.body).foregroundStyle(.white)
                    if save {
                        labeled("Name") { NovaTextField(placeholder: "e.g. Friday night", text: $saveName) }
                    }
                    if let error { Text(error).novaFont(.caption).foregroundStyle(hubWarn) }
                    CursorButton(action: connect) {
                        Text("Connect").novaFont(.button, weight: .medium).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(hubAmber))
                    }
                    let recent = model.crossPlay.recent
                    if !recent.isEmpty {
                        Text("RECENT").novaFont(.caption, weight: .bold).foregroundStyle(hubAmber.opacity(0.9))
                        ForEach(recent, id: \.self) { a in
                            CursorButton { address = a.formatted } label: {
                                HStack { Image(systemName: "clock.arrow.circlepath"); Text(a.formatted).novaFont(.body); Spacer() }
                                    .foregroundStyle(.white).padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                            }
                        }
                    }
                    CursorButton { dismiss() } label: {
                        Text("Cancel").novaFont(.button).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .cursorScrollable()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Quick Connect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .cursorCancel { dismiss() }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).novaFont(.caption, weight: .bold).foregroundStyle(hubAmber.opacity(0.9))
            content()
        }
    }

    private func connect() {
        switch CrossPlayAddress.parse(address) {
        case .failure(let e): error = e.errorDescription
        case .success(let a):
            error = nil
            let name = saveName.trimmingCharacters(in: .whitespaces)
            let saved = save ? SavedServer(name: name.isEmpty ? a.formatted : name, host: a.host, port: a.port, password: password) : nil
            dismiss()
            onConnect()
            model.connectToServer(PendingENetJoin(address: a, name: name.isEmpty ? a.formatted : name, password: password, save: saved))
        }
    }
}

// MARK: - Host

struct MultiplayerHostView: View {
    @EnvironmentObject private var model: AppModel
    var onEnterFlight: () -> Void
    #if canImport(GameKit)
    @ObservedObject var gcFlow: GameCenterFlow
    #endif
    @State private var showSetup = false
    @State private var error: String?

    private var audiences: [HostAudience] {
        var a: [HostAudience] = []
        #if canImport(GameKit)
        if model.gameCenter.isAuthenticated { a += [.friends, .publicLobby] }
        #endif
        #if canImport(MultipeerConnectivity)
        a.append(.nearby)
        #endif
        a.append(.direct)
        return a
    }

    var body: some View {
        VStack(spacing: 14) {
            Button { showSetup = true } label: {
                HubActionLabel(icon: "plus.circle.fill", title: "Host a Game",
                               subtitle: "Choose who can join, set the stakes and open the lobby")
            }
            .buttonStyle(.novaPlain)
            if let error {
                Text(error).novaFont(.caption).foregroundStyle(hubWarn).padding(.horizontal)
            }
            #if canImport(GameKit)
            if !model.gameCenter.isAuthenticated {
                Text("Sign in to Game Center (system Settings) to host for friends or list a public online lobby.")
                    .novaFont(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let e = model.gameCenter.lastError {
                Text(e).novaFont(.caption).foregroundStyle(hubWarn).padding(.horizontal)
            }
            #endif
            VStack(alignment: .leading, spacing: 6) {
                Text("Always-on server").novaFont(.button, weight: .medium).foregroundStyle(.white)
                Text("For a game that's up around the clock, run the standalone NovaSwift Dedicated Server on a Linux box, a Raspberry Pi or a VPS. Players on every platform join it by address, and it can be listed in the Public tab.")
                    .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                Link("How to host a public server",
                     destination: URL(string: "https://github.com/SirStig/NovaSwift/blob/main/docs/MULTIPLAYER.md#host-a-public-server-in-5-minutes")!)
                    .novaFont(.caption, weight: .semibold).tint(hubAmber)
                #endif
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            .padding(.horizontal)
        }
        .sheet(isPresented: $showSetup) {
            HostSetupView(onHost: { _, _, _ in }, audiences: audiences, onHostRequest: { req in
                showSetup = false
                host(req)
            })
            .cursorHost()
        }
    }

    private func host(_ req: HostRequest) {
        error = nil
        switch req.audience {
        case .direct:
            do {
                try model.hostENetGame(name: req.name, rules: req.rules, port: req.port, password: req.password,
                                       maxPlayers: req.maxPlayers, announceOnLAN: req.announceOnLAN)
                onEnterFlight()
            } catch ENetHostTransport.HostError.cannotBind(let p) {
                error = "Couldn't open UDP \(p). Another game or server may already be using it - pick a different port."
            } catch {
                self.error = "Couldn't start hosting: \(error.localizedDescription)"
            }
        case .nearby:
            var rules = req.rules
            rules.gameSpeedMultiplier = model.settings.gameSpeed.multiplier
            model.session.hostLocalLobby(lobbyName: req.name, displayName: model.multiplayerDisplayName,
                                         systemID: model.pilot.state.currentSystem,
                                         shipTypeID: model.pilot.state.shipType, rules: rules)
            onEnterFlight()
        case .friends, .publicLobby:
            #if canImport(GameKit)
            var rules = req.rules
            rules.gameSpeedMultiplier = model.settings.gameSpeed.multiplier
            let config = AppModel.OnlineHostConfig(lobbyName: req.name, rules: rules, listPublicly: req.audience == .publicLobby)
            model.onlineHostConfig = config
            model.gameCenter.lastError = nil
            gcFlow.role = .hosting
            #if canImport(CloudKit)
            if config.listPublicly { Task { await model.publishOnlineLobby(config) } }
            #endif
            gcFlow.showMatchmaker = true
            #endif
        }
    }
}

// MARK: - Plug-in dialog

/// "This server uses these plug-ins ... Install and enable them for this session?" - one click when everything is
/// in the catalog; otherwise the full missing / extra / other-version / total-conversion list with the steps
/// that can still be done automatically.
struct PluginPlanOverlay: View {
    @EnvironmentObject private var model: AppModel
    let plan: PluginJoinPlan

    private func names(_ list: [PluginRequirement]) -> String {
        list.map { $0.name.isEmpty ? $0.id : $0.name }.joined(separator: ", ")
    }

    private func close() { model.crossPlay.pluginPlan = nil }

    var body: some View {
        Group {
            if plan.working != nil || plan.isSimple {
                simple
            } else {
                detailed
            }
        }
        .cursorModal()
    }

    private var requiredList: [PluginRequirement] {
        var list = plan.requirements.plugins
        if let tc = plan.requirements.totalConversion, !list.contains(where: { $0.id == tc }) {
            list.insert(PluginRequirement(id: tc, name: tc, contentHash: ""), at: 0)
        }
        return list
    }

    private var simple: some View {
        NovaDialog(title: "Plug-ins", width: 440, buttons: plan.working != nil ? [] : [
            NovaDialogButton(title: "Cancel", action: close),
            NovaDialogButton(title: "Install & Join", isDefault: true) {
                model.runPluginPlan([.install, .disableExtras, .switchTotalConversion])
            },
        ]) {
            VStack(alignment: .leading, spacing: 10) {
                if let working = plan.working {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working).novaFont(.body).foregroundStyle(.white) }
                } else {
                    Text("This server uses these plug-ins: \(names(requiredList)). Install and enable them for this session?")
                        .novaFont(.body).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    if !plan.compatibility.extra.isEmpty {
                        Text("Your own \(names(plan.compatibility.extra)) will be switched off until you leave.")
                            .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Your pilot is saved first, and your own plug-ins come back when the session ends.")
                        .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let e = plan.error { Text(e).novaFont(.caption).foregroundStyle(hubWarn) }
            }
        }
    }

    private var detailed: some View {
        var buttons: [NovaDialogButton] = [NovaDialogButton(title: "Cancel", action: close)]
        let canInstall = !plan.installable.isEmpty
        let hasExtras = !plan.compatibility.extra.isEmpty
        let tcSwitch = plan.compatibility.wrongTotalConversion != nil && plan.tcInstalledLocally
        if hasExtras {
            buttons.append(NovaDialogButton(title: "Disable my extras") { model.runPluginPlan([.disableExtras]) })
        }
        if tcSwitch {
            buttons.append(NovaDialogButton(title: "Switch to its total conversion") { model.runPluginPlan([.switchTotalConversion]) })
        }
        if canInstall || !plan.installedDisabled.isEmpty {
            buttons.append(NovaDialogButton(title: canInstall ? "Install from catalog & enable" : "Enable & Join", isDefault: true) {
                model.runPluginPlan([.install, .disableExtras, .switchTotalConversion])
            })
        }
        return NovaDialog(title: "Can't Join Yet", width: 480, buttons: buttons) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your gameplay plug-ins differ from \(plan.serverName). Art and sound plug-ins never matter.")
                    .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                section("Missing - in the catalog", plan.installable, .green)
                section("Missing - not in the catalog", plan.unavailable, hubWarn)
                section("Installed but switched off", plan.installedDisabled, hubAmber)
                section("Other version", plan.compatibility.wrongVersion.filter { w in !plan.installable.contains { $0.id == w.id } && !plan.unavailable.contains { $0.id == w.id } }, hubWarn)
                section("You have, the server doesn't", plan.compatibility.extra, hubWarn)
                if let tc = plan.compatibility.wrongTotalConversion {
                    Text("Total conversion: the server runs \(tc)" + (plan.tcInstalledLocally ? " (installed here)." : "."))
                        .novaFont(.caption).foregroundStyle(hubAmber)
                }
                if !plan.unavailable.isEmpty {
                    Text("Ask the server's owner where to get the plug-ins marked “not in the catalog”.")
                        .novaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let e = plan.error { Text(e).novaFont(.caption).foregroundStyle(hubWarn) }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [PluginRequirement], _ color: Color) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).novaFont(.caption, weight: .bold).foregroundStyle(color)
                Text(names(list)).novaFont(.body).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if canImport(CloudKit) && canImport(GameKit)
/// The state of our own "ask to join" knock on a public online lobby (the host approves it with a Game Center invite).
private struct OnlineRequestBanner: View {
    @ObservedObject var directory: OnlineLobbyDirectory

    var body: some View {
        switch directory.outgoingRequest {
        case .waiting(let lobbyID):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(hubAmber)
                Text("Waiting for the host to let you in. The invite opens by itself.")
                    .novaFont(.caption).foregroundStyle(hubAmber).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                CursorButton {
                    Task { await directory.cancelJoinRequest(lobbyID: lobbyID, playerID: GKLocalPlayer.local.gamePlayerID) }
                } label: { Text("Cancel").novaFont(.caption, weight: .bold).foregroundStyle(.secondary) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            .padding(.horizontal)
        case .failed(let why):
            Text(why).novaFont(.caption).foregroundStyle(hubWarn).padding(.horizontal)
        default:
            EmptyView()
        }
    }
}
#endif
