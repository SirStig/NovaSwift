#if os(macOS)
import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// MARK: - Test run: story runtime, real landing, comms
//
// The second half of `EditorTestSession`. It mirrors what `GameContainerView` does around the
// flight scene, over the SANDBOX pilot (`PilotStore(editorSandbox:)`, never saved) and the
// editor's own `NovaGame`:
//
//   * landing  → story landing pass (deliveries, cargo, completion texts) → the real
//     `SpaceportView` (trade / outfitter / shipyard / bar / mission BBS) is shown by
//     `EditorTestRunView` against `session.pilot`;
//   * take-off → escort pass + payroll + the spaceport visit's days (crön tick) → launch hook →
//     the player's ship rebuilt from the sandbox pilot (new hull / outfits / cargo / fuel) and
//     the system reloaded in place (`reloadForDeparture`);
//   * jump     → `playerJumped`, travel days (crön tick), payroll, mission flight pass;
//   * mission ships (ShipSyst / AuxShipSyst matching), goal callbacks, mission failure hooks;
//   * hail (ship / stellar) and board (plunder) dialogs.
//
// Not simulated here: the landing-clearance exchange, bribes / paid assistance / tribute in
// the comm windows, capturing from the plunder dialog (use the debug panel's Capture), the
// escort command panels, gates and domination.

extension EditorTestSession {

    // MARK: Wiring

    /// Point the story seam at this session (once, at start).
    func wireStoryServices() {
        let s = missionServices
        s.onLeaveStellar = { [weak self] message in
            guard let self else { return }
            if self.landedSpobID != nil {
                // `Q`: bounced back into space; its text replaces the launch line.
                self.stagedLaunchQuote = message
                Task { @MainActor [weak self] in self?.takeOff() }
            } else if let message, !message.isEmpty {
                self.host?.hud.post(message)
            }
        }
        s.onOverlayMessage = { [weak self] message in self?.host?.hud.post(message) }
        s.onSpawnMissionShips = { [weak self] _, _ in self?.spawnActiveMissionShips() }
        s.onChangePlayerShip = { [weak self] shipID, _ in
            guard let self else { return }
            self.shipID = shipID
            // Docked: take-off rebuilds from the pilot. In flight: rebuild the ship in place.
            if self.landedSpobID == nil { self.touch(); self.scheduleRebuild() }
        }
        s.onMovePlayer = { [weak self] systemID, keepPosition in
            guard let self else { return }
            if self.landedSpobID != nil { self.dockedMove = keepPosition; return }
            _ = self.jump(to: systemID)
        }
        s.onSetStellarDestroyed = { [weak self] spobID, destroyed in
            guard let self else { return }
            if destroyed { self.host?.scene.destroyedStellarIDs.insert(spobID) }
            else { self.host?.scene.destroyedStellarIDs.remove(spobID) }
            let name = self.game?.spob(spobID)?.displayName ?? "A stellar object"
            self.host?.hud.post(destroyed ? "\(name) has been destroyed." : "\(name) has been restored.")
        }
        s.onReleaseMissionShips = { [weak self] missionID in
            guard let self else { return }
            self.host?.scene.releaseMissionShips(missionID: missionID, despawn: self.landedSpobID != nil)
        }
        s.onEscortDeparted = { [weak self] escortID, _ in self?.host?.scene.despawnEscort(recordID: escortID) }
    }

