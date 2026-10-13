import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The in-flight communication window's rules — the ship hail (`HailDialogView`
/// DITL #1007) and the stellar comm (DITL #1009) — as state a frontend drives
/// with button presses. Extracted from the Apple app's `GameContainerView` so the
/// Godot frontend runs the same lines, rolls and effects; the dialog itself (art,
/// layout, focus) stays the frontend's job.
///
/// Everything the dialog shows is data on `FlightHail`; every button is one of
/// `pressTop` / `pressMiddle` / `pressPayment` / `close`. Text comes from the
/// original's own resources (STR# 150 button labels, 2002 misc strings, 3000/3001
/// ship prompts, 3002 stellar prompts) through `OriginalComms`, `StellarComm`,
/// `PaymentWindow` and `PersEncounter`.
public final class FlightComm {

    /// What the comm window shows right now.
    public struct FlightHail: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case ship(entityID: Int, shipTypeID: Int)
            case planet(spobID: Int)
        }
        /// The negotiation sub-window (DLOG 1008) over the comm window.
        public struct Payment: Sendable, Equatable {
            public var message: String
            public var acceptTitle: String
            public var lowerTitle: String
            public var price: Int
        }
        public var kind: Kind
        public var name: String
        /// "Class: <hull>" (ship) or the stellar's class blurb.
        public var classLine: String
        public var statusText: String?
        public var statusHostile = false
        public var responseText: String
        /// A `pêrs`'s custom `HailPict`, overriding the default portrait.
        public var customPictID: Int?
        /// Top button: Greetings (ship), Greetings / Offer Bribe (planet).
        public var topTitle: String
        /// Middle button: Request Assistance / Beg For Mercy / Release (ship),
        /// Demand Tribute / Release (planet).
        public var middleTitle: String
        public var middleVisible: Bool
        public var middleEnabled: Bool
        public var closeTitle: String
        public var payment: Payment?
    }

    /// What pressing Hail did.
    public enum Opening: Equatable, Sendable {
        /// Nothing selected / nothing to hail: silent.
        case nothing
        /// A refusal: snd 153 (`beep` 4) and an optional status-line message.
        case refused(message: String?)
        /// The target is one of the player's own escorts: the Escorts window.
        case escortWindow
        /// The comm window is open (`hail`); snd 154 sounds.
        case window
    }

    public private(set) var hail: FlightHail?
    private var session: OriginalComms.Session?
    private var shipPayment: (window: PaymentWindow, effect: OriginalComms.Effect)?
    private var planetPayment: PaymentWindow?
    private var stellar: StellarComm?
    private var assistRequested = false
    private var pendingEscortRelease: Int?
    /// A pêrs the opened hail belongs to, with the LinkMission it offers right
    /// now (the frontend presents the offer like the bar does).
    public private(set) var persOffer: (personID: Int, missionID: Int)?
    /// The per-jump `Rand(100)` bribe latch (−1 until rolled); reset on each jump.
    public var bribeLatch = -1
    /// EC-25: the stellar a paid bribe was settled at - the original's approach timer set to
    /// 0x2ef with `DAT_00597a10` at that stellar. It is one approach, not a permit: the next
    /// Land press (on **any** selected body) waives `MinStatus`, and the first press then
    /// consumes it (`consumeBribeWaiver`). `Require`, a fee and the rest of the ladder still apply.
    public private(set) var bribeWaiverStellar: Int?
    /// Whether the approach timer holds a bribe (above 0x2ed).
    public var hasBribeWaiver: Bool { bribeWaiverStellar != nil }
    /// The waiver ends: a Land press ran the ladder, or the ship came within 250 px.
    public func consumeBribeWaiver() { bribeWaiverStellar = nil }

    public init() {}

    public var isOpen: Bool { hail != nil }

    /// A new system: bribes and the latch reset.
    public func systemChanged() {
        bribeLatch = -1
        bribeWaiverStellar = nil
        dismiss()
    }

    // MARK: Opening

    /// Hail the ship `entityID` (0x00454910, then the comm window 0x0047e470).
    public func openShip(entityID: Int, world: World, game: NovaGame, pilot: inout PlayerState) -> Opening {
        dismiss()
        guard let ship = world.ship(id: entityID), ship.isAlive, !ship.isPlayer else { return .nothing }
        let strs = game.stringList(2002)
        // A beep while cloaked or jumping; "No response." for disabled ships, the
        // Enforcer and Flags-0x0400 governments; "entering hyperspace" for a
        // ship spinning up; the Escorts window for the player's own.
        switch world.originalAI.hailCheck(ship, world: world) {
        case .beep: return .refused(message: nil)
        case let .message(index): return .refused(message: strs?.string(at: index) ?? "")
        case .escortWindow: return .escortWindow
        case .open: break
        }
        let govt = game.govt(ship.government)
        // The comm identifies a generic ship by its government's `CommName`.
        var displayName = govt?.commName ?? "Independent"
        var customPictID: Int?
        var persCommQuote: String?
        persOffer = nil
        if let pid = ship.personID, let pers = game.pers(pid) {
            let engine = StoryEngine(game: game, player: pilot)
            let attacking = ship.brain?.state == .attacking && ship.brain?.targetID == World.playerEntityID
            let enc = PersEncounter.hail(pers, player: pilot, game: game, engine: engine,
                                         disabled: ship.disabled, attacking: attacking)
            displayName = enc.name
            customPictID = enc.hailPictID
            persCommQuote = enc.commQuote
            if let mid = enc.offerMissionID { persOffer = (pid, mid) }
            if pers.quoteOnce { pilot.markPersQuoteShown(pid) }
        }
        // The window's two identifier lines: "Class: <hull> (<subtitle>)" and a
        // "Status:" line while the ship presses its attack or flies for you.
        var classLine = (strs?.string(at: 195) ?? "Class:") + " "
        if let hull = game.ship(ship.shipTypeID) {
            classLine += hull.name
            if !hull.subtitle.isEmpty { classLine += " (\(hull.subtitle))" }
        }
        let statusLabel = strs?.string(at: 196) ?? "Status:"
        var statusText: String?
        var statusHostile = false
        let pressing = world.originalAI.keepsPressingPlayer(ship, world: world)
        if pressing {
            statusText = statusLabel + " " + (strs?.string(at: 174) ?? "Hostile")
            statusHostile = true
        } else if let recordID = ship.escortRecordID {
            let hired = pilot.escort(id: recordID)?.origin == .hired
            statusText = statusLabel + " " + (hired ? (strs?.string(at: 166) ?? "Hired Escort")
                                                    : (strs?.string(at: 168) ?? "Escort"))
        }
        // The original AI's comm session: one set of rolls per hail.
        let session = world.originalAI.openComm(with: ship, world: world, playerCredits: pilot.credits,
                                                context: Self.greetingContext(persCommQuote: persCommQuote,
                                                                         pilot: pilot, game: game))
        self.session = session
        var line = Self.shipLine(session.openingPrompt, session, game)
        if session.appendsPilotName { line += pilot.pilotName + "." }
        var middle = Self.label(game, 23, "Request Assistance")
        if session.isPlayerEscort {
            middle = Self.label(game, 32, "Release")
        } else if pressing {
            middle = Self.label(game, 25, "Beg For Mercy")
        }
        assistRequested = false
        hail = FlightHail(kind: .ship(entityID: entityID, shipTypeID: ship.shipTypeID),
                          name: displayName, classLine: classLine, statusText: statusText,
                          statusHostile: statusHostile, responseText: line, customPictID: customPictID,
                          topTitle: Self.label(game, 22, "Greetings"), middleTitle: middle,
                          middleVisible: !session.noAssistance, middleEnabled: !session.noAssistance,
                          closeTitle: Self.label(game, 21, "Close Channel"), payment: nil)
        return .window
    }

    /// Hail stellar `spobID` (the stellar comm window, 0x00480030): an
    /// uninhabited stellar or a gate gets no window, just "No response."
    public func openPlanet(spobID: Int, world: World, game: NovaGame, pilot: inout PlayerState,
                           systemID: Int) -> Opening {
        dismiss()
        guard let spob = game.spob(spobID) else { return .nothing }
        // The window reads the per-system reputation: fold in this session's
        // crimes first.
        Self.syncStanding(world: world, game: game, pilot: &pilot)
        var latch = bribeLatch
        let comm = StellarComm.open(spob: spob, system: systemID, state: pilot, game: game,
                                    diplomacy: world.diplomacy, bribeLatch: &latch,
                                    rand: { Int.random(in: 0..<max(1, $0)) })
        bribeLatch = latch
        guard let comm else {
            return .refused(message: game.stringList(2002)?.string(at: 53) ?? "No response.")
        }
        world.commQuoteRoll = -1   // the original resets the greeting quote roll (0x00480098)
        stellar = comm
        persOffer = nil
        assistRequested = false
        var window = FlightHail(kind: .planet(spobID: spobID), name: spob.name,
                                classLine: StellarComm.classFragment(spob: spob, game: game),
                                responseText: comm.openingText(spob: spob, state: pilot, game: game),
                                topTitle: "", middleTitle: "", middleVisible: true, middleEnabled: true,
                                closeTitle: Self.label(game, 21, "Close Channel"), payment: nil)
        refreshPlanet(&window, spob: spob, systemID: systemID, pilot: pilot, game: game)
        hail = window
        return .window
    }

    /// The parts of the stellar window that follow the pilot's state: the status
    /// line and the two action buttons' titles.
    private func refreshPlanet(_ w: inout FlightHail, spob: SpobRes, systemID: Int, pilot: PlayerState,
                               game: NovaGame) {
        guard let comm = stellar else { return }
        let status = comm.status(spob: spob, system: systemID, state: pilot, game: game)
        w.statusText = status?.text
        w.statusHostile = status?.hostile ?? false
        w.topTitle = comm.denied ? Self.label(game, 24, "Offer Bribe") : Self.label(game, 22, "Greetings")
        if pilot.hasDominated(spob.id) {
            w.middleTitle = Self.label(game, 32, "Release")
            w.middleVisible = !spob.startsDominated   // hidden on an always-dominated stellar (0x004a0f90)
        } else {
            w.middleTitle = Self.label(game, 45, "Demand Tribute")
            w.middleVisible = true
        }
        w.middleEnabled = true
    }

    // MARK: Buttons

    /// Greetings (both windows) / Offer Bribe (a refused stellar).
    public func pressTop(world: World, game: NovaGame, pilot: inout PlayerState) {
        guard var window = hail, window.payment == nil else { return }
        switch window.kind {
        case .ship:
            guard let session, let ship = world.ship(id: session.entityID) else { return }
            switch world.originalAI.pressGreetings(session, ship: ship, world: world) {
            case .greeting: window.responseText = session.greeting
            case let .reply(prompt): window.responseText = Self.shipLine(prompt, session, game)
            default: break
            }
            hail = window
        case let .planet(spobID):
            guard let comm = stellar, let spob = game.spob(spobID) else { return }
            switch comm.greetings(spob: spob, state: pilot, game: game) {
            case let .reply(text):
                window.responseText = text
            case let .offerBribe(prompt, price):
                window.responseText = prompt
                planetPayment = PaymentWindow(price: price, rand: { Int.random(in: 0..<max(1, $0)) })
                window.payment = Self.paymentView(planetPayment!, game: game, hasShipTarget: false)
            }
            hail = window
        }
    }

    /// Request Assistance / Beg For Mercy / Release (ship), Demand Tribute /
    /// Release (planet).
    public func pressMiddle(world: World, game: NovaGame, pilot: inout PlayerState, systemID: Int) {
        guard var window = hail, window.payment == nil, window.middleEnabled else { return }
        switch window.kind {
        case .ship:
            guard let session, let ship = world.ship(id: session.entityID) else { return }
            switch world.originalAI.pressAssistance(session, ship: ship, world: world) {
            case let .reply(prompt):
                window.responseText = Self.shipLine(prompt, session, game)
            case .greeting, .nothing:
                break
            case let .releaseEscort(prompt):
                window.responseText = Self.shipLine(prompt, session, game)
                assistRequested = true
                window.middleEnabled = false
                pendingEscortRelease = session.entityID
            case let .done(prompt, effect):
                var s = session
                _ = world.originalAI.settle(&s, effect: effect, paid: true, ship: ship, world: world)
                self.session = s
                window.responseText = Self.shipLine(prompt, session, game)
                assistRequested = true
                window.middleEnabled = false
            case let .offer(prompt, price, free, effect):
                window.responseText = Self.shipLine(prompt, session, game)
                hail = window
                if free {
                    settleShip(effect: effect, paid: true, price: 0, world: world, game: game, pilot: &pilot)
                    return
                }
                let pay = PaymentWindow(price: price, rand: { Int.random(in: 0..<max(1, $0)) })
                shipPayment = (pay, effect)
                window.payment = Self.paymentView(pay, game: game, hasShipTarget: true)
            }
            hail = window
        case let .planet(spobID):
            guard var comm = stellar, let spob = game.spob(spobID) else { return }
            if pilot.hasDominated(spobID) {
                guard !spob.startsDominated else { return }
                world.releaseStellar(spobID: spobID)
                let engine = StoryEngine(game: game, player: pilot)
                engine.releaseStellar(spobID)
                pilot = engine.player
                Self.syncStanding(world: world, game: game, pilot: &pilot)
                window.responseText = StellarComm.releaseReply(spob: spob, game: game)
                refreshPlanet(&window, spob: spob, systemID: systemID, pilot: pilot, game: game)
                hail = window
                return
            }
            // Every demand is a crime against the stellar's government (the engine
            // applies it); below a combat rating of 12,800 it is laughed off; a
            // stellar with nothing left to fight submits to the first demand;
            // otherwise it launches its defenders.
            world.playerCombatRating = pilot.combatRating
            world.dominatedStellars.formUnion(pilot.dominatedStellars ?? [])
            let outcome = world.demandTribute(spobID: spobID, firstPressInWindow: !comm.tributePressed)
            comm.tributePressed = true
            stellar = comm
            Self.syncStanding(world: world, game: game, pilot: &pilot)
            let reply = comm.tributeReply(outcome, spob: spob, game: game)
            if !reply.isEmpty { window.responseText = reply }
            refreshPlanet(&window, spob: spob, systemID: systemID, pilot: pilot, game: game)
            hail = window
        }
    }

    /// A press in the negotiation window: Accept Price (`pay`) or Lower Price.
    public func pressPayment(_ press: PaymentWindow.Press, world: World, game: NovaGame,
                             pilot: inout PlayerState, systemID: Int) {
        guard var window = hail, window.payment != nil else { return }
        switch window.kind {
        case .ship:
            guard var payment = shipPayment else { return }
            switch payment.window.press(press) {
            case .open:
                shipPayment = payment
                window.payment = Self.paymentView(payment.window, game: game, hasShipTarget: true)
                hail = window
            case .paid:
                shipPayment = nil
                window.payment = nil
                hail = window
                settleShip(effect: payment.effect, paid: true, price: payment.window.price,
                           world: world, game: game, pilot: &pilot)
            case .refused:
                shipPayment = nil
                window.payment = nil
                hail = window
                settleShip(effect: payment.effect, paid: false, price: payment.window.price,
                           world: world, game: game, pilot: &pilot)
            }
        case let .planet(spobID):
            guard var pay = planetPayment else { return }
            let result = pay.press(press)
            switch result {
            case .open:
                planetPayment = pay
                window.payment = Self.paymentView(pay, game: game, hasShipTarget: false)
                hail = window
            case .paid, .refused:
                planetPayment = nil
                window.payment = nil
                settleBribe(paid: result == .paid, price: pay.price, spobID: spobID, window: window,
                            game: game, pilot: &pilot, systemID: systemID)
            }
        }
    }

    private func settleShip(effect: OriginalComms.Effect, paid: Bool, price: Int, world: World,
                            game: NovaGame, pilot: inout PlayerState) {
        guard var session, var window = hail, let ship = world.ship(id: session.entityID) else { return }
        if paid, pilot.credits < price {
            window.responseText = Self.shipLine(OriginalComms.Prompt.cannotAfford, session, game)
            hail = window
            return
        }
        let prompt = world.originalAI.settle(&session, effect: effect, paid: paid, ship: ship, world: world)
        self.session = session
        if paid, price > 0 { pilot.credits -= price }
        if paid, effect != .bribe {
            assistRequested = true
            window.middleEnabled = false
        }
        window.responseText = Self.shipLine(prompt, session, game)
        hail = window
    }

    private func settleBribe(paid: Bool, price: Int, spobID: Int, window: FlightHail, game: NovaGame,
                             pilot: inout PlayerState, systemID: Int) {
        guard var comm = stellar, let spob = game.spob(spobID) else { return }
        var window = window
        var latch = bribeLatch
        let outcome = comm.settleBribe(paid: paid, price: price, spob: spob, state: &pilot, game: game,
                                       bribeLatch: &latch)
        bribeLatch = latch
        stellar = comm
        switch outcome {
        case let .cannotAfford(text), let .refused(text):
            window.responseText = text
            hail = window
        case let .paid(_, hudLine):
            // Paid: the next Land press waives MinStatus (one approach), and the
            // comm window closes.
            bribeWaiverStellar = spobID
            pendingMessages.append(hudLine)
            dismiss()
        }
    }

    /// Lines for the HUD status line (a paid bribe's clearance).
    public private(set) var pendingMessages: [String] = []
    public func drainMessages() -> [String] {
        defer { pendingMessages.removeAll() }
        return pendingMessages
    }

    /// Close Channel (snd 152). A released mission escort is let go now.
    public func close(world: World?) {
        if let id = pendingEscortRelease, let world, let ship = world.ship(id: id) {
            world.originalAI.releaseEscort(ship, world: world)
        }
        dismiss()
    }

    private func dismiss() {
        hail = nil
        session = nil
        shipPayment = nil
        planetPayment = nil
        stellar = nil
        pendingEscortRelease = nil
        assistRequested = false
    }

    // MARK: Text helpers

    static func label(_ game: NovaGame, _ index: Int, _ fallback: String) -> String {
        game.stringList(150)?.string(at: index) ?? fallback
    }

    /// STR# 3000 entry `prompt × 5 + variant + 1` for the ship comm window.
    static func shipLine(_ prompt: Int, _ session: OriginalComms.Session, _ game: NovaGame) -> String {
        let entry = OriginalComms.promptEntry(prompt, variant: session.variant)
        return game.stringList(entry.list)?.string(at: entry.index) ?? ""
    }

    static func paymentView(_ pay: PaymentWindow, game: NovaGame, hasShipTarget: Bool) -> FlightHail.Payment {
        FlightHail.Payment(message: PaymentWindow.prompt(price: pay.price, game: game, hasShipTarget: hasShipTarget),
                           acceptTitle: label(game, 30, "Accept Price"),
                           lowerTitle: label(game, 31, "Lower Price"), price: pay.price)
    }

    /// The greeting context the engine can't see: active disasters with more
    /// than a day left, the përs CommQuote and the pilot's name (AI-43).
    static func greetingContext(persCommQuote: String?, pilot: PlayerState,
                                game: NovaGame) -> OriginalComms.GreetingContext {
        var disasters: [OriginalComms.Disaster] = []
        for (oopsID, expiry) in (pilot.activeDisasters ?? [:]).sorted(by: { $0.key < $1.key })
        where pilot.date.days(until: expiry) > 1 {
            guard let o = game.oops(oopsID) else { continue }
            let stellar = o.stellar == -1 ? (pilot.disasterStellars?[oopsID] ?? -1) : o.stellar
            guard stellar >= 128 else { continue }
            disasters.append(.init(stellarID: stellar, commodity: o.commodity, priceDelta: o.priceDelta))
        }
        return OriginalComms.GreetingContext(disasters: disasters, persCommQuote: persCommQuote,
                                             pilotName: pilot.pilotName)
    }

    // MARK: Live world → pilot

    /// Fold the crimes, reputation and combat rating the live world accrued into
    /// the pilot (`GameContainerView.syncCombatStanding`): the stellar comm reads
    /// the per-system reputation, and tribute reads the combat rating.
    public static func syncStanding(world: World, game: NovaGame, pilot: inout PlayerState) {
        pilot.applyReputationDelta(world.diplomacy?.consumeReputationDelta() ?? [:])
        for crime in world.diplomacy?.consumeCrimeEvents() ?? [] {
            pilot.revokeRanks(forCrime: crime.kind, against: crime.victim, game: game)
        }
        let delta = world.diplomacy?.consumeCombatRatingDelta() ?? 0
        if delta != 0 {
            pilot.combatRating = CombatRatingRule.fold(pilot.combatRating, adding: delta)
            world.playerCombatRating = pilot.combatRating
        }
    }

    /// A world event that persists into the pilot: a stellar submitting to
    /// tribute (`OnDominate` bits, daily income) or being shot down
    /// (`OnDestroy`, `DeadTime`). Returns the HUD line, or nil for any other event.
    public func apply(event: WorldEvent, game: NovaGame, pilot: inout PlayerState, systemID: Int,
                      world: World) -> String? {
        switch event {
        case let .stellarDominated(spobID):
            let engine = StoryEngine(game: game, player: pilot)
            engine.dominateStellar(spobID)
            pilot = engine.player
            if var window = hail, case let .planet(id) = window.kind, id == spobID, let spob = game.spob(spobID) {
                refreshPlanet(&window, spob: spob, systemID: systemID, pilot: pilot, game: game)
                hail = window
            }
            // The original prints no status line for a surrender (UI-11).
            return nil
        case let .stellarDestroyed(spobID, _, _, _):
            let engine = StoryEngine(game: game, player: pilot)
            engine.stellarShotDown(spobID)
            pilot = engine.player
            return nil   // no status line for a destroyed stellar in the original (UI-11)
        default:
            return nil
        }
    }
}
