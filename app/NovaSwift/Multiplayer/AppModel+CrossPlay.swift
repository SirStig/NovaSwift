import Foundation
import Combine
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftENet
import NovaSwiftPluginStore

/// Cross-play orchestration on `AppModel`: joining / hosting ENet games, and borrowing a server's plug-in set for
/// the length of a session ("Install & Join"), then putting the player's own set back.
///
/// The borrow is a session-only override on `GameDataController` (`setSessionPluginOverride`): nothing the
/// player chose is rewritten on disk, so even a crash mid-session leaves their own plug-ins selected next launch.
/// Installing from the catalog does keep the downloaded files (they're just switched off again afterwards).
extension AppModel {

    enum PluginPlanStep: Hashable { case install, disableExtras, switchTotalConversion }

    func wireCrossPlay() {
        session.onSessionEnded = { [weak self] in self?.crossPlaySessionEnded() }
        // A refused / dropped ENet join: plug-ins -> the plan dialog; anything else -> a banner. Either way the
        // joiner is no longer waiting, and a borrowed plug-in set goes back.
        session.$enetFailure
            .compactMap { $0 }
            .sink { [weak self] failure in self?.enetJoinFailed(failure) }
            .store(in: &crossPlay.cancellables)
        session.$isActive
            .removeDuplicates()
            .sink { [weak self] active in if active { self?.crossPlay.joinInFlight = false } }
            .store(in: &crossPlay.cancellables)
    }

    // MARK: Joining

    static let encryptedNotice = "Encrypted server - not supported on this device yet. Ask the host to turn encryption off, or join from the desktop app."