    /// Per-scene callbacks (a host rebuild makes a new scene). Closures hold the session weakly.
    func wireStoryCallbacks(_ host: GameHost) {
        let scene = host.scene
        scene.onMissionShipLost = { [weak self] missionID, goal in self?.missionShipLost(missionID, goal) }
        scene.onMissionAuxShipsArrived = { [weak self] missionID, count in
            guard let self, let m = self.game?.mission(missionID), !m.infiniteAuxShips,
                  let i = self.pilot.state.activeMissions.firstIndex(where: { $0.missionID == missionID }) else { return }
            let left = self.pilot.state.activeMissions[i].auxShipsRemaining ?? m.auxShipCount
            self.pilot.state.activeMissions[i].auxShipsRemaining = max(0, left - count)
        }
        scene.onPlayerDisabled = { [weak self] in
            self?.failActiveMissions(where: { $0.failIfPlayerDisabled }, reason: "Your ship was disabled — mission failed.")
        }
        scene.onPlayerDying = { [weak self] in
            self?.failActiveMissions(where: { $0.failIfPlayerDisabled }, reason: "Your ship was destroyed — mission failed.")
        }
        scene.onPlayerBoarded = { [weak self] in
            self?.failActiveMissions(where: { $0.flags1 & 0x8000 != 0 }, reason: "You were boarded — mission failed.")
        }
        scene.persGrudgeProvider = { [weak self] id in self?.pilot.state.persHoldsGrudge(id) ?? false }
        scene.persMissionAvailableProvider = { [weak self] pers in
            guard let self, let game = self.game else { return true }
            let engine = StoryEngine(game: game, player: self.pilot.state, services: self.missionServices)
            return PersEncounter.offeredMission(pers, player: self.pilot.state, game: game, engine: engine,
                                                boarding: pers.offerMissionOnBoard) != nil
        }
        scene.stellarIFFColorProvider = { [weak self] id in
            guard let self, let game = self.game, let spob = game.spob(id) else { return nil }
            let c = RadarIFF.stellarColor(spob, state: self.pilot.state, game: game, system: self.systemID)
            return Color(red: Double(c.r) / 65535, green: Double(c.g) / 65535, blue: Double(c.b) / 65535)
        }
        scene.onEscortLost = { [weak self] recordID in
            guard let self else { return }
            if let lost = self.pilot.state.removeEscort(id: recordID) { self.host?.hud.post("\(lost.name) was destroyed.") }
        }
        scene.onEscortAbandoned = { [weak self] recordID, destroyed in
            guard let self else { return }
            if let lost = self.pilot.state.removeEscort(id: recordID), destroyed {
                self.host?.hud.post("\(lost.name) was destroyed.")
            }
        }
        // Every status-bar line gets the original's wildcard pass, so quotes never show raw tags.
        if let game {
            host.hud.expandText = { [weak self] text in
                guard let self else { return text }
                return OriginalText(game: game).expandStatusText(text, player: self.pilot.state)
            }
            var patterns: [Int: CGImage] = [:]
            for id in 128..<138 { if let cg = game.pixPatSheet(id)?.makeCGImage() { patterns[id] = cg } }
            host.hud.radarPatterns = patterns
        }
    }

    /// Break the scene → session reference cycles (End Test).
    func unwireStoryCallbacks(_ scene: GameScene?) {
        guard let scene else { return }
        scene.onMissionShipLost = nil; scene.onMissionAuxShipsArrived = nil
        scene.onPlayerDisabled = nil; scene.onPlayerDying = nil; scene.onPlayerBoarded = nil
        scene.persGrudgeProvider = nil; scene.persMissionAvailableProvider = nil
        scene.stellarIFFColorProvider = nil
        scene.onEscortLost = nil; scene.onEscortAbandoned = nil
    }

    // MARK: Entering a system

    /// A system just became current (jump, debug jump, host rebuild): nav visibility, the
    /// active missions' special ships whose `ShipSyst` matches, and the escort wing.
    func systemEntered() {
        refreshNavVisibility()
        spawnActiveMissionShips()
        host?.scene.respawnEscorts(pilot.state.escortWing.map { (recordID: $0.id, shipType: $0.shipType) })
    }

    /// Drop every active mission's special and auxiliary ships into the live world when the
    /// player is in the matching system (`ShipSyst` / `AuxShipSyst`). Deduped by the scene.
    func spawnActiveMissionShips() {
        guard let scene = host?.scene, let game else { return }
        let currentSys = systemID
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        if pilot.state.activeMissions.contains(where: { $0.shipSystemResolved != true }) {
            engine.resolveLegacyMissionShipSystems()
            pilot.state = engine.player
        }
        for am in pilot.state.activeMissions {
            guard let m = game.mission(am.missionID), !scene.hasMissionShips(m.id) else { continue }
            let passiveGoal = m.shipGoal == .escort || m.shipGoal == .observe || m.shipGoal == .none
            let goalEligible = m.shipCount > 0 && m.shipDude >= 128
                && (passiveGoal || am.shipObjectivesRemaining > 0)
            let shipName = engine.missionShipName(am, m)
            let shipSubtitle = engine.missionShipSubtitle(am, m)
            if goalEligible, engine.shipSystemMatches(am, currentSystem: currentSys) {
                if m.shipStart == 1 {
                    // A ShipStart-1 batch waits out its rearm delay, then jumps in.
                    scene.scheduleMissionArrival(missionID: m.id, dudeID: m.shipDude,
                                                 count: max(1, m.shipCount), goal: m.shipGoal,
                                                 behavior: m.shipBehaviorMode, auxiliary: false,
                                                 preferredShipID: am.lockedShipType,
                                                 name: shipName, subtitle: shipSubtitle)
                } else {
                    scene.spawnMissionShips(missionID: m.id, dudeID: m.shipDude,
                                            count: max(1, m.shipCount), goal: m.shipGoal,
                                            behavior: m.shipBehaviorMode, government: nil,
                                            arrival: .populate,
                                            navStellarIndex: (-16 ... -1).contains(m.shipStart) ? -1 - m.shipStart : nil,
                                            startsCloaked: m.shipStart == 2,
                                            preferredShipID: am.lockedShipType,
                                            name: shipName, subtitle: shipSubtitle)
                }
            }
            let auxLeft = m.infiniteAuxShips ? m.auxShipCount : (am.auxShipsRemaining ?? m.auxShipCount)
            if auxLeft > 0, m.auxShipDude >= 128, engine.auxSystemMatches(am, m, currentSystem: currentSys) {
                scene.scheduleMissionArrival(missionID: m.id, dudeID: m.auxShipDude, count: auxLeft,
                                             goal: .none, behavior: .standard, auxiliary: true)
            }
        }
    }

    /// Live auxiliary ships go back to their missions' budgets as the player leaves the system.
    func creditSurvivingAuxShips() {
        guard let scene = host?.scene, let game else { return }
        for (missionID, count) in scene.collectSurvivingAuxiliaryShips() {
            guard let m = game.mission(missionID), !m.infiniteAuxShips,
                  let i = pilot.state.activeMissions.firstIndex(where: { $0.missionID == missionID }) else { continue }
            let left = pilot.state.activeMissions[i].auxShipsRemaining ?? m.auxShipCount
            pilot.state.activeMissions[i].auxShipsRemaining = min(m.auxShipCount, left + count)
        }
    }

    // MARK: Story ticks

    /// Follow the pilot into `systemID`: explored, nebula events, fresh offer rolls.
    func storyArrival(in systemID: Int, via hops: [Int] = []) {
        creditSurvivingAuxShips()
        guard let game else { pilot.state.currentSystem = systemID; return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        engine.playerJumped(toSystem: systemID, via: hops)
        pilot.state = engine.player
    }

    /// `days` of the original's daily tick (date, crön OnStart/OnEnd, deadlines, tribute…).
    func advanceGameDays(_ days: Int) {
        guard days > 0, let game else { return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        engine.advanceDays(days)
        pilot.state = engine.player
        refreshNavVisibility()
        touch()
    }

    /// Escort payroll: one period per spaceport visit / travel day.
    func payEscorts(periods: Int) {
        guard periods > 0, let game, !pilot.state.hiredEscorts.isEmpty else { return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        _ = engine.processEscortPayroll(periods: periods, skipping: host?.scene.disabledEscortRecordIDs() ?? [])
        pilot.state = engine.player
    }

    /// The per-tick mission pass, run where it can change anything: after a jump's days, on launch.
    func runMissionFlightPass() {
        guard let game, !pilot.state.activeMissions.isEmpty else { return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        engine.missionFlightPass()
        pilot.state = engine.player
    }

    func missionShipLost(_ missionID: Int, _ goal: MissionShipGoal) {
        guard let game else { return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        if goal == .chaseOff { engine.missionShipLeft(missionID: missionID) }
        else { engine.missionShipDestroyed(missionID: missionID) }
        pilot.state = engine.player
        touch()
    }

    func failActiveMissions(where predicate: (MissionRes) -> Bool, reason: String) {
        guard let game else { return }
        let ids = pilot.state.activeMissions.map(\.missionID)
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        var failedAny = false
        for id in ids {
            guard let m = game.mission(id), predicate(m) else { continue }
            engine.failMission(id)
            failedAny = true
        }
        guard failedAny else { return }
        pilot.state = engine.player
        host?.hud.post(reason)
        touch()
    }

    /// The active missions with their live objectives, for the debug panel's objective list.
    var missionSummaries: [StoryEngine.MissionSummary] {
        guard let game else { return [] }
        return StoryEngine(game: game, player: pilot.state).activeMissionSummaries()
    }

    // MARK: Sandbox state ↔ flight

    /// Fold the combat consequences played out in flight into the pilot (legal record,
    /// ranks, stellar damage, combat rating).
    func syncCombatStanding() {
        guard let scene = host?.scene else { return }
        pilot.state.applyReputationDelta(scene.consumeReputationDelta())
        if let game {
            for crime in scene.consumeCrimeEvents() {
                pilot.state.revokeRanks(forCrime: crime.kind, against: crime.victim, game: game)
            }
        }
        let armor = scene.liveStellarStrength
        if !armor.isEmpty {
            var left = pilot.state.stellarStrengthLeft ?? [:]
            for (id, value) in armor where !pilot.state.isStellarDestroyed(id) && value >= 0 { left[id] = value }
            pilot.state.stellarStrengthLeft = left
        }
        let delta = scene.consumeCombatRatingDelta()
        if delta != 0 {
            pilot.state.combatRating = CombatRatingRule.fold(pilot.state.combatRating, adding: delta)
            scene.syncPlayerCombatRating(pilot.state.combatRating)
        }
    }

    /// Spent munitions stay spent (the pilot's owned ammunition and fighters).
    func recordMunitions() {
        guard let ship = host?.scene.playerShip, ship.isAlive, let game else { return }
        Munitions.record(ship, into: &pilot.state, game: game)
    }

    /// Immediately reflect a spaceport transaction (new ship, refuel, repair) in the HUD.
    func syncHUDFromPilotState() {
        guard let host, let galaxy = host.galaxy, let game = host.game else { return }
        let state = pilot.state
        host.hud.credits = state.credits
        let res = game.ship(state.shipType)
        host.hud.shipName = state.shipName.isEmpty ? (res?.displayName ?? "") : state.shipName
        guard let lo = PilotEconomy.loadout(state, galaxy: galaxy) else { return }
        let fuel = state.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
        let shield = state.shield.map { min($0, lo.maxShield) } ?? lo.maxShield
        let armor = state.armor.map { min($0, lo.maxArmor) } ?? lo.maxArmor
        host.scene.syncLiveHUDStats(fuel: fuel, maxFuel: lo.maxFuel, shield: shield, maxShield: lo.maxShield,
                                    armor: armor, maxArmor: lo.maxArmor)
        host.hud.cargoCapacity = PilotEconomy.cargoCapacity(state, galaxy: galaxy)
        host.hud.cargoUsed = state.usedCargoSpace
        host.hud.maxSpeed = lo.speed
    }

    // MARK: Landing

    /// Dock at `id`: the story's landing pass runs (deliveries, pickups, completions), the
    /// landing fee is charged and the hull repaired; the view then shows the real spaceport.
    func land(_ id: Int) {
        guard landedSpobID == nil, host != nil else { return }
        host?.scene.cancelCombatChatter()
        departedSpobID = id
        landedSpobID = id           // set first: a `Q` fired by the landing pass can take off again
        applyPause()
        pilot.state.landedSpob = id
        pilot.visitDays = SpaceportVisitDays()
        if let fuel = host?.scene.playerShip?.fuel { pilot.state.fuel = fuel }
        syncCombatStanding()
        creditSurvivingAuxShips()
        if let game {
            let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
            engine.playerLanded(onSpob: id)
            pilot.state = engine.player
        }
        repairOnLanding(spobID: id)
        recordMunitions()
        syncHUDFromPilotState()
        touch()
    }

    private func repairOnLanding(spobID: Int) {
        guard let ship = host?.scene.playerShip, let game, let spob = game.spob(spobID) else { return }
        let fee = LandedServices.landingFee(spob: spob, state: pilot.state)
        if fee > 0 { pilot.state.credits = max(0, pilot.state.credits - fee) }
        ship.shield = ship.maxShield
        ship.armor = ship.maxArmor
        pilot.state.armor = ship.armor
        pilot.state.shield = ship.shield
    }

    // MARK: Take-off

    /// Leave the spaceport: the escort pass, payroll and the visit's days run (crön tick), the
    /// launch hook fires, the ship is rebuilt from the sandbox pilot (hull / outfits / cargo /
    /// fuel) and the system is reloaded in place around it.
    func takeOff() {
        guard landedSpobID != nil, !departing else { return }
        guard let host, let game, let build, let spob = departedSpobID else { landedSpobID = nil; return }
        departing = true
        defer { departing = false }

        if let spobRes = game.spob(spob) {
            let pass = pilot.runEscortFleetPass(at: spobRes, game: game,
                                                disabled: host.scene.disabledEscortRecordIDs())
            if pass.transactions > 0 {
                for id in pass.soldIDs { host.scene.despawnEscort(recordID: id) }
                missionServices.showStoryText(PilotEconomy.escortFleetPassText(pass, game: game), title: "")
            }
        }
        payEscorts(periods: 1)
        advanceGameDays(pilot.visitDays.departureDays)
        pilot.visitDays = SpaceportVisitDays()
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        let launchMessage = engine.playerLaunched()
        pilot.state = engine.player
        pilot.state.landedSpob = nil

        let quote = stagedLaunchQuote
        stagedLaunchQuote = nil
        shipID = pilot.state.shipType

        if dockedMove != nil {
            // A story move while docked: launch into the new system with a fresh ship.
            dockedMove = nil
            let sys = pilot.state.currentSystem
            landedSpobID = nil; departedSpobID = nil
            nav.configure(game: game, startSystemID: sys)
            rebuildTask?.cancel()
            Task { [weak self] in
                guard let self else { return }
                await self.installHost(systemID: sys, shipID: self.pilot.state.shipType, pose: nil)
                self.applyPause()
            }
            return
        }

        guard let session = departureShip(game: game, galaxy: build.galaxy) else {
            landedSpobID = nil; applyPause(); return
        }
        host.editorRefreshHUD(shipType: pilot.state.shipType, credits: pilot.state.credits)
        host.hud.shipName = session.name
        let art = session.art
        host.scene.reloadForDeparture(spobID: spob, player: session.ship, textures: art.textures,
                                      engineTextures: art.engine, shieldTextures: art.shield,
                                      lightTextures: art.lights, weaponGlowTextures: art.weaponGlow,
                                      altTextures: art.alt, hullAnim: art.hullAnim)
        nav.attachShip(host.scene.playerShip)
        landedSpobID = nil
        departedSpobID = nil
        applyPause()
        systemEntered()
        syncHUDFromPilotState()
        let line = quote.flatMap { $0.isEmpty ? nil : $0 } ?? launchMessage
        host.hud.post(line.flatMap { $0.isEmpty ? nil : $0 } ?? "Launched from \(game.spob(spob)?.displayName ?? "the stellar").")
        touch()
    }

    /// The player's ship from the sandbox pilot: hull, outfits, hold, fuel and damage carried,
    /// owned fighters loaded (the editor twin of `GameHost.buildPlayerShip`).
    private func departureShip(game: NovaGame, galaxy: Galaxy) -> (ship: Ship, art: GameHost.EditorShipArt, name: String)? {
        let s = pilot.state
        guard let ship = GameHost.editorShip(game: game, galaxy: galaxy, shipID: s.shipType, outfits: s.outfits) else {
            return nil
        }
        ship.cargo = s.cargo
        if let lo = PilotEconomy.loadout(s, galaxy: galaxy) {
            ship.fuel = s.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
            ship.fuelRegenPerSec = lo.playerFuelRegenPerSec
        }
        ship.armor = s.armor.map { min($0, ship.maxArmor) } ?? ship.maxArmor
        ship.shield = s.shield.map { min($0, ship.maxShield) } ?? ship.maxShield
        Munitions.loadCarriedFighters(into: ship, state: s, game: game)
        let res = game.ship(s.shipType)
        let name = s.shipName.isEmpty ? (res?.displayName ?? "") : s.shipName
        return (ship, GameHost.editorShipArt(game: game, shipID: s.shipType), name)
    }

    // MARK: Hyperjump

    /// Engage the hyperdrive along the map's armed route (the `J` key / map button). On
    /// arrival: fuel spent, the story follows the pilot, the travel days run (crön tick),
    /// payroll, and the mission flight pass (a deadline that ran out fails now).
    @discardableResult
    func attemptJump() -> Bool {
        guard let host, let game, let galaxy = host.galaxy, !host.scene.isJumping else { return false }
        let hops = nav.nextJumpHopCount
        guard hops > 0 else { host.hud.post("No hyperspace course is armed — open the map (M)."); return false }
        guard nav.canAfford(hops: hops) else { host.hud.post("Insufficient fuel for a jump."); return false }
        host.scene.hyperspaceNoJumpRadius = pilot.hyperspaceNoJumpRadius(galaxy: galaxy)
        guard host.scene.canEnterHyperspace() else { nav.showingMap = false; return true }
        let destID = nav.route[hops - 1]
        var outbound = 0.0
        if let a = game.system(nav.currentSystemID), let b = game.system(nav.route[0]), a.x != b.x || a.y != b.y {
            outbound = atan2(Double(b.x - a.x), Double(-(b.y - a.y)))
        }
        let fast = pilot.hasInstantJump(galaxy: galaxy)
        let speed = pilot.jumpSpeedFactor(galaxy: galaxy)
        nav.showingMap = false
        host.scene.beginJump(to: destID, outboundHeading: outbound, instant: fast, speed: speed) { [weak self] in
            guard let self else { return }
            let days = max(PilotEconomy.travelDays(self.pilot.state, galaxy: galaxy),
                           self.host?.scene.attachedShipsTravelDays() ?? 0)
            let passedThrough = Array(self.nav.route.prefix(max(0, hops - 1)))
            _ = self.nav.commitArrival(at: destID, hops: hops)
            self.pilot.state.fuel = self.host?.scene.playerShip?.fuel
            self.storyArrival(in: destID, via: passedThrough)
            self.advanceGameDays(days)
            self.payEscorts(periods: days)
            self.runMissionFlightPass()
            // Mission ships and escorts attach in `systemReloaded` → `systemEntered`.
        }
        return true
    }

    // MARK: Hail

    /// Hail the selected ship (or `stellar`: the selected stellar) and open the comm window.
    func hailTarget(stellar: Bool = false) {
        guard let scene = host?.scene, let game, landedSpobID == nil, hail == nil, boardManifest == nil else { return }
        guard let result = scene.attemptHail(stellar: stellar) else {
            host?.hud.post("Select a ship or stellar first (T / R, or click one).")
            return
        }
        switch result {
        case let .ship(entityID, name, shipTypeID, govt, hostile):
            hailShip(scene, game, entityID: entityID, name: name, shipTypeID: shipTypeID, govt: govt, hostile: hostile)
        case let .planet(spobID, name, _, landable):
            hailStellar(scene, game, spobID: spobID, name: name, landable: landable)
        }
    }

    private func hailShip(_ scene: GameScene, _ game: NovaGame, entityID: Int, name: String, shipTypeID: Int,
                          govt: GovtRes?, hostile: Bool) {
        let strings = game.stringList(2002)
        if scene.isPlayerEscort(entityID) {
            host?.hud.post("Escort orders aren't part of the test run.")
            return
        }
        let personID = scene.personID(forEntity: entityID)
        let check = scene.originalHailCheck(entityID: entityID)
        switch check {
        case .beep?: return
        case let .message(index)?:
            host?.hud.post(strings?.string(at: index) ?? "No response.")
            return
        case .escortWindow?:
            host?.hud.post("Escort orders aren't part of the test run.")
            return
        case .open?, nil: break
        }
        if check == nil, personID == nil, govt?.cantBeHailed == true {
            host?.hud.post(strings?.string(at: 53) ?? "No response.")
            return
        }
        let commName = govt?.commName ?? "Independent"
        var displayName = commName
        var response: String
        if hostile { response = "They aren't interested in talking." }
        else if govt?.nonTalkative == true { response = "This is \(commName). They have nothing further to say." }
        else { response = "This is \(commName). Go ahead." }
        var customPictID: Int?
        // A named person (përs): its quote, picture and LinkMission offer.
        if let pid = personID, let pers = game.pers(pid) {
            let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
            let disabled = scene.isEntityDisabled(entityID)
            let attacking = scene.isEntityAttackingPlayer(entityID)
            let enc = PersEncounter.hail(pers, player: pilot.state, game: game, engine: engine,
                                         disabled: disabled, attacking: attacking)
            displayName = enc.name
            customPictID = enc.hailPictID
            if let quote = enc.commQuote ?? enc.hailQuote { response = quote }
            presentPersMissionOffer(pid, missionID: enc.offerMissionID, engine: engine, game: game)
            if pers.quoteOnce { pilot.state.markPersQuoteShown(pid) }
        }
        var classLine = (strings?.string(at: 195) ?? "Class:") + " "
        if let hull = game.ship(shipTypeID) {
            classLine += hull.name
            if !hull.subtitle.isEmpty { classLine += " (\(hull.subtitle))" }
        }
        var state = HailDialogState(kind: .ship(entityID: entityID, shipTypeID: shipTypeID),
                                    name: displayName, govtLabel: classLine, hostile: hostile,
                                    responseText: response, customPictID: customPictID)
        if scene.originalKeepsPressingPlayer(entityID: entityID) {
            state.statusText = (strings?.string(at: 196) ?? "Status:") + " " + (strings?.string(at: 174) ?? "Hostile")
            state.statusHostile = true
        }
        hail = state
    }

    private func hailStellar(_ scene: GameScene, _ game: NovaGame, spobID: Int, name: String, landable: Bool) {
        guard let spob = game.spob(spobID) else { return }
        var latch = bribeLatch
        guard let comm = StellarComm.open(spob: spob, system: systemID, state: pilot.state, game: game,
                                          diplomacy: host?.galaxy?.makeDiplomacy(),
                                          bribeLatch: &latch, rand: { Int.random(in: 0..<max(1, $0)) }) else {
            host?.hud.post(game.stringList(2002)?.string(at: 53) ?? "No response.")
            return
        }
        bribeLatch = latch
        scene.noteStellarCommOpened()
        var state = HailDialogState(kind: .planet(spobID: spobID), name: name,
                                    govtLabel: StellarComm.classFragment(spob: spob, game: game), hostile: false,
                                    landable: landable,
                                    responseText: comm.openingText(spob: spob, state: pilot.state, game: game))
        state.comm = comm
        let status = comm.status(spob: spob, system: systemID, state: pilot.state, game: game)
        state.statusText = status?.text
        state.statusHostile = status?.hostile ?? false
        if comm.denied { state.topButtonTitle = host?.graphics?.buttonLabel(SpaceportLabel.offerBribe, fallback: "Offer Bribe") ?? "Offer Bribe" }
        state.tributeVisible = false          // tribute / domination isn't simulated in the test run
        hail = state
    }

    /// The Greetings button.
    func hailGreetings() {
        guard var state = hail else { return }
        if case let .planet(spobID) = state.kind, let comm = state.comm, let game, let spob = game.spob(spobID) {
            switch comm.greetings(spob: spob, state: pilot.state, game: game) {
            case let .reply(text): state.responseText = text
            case let .offerBribe(prompt, _): state.responseText = prompt + "\n(Bribes aren't simulated in the test run.)"
            }
        } else {
            state.responseText = state.hostile ? "They don't seem interested in talking." : "Just a routine hail, nothing more."
        }
        hail = state
    }

    func closeHail() { hail = nil }

    func hailPortrait(_ state: HailDialogState) -> CGImage? {
        if let pictID = state.customPictID, let custom = host?.graphics?.pict(pictID) { return custom }
        switch state.kind {
        case let .ship(_, shipTypeID):
            guard let res = game?.ship(shipTypeID) else { return nil }
            return host?.graphics?.shipPicture(res)
        case let .planet(spobID):
            if let sheet = game?.spobSprite(spobID),
               let sprite = HDGraphics.shared.frameImage(for: sheet, frame: 0) ?? sheet.frameCGImage(0) { return sprite }
            guard let spob = game?.spob(spobID) else { return nil }
            return host?.graphics?.landscape(for: spob)
        }
    }

    // MARK: A përs's LinkMission offer (hail / board)

    func presentPersMissionOffer(_ personID: Int, missionID: Int?, engine: StoryEngine, game: NovaGame) {
        guard let missionID, let mission = game.mission(missionID) else { return }
        persOfferEngine = engine
        persOfferPersonID = personID
        if !engine.present(mission) {
            pilot.state = engine.player          // a can't-refuse offer with no text activated silently
            persOfferEngine = nil; persOfferPersonID = nil
        }
    }

    func acceptPersOffer(_ offer: MissionOffer) {
        guard let engine = persOfferEngine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        if let pid = persOfferPersonID, let pers = game?.pers(pid) {
            if pers.deactivateAfterMission { pilot.state.recordPersDefeated(pid) }
            if pers.leaveAfterMission { host?.scene.sendPersonDeparting(personID: pid) }
        }
        missionServices.pendingOffer = nil
        persOfferEngine = nil; persOfferPersonID = nil
        spawnActiveMissionShips()
        touch()
    }

    func declinePersOffer(_ offer: MissionOffer) {
        guard let engine = persOfferEngine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        missionServices.pendingOffer = nil
        persOfferEngine = nil; persOfferPersonID = nil
        touch()
    }

    // MARK: Board / plunder

    func boardTarget() {
        guard landedSpobID == nil, hail == nil, boardManifest == nil, let scene = host?.scene,
              let m = scene.attemptBoard() else { return }
        boardManifest = m
        plunderPanic = World.PlunderPanic(rand: { Int.random(in: 0..<$0) })
        // A përs's ItemClass loot is handed over on boarding; its LinkMission may be offered.
        let loot = scene.plunderOutfits(m.shipID)
        if !loot.isEmpty {
            for oid in loot { pilot.state.grantOutfit(oid) }
            host?.hud.post("Salvaged \(loot.count) item(s).")
            scheduleRebuildKeepingBoard()
        }
        if let pid = scene.personID(forEntity: m.shipID), let game, let pers = game.pers(pid) {
            let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
            let enc = PersEncounter.hail(pers, player: pilot.state, game: game, engine: engine, boarding: true)
            presentPersMissionOffer(pid, missionID: enc.offerMissionID, engine: engine, game: game)
        }
    }

    /// Granted loot changes the loadout; rebuilding the host would drop the boarding, so the
    /// ship is refitted when the dialog closes (see `finishBoarding`).
    private func scheduleRebuildKeepingBoard() { loadoutDirtyDuringBoarding = true }

    private func refreshBoard(_ scene: GameScene, shipID: Int) {
        boardManifest = scene.boardManifest(shipID)
        boardRefresh &+= 1
    }

    private func plunderPress(_ scene: GameScene, _ shipID: Int, _ action: () -> Void) {
        if var panic = plunderPanic {
            let blows = panic.rollsSelfDestruct(rand: { Int.random(in: 0..<$0) })
            plunderPanic = panic
            if blows {
                scene.selfDestructHulk(shipID)
                host?.hud.post(game?.stringList(2002)?.string(at: 113) ?? "The ship self-destructs!")
                plunderPanic = nil
                boardManifest = nil
                return
            }
        }
        action()
    }

    func plunderTakeCredits(_ shipID: Int) {
        guard let scene = host?.scene else { return }
        plunderPress(scene, shipID) {
            let credits = scene.plunderCredits(shipID)
            guard credits > 0 else { return }
            plunderPanic?.looted(.credits)
            pilot.state.credits += credits
            host?.hud.credits = pilot.state.credits
            host?.hud.post("Took \(credits) credits.")
            refreshBoard(scene, shipID: shipID)
        }
    }

    func plunderTakeCargo(_ shipID: Int) {
        guard let scene = host?.scene else { return }
        plunderPress(scene, shipID) {
            guard let game, let galaxy = host?.galaxy else { return }
            let room = PilotEconomy.cargoFree(pilot.state, galaxy: galaxy)
            let offered = scene.boardingManifest(shipID)?.cargo.first
            let taken = scene.plunderCargo(shipID, room: room)
            guard offered != nil else { return }
            plunderPanic?.looted(.cargo)
            let text = OriginalText(game: game)
            guard let (commodity, tons) = taken.first else {
                host?.hud.post(text.misc(114))
                refreshBoard(scene, shipID: shipID)
                return
            }
            pilot.state.cargo[commodity, default: 0] += tons
            host?.scene.playerShip?.cargo = pilot.state.cargo
            let name = Commodity(rawValue: commodity).map { game.commodityName($0) } ?? ""
            host?.hud.post("\(text.misc(115)) \(OriginalText.grouped(tons)) \(text.misc(tons == 1 ? 1 : 2)) \(text.misc(391)) \(name) \(text.misc(108))")
            refreshBoard(scene, shipID: shipID)
        }
    }

    func plunderTakeFuel(_ shipID: Int) {
        guard let scene = host?.scene else { return }
        plunderPress(scene, shipID) {
            let took = scene.plunderFuel(shipID)
            guard took >= 1 else { return }
            plunderPanic?.looted(.fuel)
            pilot.state.fuel = scene.playerShip?.fuel
            host?.hud.post("Siphoned \(Int(took)) fuel.")
            refreshBoard(scene, shipID: shipID)
        }
    }

    func plunderTakeAmmo(_ shipID: Int) {
        guard let scene = host?.scene else { return }
        plunderPress(scene, shipID) {
            let rounds = scene.plunderAmmo(shipID, freeMass: plunderFreeMass)
            guard rounds > 0 else { return }
            plunderPanic?.looted(.ammo)
            host?.hud.post("Transferred \(rounds) round\(rounds == 1 ? "" : "s") of ammunition.")
            refreshBoard(scene, shipID: shipID)
        }
    }

    var plunderFreeMass: Int {
        guard let galaxy = host?.galaxy else { return .max }
        return pilot.freeMass(galaxy: galaxy)
    }

    func plunderCaptureUnsupported() {
        host?.hud.post("Capturing from the plunder dialog isn't simulated — use Capture in the debug panel.")
    }

    /// Close the plunder dialog: the hulk stays adrift, disabled.
    func finishBoarding() {
        guard let m = boardManifest else { return }
        host?.scene.finishBoardingWithoutCapture(m.shipID)
        plunderPanic = nil
        boardManifest = nil
        if loadoutDirtyDuringBoarding {
            loadoutDirtyDuringBoarding = false
            scheduleRebuild()
        }
    }
}
#endif