    /// Join `join.address`. If the browser already has a live answer for it (`row`), that is used; otherwise the
    /// server's status port is asked first (like the Godot client), which also tells an encrypted (DTLS) server -
    /// which this client can't speak - from one that is merely unreachable. A different gameplay plug-in set
    /// opens the plug-in dialog instead of connecting.
    func connectToServer(_ join: PendingENetJoin, row: ServerRow? = nil) {
        guard data.hasBaseData else {
            crossPlay.notice = "Add your EV Nova data files before playing online."
            return
        }
        crossPlay.notice = nil
        crossPlay.lastJoin = join
        if let row, row.state == .online {
            proceedToJoin(join, beacon: nil, row: row)
            return
        }
        crossPlay.busy = "Contacting \(join.address.formatted)…"
        let host = join.address.host, port = join.address.port
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = ServerStatusQuery.query(host: host, gamePort: port, timeout: 1.5)
            await MainActor.run { self?.proceedToJoin(join, beacon: r?.beacon, row: nil) }
        }
    }

    private func proceedToJoin(_ join: PendingENetJoin, beacon: ServerBeacon?, row: ServerRow?) {
        crossPlay.busy = nil
        let encrypted = row?.encrypted ?? beacon?.encrypted ?? false
        if encrypted {
            crossPlay.notice = Self.encryptedNotice
            return
        }
        let protocolOK = row?.protocolOK ?? beacon?.isCompatible ?? true
        if !protocolOK {
            crossPlay.notice = "That server runs a different multiplayer protocol. One of you needs to update NovaSwift."
            return
        }
        // nil = the server didn't say (older build, status port closed): the handshake will tell.
        if let requirements = row?.requirements ?? beacon?.requirements {
            let compat = PluginCompatibility.evaluate(local: currentPluginRequirements(), server: requirements)
            if !compat.isCompatible {
                presentPluginPlan(join, requirements: requirements, compat: compat)
                return
            }
        }
        startENetJoin(join)
    }

    /// Connect now (plug-ins already match, or we don't know yet).
    func startENetJoin(_ join: PendingENetJoin) {
        if screen != .game { finishLoadingIntoGame() }
        if let s = join.save { crossPlay.save(s) }
        crossPlay.noteRecent(join.address)
        crossPlay.lastJoin = join
        crossPlay.joinInFlight = true
        crossPlay.busy = nil
        session.joinENet(address: join.address, password: join.password, displayName: multiplayerDisplayName,
                         systemID: pilot.state.currentSystem, shipTypeID: pilot.state.shipType, label: join.name)
    }

    private func enetJoinFailed(_ failure: MultiplayerSession.ENetFailure) {
        crossPlay.joinInFlight = false
        crossPlay.busy = nil
        if failure.code == "plugins", let join = crossPlay.lastJoin,
           let json = failure.serverManifestJSON, let manifest = ENetTransport.parseManifest(json) {
            let req = PluginRequirements(plugins: manifest.plugins)
            let compat = PluginCompatibility.evaluate(local: currentPluginRequirements(), server: req)
            if !compat.isCompatible {
                presentPluginPlan(join, requirements: req, compat: compat)
                return
            }
        }
        crossPlay.notice = Self.friendlyJoinMessage(failure)
        if crossPlay.borrowedFrom != nil, !session.isActive { Task { await restorePlugins() } }
    }

    static func friendlyJoinMessage(_ f: MultiplayerSession.ENetFailure) -> String {
        switch f.code {
        case "proto": return "That server runs a different multiplayer protocol. One of you needs to update NovaSwift."
        case "password": return f.message.contains("needs") ? "That server needs a password." : "Wrong password."
        case "full": return "That server is full."
        case "banned": return "You are banned from that server."
        case "plugins": return "Your gameplay plug-ins don't match that server's."
        default: return f.message
        }
    }

    // MARK: Hosting

    /// Open this game to ENet joiners. Throws `ENetHostTransport.HostError.cannotBind` when the port is taken.
    func hostENetGame(name: String, rules: SessionRules, port: Int, password: String, maxPlayers: Int,
                      announceOnLAN: Bool) throws {
        guard data.hasBaseData else {
            crossPlay.notice = "Add your EV Nova data files before hosting."
            return
        }
        if screen != .game { finishLoadingIntoGame() }
        crossPlay.stop()        // the browser's beacon socket must not shadow the host's status responder
        var rules = rules
        rules.gameSpeedMultiplier = settings.gameSpeed.multiplier
        try session.hostENet(lobbyName: name, displayName: multiplayerDisplayName, systemID: pilot.state.currentSystem,
                             shipTypeID: pilot.state.shipType, rules: rules, port: port, password: password,
                             maxPlayers: maxPlayers, announcer: announceOnLAN ? crossPlay.announcer : nil,
                             requirements: currentPluginRequirements())
    }

    // MARK: Plug-in plan

    func presentPluginPlan(_ join: PendingENetJoin, requirements: PluginRequirements, compat: PluginCompatibility) {
        let installed = Dictionary(data.plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var installedDisabled: [PluginRequirement] = [], installable: [PluginRequirement] = [], unavailable: [PluginRequirement] = []
        for r in compat.missing {
            if installed[r.id] != nil { installedDisabled.append(r) }
            else if store.entry(id: r.id) != nil { installable.append(r) }
            else { unavailable.append(r) }
        }
        for r in compat.wrongVersion {
            if store.entry(id: r.id) != nil { installable.append(r) } else { unavailable.append(r) }
        }
        var tcInstalled = false
        if let tc = compat.wrongTotalConversion {
            tcInstalled = installed[tc] != nil
            if !tcInstalled, !installable.contains(where: { $0.id == tc }), !unavailable.contains(where: { $0.id == tc }) {
                if store.entry(id: tc) != nil {
                    installable.append(PluginRequirement(id: tc, name: store.entry(id: tc)?.name ?? tc, contentHash: ""))
                } else {
                    unavailable.append(PluginRequirement(id: tc, name: tc, contentHash: ""))
                }
            }
        }
        crossPlay.busy = nil
        crossPlay.pluginPlan = PluginJoinPlan(serverName: join.name, requirements: requirements, compatibility: compat,
                                              installedDisabled: installedDisabled, installable: installable,
                                              unavailable: unavailable, tcInstalledLocally: tcInstalled, join: join)
    }

    /// Runs the chosen steps, swaps the plug-in set for the session, reloads the data and connects.
    func runPluginPlan(_ steps: Set<PluginPlanStep>) {
        guard var plan = crossPlay.pluginPlan else { return }
        plan.error = nil
        Task { @MainActor in
            do {
                // 1. Download what the catalog has (files stay installed; they are only enabled for the session).
                if steps.contains(.install), !plan.installable.isEmpty {
                    guard !store.isOffline else { throw PlanError.offline }
                    for r in plan.installable {
                        guard let entry = store.entry(id: r.id) else { continue }
                        plan.working = "Installing \(entry.name)…"
                        crossPlay.pluginPlan = plan
                        for dep in store.browser.missingDependencies(of: entry) {
                            if let d = store.entry(id: dep) { _ = try await PluginInstallPipeline.install(d, into: data.importedPluginsDir) }
                        }
                        _ = try await PluginInstallPipeline.install(entry, into: data.importedPluginsDir)
                    }
                    store.refresh(data: data)
                }
                // 2. The set to run: the player's own, minus extras (if asked), plus everything the server needs.
                let compat = plan.compatibility
                let local = data.enabledPluginIDs
                var set = crossPlay.borrowedFrom != nil ? local : local
                if steps.contains(.disableExtras) { set.subtract(compat.extra.map(\.id)) }
                set.formUnion(plan.requirements.plugins.map(\.id))
                if steps.contains(.switchTotalConversion) || steps.contains(.install) {
                    let enabledTCs = data.plugins.filter { $0.isEnabled && $0.isTotalConversion }.map(\.id)
                    if let tc = plan.requirements.totalConversion {
                        set.subtract(enabledTCs.filter { $0 != tc }); set.insert(tc)
                    } else if steps.contains(.disableExtras) {
                        set.subtract(enabledTCs)
                    }
                }
                plan.working = "Switching plug-ins…"
                crossPlay.pluginPlan = plan
                // 3. Swap (tearing the flight scene down first: the loaded game data is replaced).
                if crossPlay.borrowedFrom == nil { crossPlay.borrowedFrom = data.enabledPluginIDs }
                let join = plan.join
                crossPlay.pluginPlan = nil
                crossPlay.busy = "Switching to the server's plug-ins…"
                await swapPlugins(to: set)
                // 4. Verify, then connect.
                let after = PluginCompatibility.evaluate(local: currentPluginRequirements(), server: plan.requirements)
                if after.isCompatible {
                    startENetJoin(join)
                } else {
                    await restorePlugins()
                    var again = plan
                    again.compatibility = after; again.working = nil
                    again.error = "Even with those changes your plug-ins still differ from the server's. Its copy of a plug-in may be newer than the catalog's."
                    crossPlay.pluginPlan = again
                }
            } catch {
                plan.working = nil
                plan.error = (error as? PlanError)?.message ?? error.localizedDescription
                crossPlay.pluginPlan = plan
                crossPlay.busy = nil
            }
        }
    }

    private enum PlanError: Error {
        case offline
        var message: String { "The plug-in catalog is offline, so nothing can be downloaded right now." }
    }

    /// Applies a session plug-in set. Saves the pilot and drops back to the main menu first when flight is running.
    private func swapPlugins(to ids: Set<String>?) async {
        pilot.save()
        let wasInGame = screen == .game
        if wasInGame {
            screen = .mainMenu
            try? await Task.sleep(nanoseconds: 300_000_000)   // let the flight scene tear down
        }
        await data.setSessionPluginOverride(ids)
        if wasInGame, ids != nil { /* startENetJoin re-enters the game */ }
    }

    /// Puts the player's own plug-in set back after a borrowed one, and returns to flight if that's where they were.
    func restorePlugins() async {
        guard crossPlay.borrowedFrom != nil || data.sessionPluginOverride != nil else { return }
        guard !crossPlay.restoringPlugins else { return }
        crossPlay.restoringPlugins = true
        defer { crossPlay.restoringPlugins = false }
        let wasInGame = screen == .game
        await swapPlugins(to: nil)
        crossPlay.borrowedFrom = nil
        crossPlay.notice = "Your own plug-ins are back."
        if wasInGame { finishLoadingIntoGame() }
    }

    /// The "Reconnect" button after auto-reconnect gave up. The session already ended normally (borrowed plug-ins
    /// are being / were restored), so this is just a fresh join from the kept ticket: it re-checks the server's
    /// plug-ins and re-opens the "Install & Join" plan when the set must be borrowed again.
    func reconnectToLostServer() {
        guard let lost = session.lostConnection else { return }
        session.dismissLostConnection()
        let join = PendingENetJoin(address: lost.ticket.address, name: lost.ticket.lobbyName,
                                   password: lost.ticket.password, save: nil)
        Task { @MainActor in
            while crossPlay.restoringPlugins { try? await Task.sleep(nanoseconds: 100_000_000) }
            connectToServer(join)
        }
    }

    private func crossPlaySessionEnded() {
        guard crossPlay.borrowedFrom != nil else { return }
        Task { await restorePlugins() }
    }
}
