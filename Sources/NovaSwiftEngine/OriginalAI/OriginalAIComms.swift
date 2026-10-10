import Foundation
import NovaSwiftKit

/// The ship comm window (`NovaUi_RunTargetShipCommWindow` 0x0047e470) and the
/// hail command in front of it (`Ship_HandlePlayerTargetActionCommand`
/// 0x00454910), as rules the host's dialog drives (AI-42/43/44):
///
/// - `hailCheck`: whether a hail opens the window, beeps, or prints a line;
/// - `openComm`: one session of rolls per window (variant, personality,
///   price), the government/rank flags it reads, the opening prompt and the
///   greeting text (`NovaUi_BuildShipCommHailInfoText` 0x004819d0);
/// - `pressGreetings` / `pressAssistance`: the two buttons. A priced answer
///   goes through Batch 4's shared payment window (DLOG 1008) and is settled
///   with `settle`.
///
/// Every line is STR# 3000 entry `prompt × 5 + variant + 1` (STR# 3001 from
/// prompt 0x26), `NovaUi_LoadTravelDestinationPromptString` 0x004828c0.
public enum OriginalComms {

    /// What a hail does (0x00454910).
    public enum HailCheck: Equatable, Sendable {
        /// The player is cloaked, destroyed or jumping: a beep, nothing else.
        case beep
        /// A beep and STR# 2002 entry `index` on the HUD: #53 "No response."
        /// or #54 "Unable to send hail - target ship is entering hyperspace."
        case message(index: Int)
        /// One of the player's own escorts: the escort window (DLOG 1022).
        case escortWindow
        /// The comm window opens.
        case open
    }

    /// What a paid (or free) answer sets the ship doing.
    public enum Effect: Equatable, Sendable {
        /// Bribe: break off (state 2, behavior 1).
        case bribe
        /// Fuel transfer (state 9) or repair of a disabled player (state 0x0F).
        case assist
        /// Attack a random ship pressing the player (state 4).
        case attackUnengaged
        /// Attack a random threat to the player's squad (behavior ≥ 5, free).
        case attackThreat
        /// A rank 0x0400 ally: attack and call the system's reinforcements.
        case attackAndReinforce
    }

    /// A button's answer.
    public enum Answer: Equatable, Sendable {
        /// Show this prompt.
        case reply(prompt: Int)
        /// Show the session's greeting text.
        case greeting
        /// The button does nothing (government flags_secondary 0x8 mutes it).
        case nothing
        /// Show `prompt`, then put `price` through the payment window (or
        /// settle at once when `free`).
        case offer(prompt: Int, price: Int, free: Bool, effect: Effect)
        /// Done at once: show `prompt` and apply `effect`.
        case done(prompt: Int, effect: Effect)
        /// A player-led mission escort is let go (STR# 3001 farewell); the
        /// host calls `releaseEscort` when the window closes.
        case releaseEscort(prompt: Int)
    }

    /// One comm window's opening rolls and the flags it read at open.
    public struct Session: Equatable, Sendable {
        public let entityID: Int
        /// `Rand(5)`: which of the five lines of each prompt.
        public let variant: Int
        public let personality: Double
        public internal(set) var price: Int
        /// The ship takes bribes (DAT_007d17f2: faction-less; trader of a
        /// Flags-0x2000 government; warship of a Flags-0x0200 one). The
        /// revenge përs and defense ships still refuse when asked.
        public let bribable: Bool
        /// Government flags_secondary 0x10 or an allied rank's 0x0800:
        /// assistance is free.
        public let assistFree: Bool
        /// An allied rank's 0x0400: the ship helps against a threat for free.
        public let rankDefends: Bool
        /// Government flags_secondary 0x0001: no assistance, and Greetings
        /// answers "No response." (local_11).
        public let noAssistance: Bool
        /// flags_secondary 0x0008 on the ship's or its hull's inherent
        /// government: the assistance button does nothing (local_1d).
        public let assistanceMuted: Bool
        /// Government Flags 0x0001 (DAT_007d17f4).
        public let xenophobic: Bool
        /// A warship of a Flags-0x1000 (plunder) government (local_1e).
        public let plunderer: Bool
        /// A ShipBehav-1 mission ship (local_20).
        public let missionProtector: Bool
        /// A non-mission escort of the player: the middle button reads
        /// "Release" (STR# 150 #32).
        public let isPlayerEscort: Bool
        /// The opening prompt (0, 2, 4, 5 or 8).
        public let openingPrompt: Int
        /// Prompt 8 ("Glad to see you, ") is followed by the pilot's name.
        public let appendsPilotName: Bool
        /// The Greetings text, built at open.
        public let greeting: String
    }

    /// The STR# 3000 prompt index a priced offer opens with: personality
    /// below 0.8 → 0x17, up to 1.2 → `middle`, otherwise 0x18. A bribe and
    /// paid help against a threat use 0x12, refuel/repair 0x1C.
    public static func offerPrompt(personality: Double, bribe: Bool) -> Int {
        if Float(personality) < 0.8 { return 0x17 }
        if Float(personality) <= 1.2 { return bribe ? 0x12 : 0x1c }
        return 0x18
    }

    /// STR# 3000 prompts the comm window answers with.
    public enum Prompt {
        public static let channelOpen = 0x00
        public static let noResponse = 0x01
        public static let whatDoYouWant = 0x02
        public static let goodToFlyWithUs = 0x04
        public static let whatCanIDoSir = 0x05
        public static let gladToSeeYou = 0x08
        public static let cannotAfford = 0x0c
        public static let stopWastingTime = 0x0d
        public static let notInTrouble = 0x0e
        public static let busy = 0x10
        public static let ratherNot = 0x11
        public static let refused = 0x13
        public static let bribePaid = 0x14
        public static let cantHelpSir = 0x16
        public static let cantDoThat = 0x19
        public static let onMyWay = 0x1d
        public static let bribeRefused = 0x1e
        public static let assistanceRefused = 0x1f
        /// STR# 3001: a released escort's farewell.
        public static let escortFarewell = 0x26
        /// Greetings' fallback for short or `*` text: STR# 3000 #46–50.
        public static let greetingFallback = 0x2e
    }

    /// The STR# list and 1-based entry of `prompt` for a session variant.
    public static func promptEntry(_ prompt: Int, variant: Int) -> (list: Int, index: Int) {
        prompt < 0x26 ? (3000, prompt * 5 + variant + 1) : (3001, prompt * 5 + variant - 0xbd)
    }

    /// The ship's mood multiplier for this conversation:
    /// `(Rand(0x29) + 0x50) × 0.01`, then −0.5 on a 1-in-5 roll, else +0.5 on
    /// another 1-in-5.
    public static func personality(_ rng: inout NovaRandom) -> Double {
        var p = Double(Float(rng.range(0x29) + 0x50) * Float(0.01))
        if rng.range(5) == 0 {
            p -= 0.5
        } else if rng.range(5) == 0 {
            p += 0.5
        }
        return p
    }

    /// Whether a ship takes a bribe: a faction-less ship always; a trader
    /// (behavior < 3) of a government with Flags 0x2000; a warship of a
    /// government with Flags 0x0200. Defense-fleet ships never do.
    public static func offersBribe(govtFlags: UInt16?, behavior: Int, isDefenseFleet: Bool) -> Bool {
        if isDefenseFleet { return false }
        guard let flags = govtFlags else { return true }
        if flags & 0x2000 != 0 && behavior < 3 { return true }
        if flags & 0x0200 != 0 && behavior > 2 { return true }
        return false
    }

    /// The bribe: `(Rand(⌊credits × 5e-7⌋) × 1000 + 3000) × personality`,
    /// capped at a third of the player's credits, floored to a thousand and
    /// clamped to [1000, 20000]. A government with Flags 0x8000 then rolls
    /// again — `(Rand(⌊credits × 1e-4⌋) × 1000 + 10000) × personality` —
    /// replacing the first price (both draws are taken).
    public static func bribeCost(credits: Int, govtFlags: UInt16, personality: Double,
                                 rng: inout NovaRandom) -> Int {
        func roll(_ scale: Double, _ base: Int) -> Int {
            let upper = max(1, Int(Float(credits) * Float(scale)))
            let pick = rng.range(upper)
            return Int(Float(pick * 1000 + base) * Float(personality))
        }
        var cost = roll(5e-7, 3000)
        if govtFlags & 0x8000 != 0 { cost = roll(1e-4, 10_000) }
        let cap = Float(credits) * Float(0.333)
        if cap < Float(cost) { cost = Int(cap) }
        cost = cost / 1000 * 1000
        return min(20_000, max(1000, cost))
    }

    /// Request Assistance's answer, as the older API reports it.
    public enum AssistanceReply: Equatable, Sendable {
        /// "In your dreams, pal."
        case refused
        /// "I'm busy." / "Sorry sir, I can't help you."
        case busy
        /// "You're not in any trouble."
        case notInTrouble
        /// "I'd rather not."
        case ratherNot
        /// Helps for pay (free with government flags_secondary 0x10): state 9
        /// to refuel, state 0x0F to repair a disabled player, or an attack on
        /// a threat.
        case helps(repair: Bool, againstThreat: Bool)
    }

    /// One active disaster for a trade-gossip greeting: the stellar it hits
    /// (`spöb` id), the commodity index and the price change.
    public struct Disaster: Equatable, Sendable {
        public let stellarID: Int
        public let commodity: Int
        public let priceDelta: Int
        public init(stellarID: Int, commodity: Int, priceDelta: Int) {
            self.stellarID = stellarID
            self.commodity = commodity
            self.priceDelta = priceDelta
        }
    }

    /// What the host knows that the engine doesn't, for the greeting.
    public struct GreetingContext: Sendable {
        /// Disasters with more than one day left (oops +0xc > 1).
        public var disasters: [Disaster]
        /// The resolved përs CommQuote (STR 15000+q, else STR# 7100 #q), or nil.
        public var persCommQuote: String?
        /// The pilot's name, for prompt 8.
        public var pilotName: String
        public init(disasters: [Disaster] = [], persCommQuote: String? = nil, pilotName: String = "") {
            self.disasters = disasters
            self.persCommQuote = persCommQuote
            self.pilotName = pilotName
        }
    }
}

// MARK: - Hail and window rules

extension OriginalAI {

    /// The revenge përs (slot 0x3fe) and the Enforcer (slot 0x3ff).
    static let revengePersID = 0x3fe + 128
    static let enforcerPersID = 0x3ff + 128

    /// `Ship_DoesShipLikePlayer` (0x0040fd20).
    func likesPlayer(_ ship: Ship, host: OriginalAIHost, world: World) -> Bool {
        if keepsPressing(ship, host: host) { return false }
        if leader(of: ship) == World.playerEntityID { return true }
        let g = ship.government
        if host.rankForbidsAutoAttack(g) { return true }
        if ship.missionID != nil {
            guard let goal = ship.missionShipGoal, goal == .escort || goal == .observe else { return false }
            return ship.brain?.behaviorOverride == .protectPlayer
        }
        // A ship with no government likes everyone (the function's 0xff01).
        guard g >= govtResourceBase, let gov = host.govt(g) else { return true }
        let r = host.playerReputationHere
        let o = host.systemGovernment
        func tol(_ id: Int) -> Int { host.govt(id)?.crimeTolerance ?? 0 }
        if gov.xenophobic {
            if g == o {
                if tol(o) < r { return true }
            } else if o < govtResourceBase {
                // The independent arm reads government slot 0's tolerance.
                if tol(govtResourceBase) < r { return false }
            } else if tol(o) < r {
                return false
            }
        }
        if o < govtResourceBase {
            if !gov.nosy || -tol(g) <= r { return true }
        } else if host.areAllied(o, g) {
            if -tol(o) <= r { return true }
        } else if !(host.areHostile(o, g) || (host.govt(g)?.xenophobic ?? false) || (host.govt(o)?.xenophobic ?? false)) {
            if !gov.nosy || -tol(o) <= r { return true }
        } else if r < -tol(o) {
            return true
        }
        if world.diplomacy?.latches.isScrambled(g) == true { return true }
        return false
    }

    /// The hail command on a targeted ship (0x00454910).
    public func hailCheck(_ ship: Ship, world: World) -> OriginalComms.HailCheck {
        let player = world.player
        if player.cloakLevel > 0 || !player.isAlive || world.playerJump != nil { return .beep }
        let host = WorldAIHost(world: world, ai: self)
        if let rec = records[ship.entityID], rec.jumpTimer > 0 {
            return .message(index: ship.disabled ? 53 : 54)
        }
        var can = true
        let ledByPlayer = leader(of: ship) == World.playerEntityID
        if !ledByPlayer || ship.missionID != nil {
            if let g = host.govt(ship.government), g.flags1 & 0x0400 != 0 { can = false }
            let inherent = host.hull(of: ship).inherentCombatGovt
            if inherent >= govtResourceBase, let g = host.govt(inherent), g.flags1 & 0x0400 != 0 { can = false }
        }
        if ship.shipTypeID == 0x2ff + 128 { can = false }
        if ship.disabled { can = false }
        if ship.personID == Self.enforcerPersID { can = false }
        guard can else { return .message(index: 53) }
        let rec = ensureRecord(ship, host: host)
        if rec.behavior == 6, ledByPlayer, ship.missionID == nil { return .escortWindow }
        return .open
    }

    /// Open a comm window with `ship` (0x0047e470): the session's rolls, in
    /// the original's order, then the opening prompt and the greeting.
    public func openComm(with ship: Ship, world: World, playerCredits: Int,
                         context: OriginalComms.GreetingContext = .init()) -> OriginalComms.Session {
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        let govt = host.govt(ship.government)
        let flags1 = govt?.flags1 ?? 0
        let flags2 = govt?.flags2 ?? 0
        var bribable = govt == nil
        if rec.behavior < 3, flags1 & 0x2000 != 0 { bribable = true }
        if rec.behavior > 2, flags1 & 0x0200 != 0 { bribable = true }
        let noAssistance = govt != nil && flags2 & 0x0001 != 0
        var muted = govt != nil && flags2 & 0x0008 != 0
        let inherent = host.hull(of: ship).inherentCombatGovt
        if inherent >= govtResourceBase, let g = host.govt(inherent), g.flags2 & 0x0008 != 0 { muted = true }
        let plunderer = govt != nil && rec.behavior > 2 && flags1 & 0x1000 != 0

        let variant = world.rng.range(5)
        let personality = OriginalComms.personality(&world.rng)
        let price = OriginalComms.bribeCost(credits: playerCredits, govtFlags: flags1,
                                            personality: personality, rng: &world.rng)
        let xenophobic = govt != nil && flags1 & 0x0001 != 0

        // Allied ranks: 0x0400 helps against a threat, 0x0800 free assistance.
        var rankDefends = false, free = false
        for rank in world.diplomacy?.activeRankFlags ?? [] where host.areAllied(ship.government, rank.govt) {
            if rank.flags & 0x0400 != 0 { rankDefends = true }
            if rank.flags & 0x0800 != 0 { free = true }
        }
        if govt != nil, flags2 & 0x0010 != 0 { free = true }
        let protector = ship.missionID != nil && ship.brain?.behaviorOverride == .protectPlayer

        let greeting = buildGreeting(ship, variant: variant, world: world, context: context)

        // The opening line.
        var opening = OriginalComms.Prompt.channelOpen
        var appendsName = false
        if ship.missionID == nil || ship.disabled || noAssistance {
            if ship.disabled || noAssistance {
                opening = OriginalComms.Prompt.channelOpen
            } else if keepsPressing(ship, host: host) {
                opening = OriginalComms.Prompt.whatDoYouWant
            } else if leader(of: ship) != World.playerEntityID {
                opening = likesPlayer(ship, host: host, world: world)
                    ? OriginalComms.Prompt.channelOpen : OriginalComms.Prompt.whatDoYouWant
            } else if rec.behavior == 5 {
                opening = OriginalComms.Prompt.whatCanIDoSir
            } else if rec.behavior == 6 {
                opening = OriginalComms.Prompt.goodToFlyWithUs
            }
        } else {
            if ship.missionShipGoal == .destroy {
                opening = OriginalComms.Prompt.whatDoYouWant
            } else if ship.missionShipGoal == .escort {
                opening = OriginalComms.Prompt.gladToSeeYou
                appendsName = true
            }
            let behav = ship.brain?.behaviorOverride ?? .standard
            if behav == .attackPlayer {
                opening = OriginalComms.Prompt.whatDoYouWant
                appendsName = false
            } else if behav == .protectPlayer {
                opening = OriginalComms.Prompt.goodToFlyWithUs
                appendsName = false
            }
        }
        return OriginalComms.Session(entityID: ship.entityID, variant: variant, personality: personality,
                                     price: price, bribable: bribable, assistFree: free, rankDefends: rankDefends,
                                     noAssistance: noAssistance, assistanceMuted: muted, xenophobic: xenophobic,
                                     plunderer: plunderer, missionProtector: protector,
                                     isPlayerEscort: leader(of: ship) == World.playerEntityID && ship.missionID == nil,
                                     openingPrompt: opening,
                                     appendsPilotName: appendsName, greeting: greeting)
    }

    /// Whether the hailed ship is still pressing its attack on the player —
    /// the assistance button then reads "Beg For Mercy" (STR# 150 #25).
    public func keepsPressingPlayer(_ ship: Ship, world: World) -> Bool {
        keepsPressing(ship, host: WorldAIHost(world: world, ai: self))
    }

    /// The Greetings button (button 3).
    public func pressGreetings(_ session: OriginalComms.Session, ship: Ship, world: World) -> OriginalComms.Answer {
        let host = WorldAIHost(world: world, ai: self)
        guard !ship.disabled, !session.noAssistance else { return .reply(prompt: OriginalComms.Prompt.noResponse) }
        if keepsPressing(ship, host: host) { return .reply(prompt: OriginalComms.Prompt.stopWastingTime) }
        return likesPlayer(ship, host: host, world: world)
            ? .greeting : .reply(prompt: OriginalComms.Prompt.stopWastingTime)
    }

    /// The middle button (button 2): Request Assistance, or Beg For Mercy
    /// while the ship presses its attack.
    public func pressAssistance(_ session: OriginalComms.Session, ship: Ship,
                                world: World) -> OriginalComms.Answer {
        typealias P = OriginalComms.Prompt
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        if ship.disabled {
            return session.noAssistance ? .nothing : .reply(prompt: P.noResponse)
        }
        let ledByPlayer = leader(of: ship) == World.playerEntityID
        if ledByPlayer, rec.behavior == 6, !session.missionProtector {
            return .releaseEscort(prompt: P.escortFarewell)
        }
        if session.assistanceMuted { return .nothing }
        func priced(_ middle: Int, _ effect: OriginalComms.Effect, free: Bool) -> OriginalComms.Answer {
            let prompt: Int
            if Float(session.personality) < 0.8 { prompt = 0x17 }
            else if Float(session.personality) <= 1.2 { prompt = middle }
            else { prompt = 0x18 }
            return .offer(prompt: prompt, price: session.price, free: free, effect: effect)
        }
        if keepsPressing(ship, host: host) {
            // Beg For Mercy.
            if ship.missionID != nil, ship.brain?.behaviorOverride == .attackPlayer {
                return .reply(prompt: P.refused)
            }
            guard rec.defenseHome == nil, ship.personID != Self.revengePersID, session.bribable else {
                return .reply(prompt: P.refused)
            }
            return priced(0x12, .bribe, free: false)
        }
        if !likesPlayer(ship, host: host, world: world) || session.xenophobic || session.plunderer {
            return .reply(prompt: P.refused)
        }
        // Ship_IsThreatened (0x0040fc00) compares the ship's own target with
        // its own slot, so it never fires; only a non-idle state makes it busy.
        let idleStates = [OriginalAIState.idle, OriginalAIState.travel, OriginalAIState.departJump,
                          OriginalAIState.gateEntry, OriginalAIState.scanApproach]
        guard idleStates.contains(rec.state) else {
            if (rec.state == OriginalAIState.refuel || rec.state == OriginalAIState.repair),
               rec.primary == World.playerEntityID {
                return .reply(prompt: P.onMyWay)
            }
            return .reply(prompt: rec.behavior < 5 ? P.busy : P.cantHelpSir)
        }
        let squadThreatened = host.ships.contains { c in
            !c.isPlayer && c.isAlive && (records[c.entityID].map { isThreatToPlayerSquad($0, ship: c, host: host) } ?? false)
        }
        if !squadThreatened {
            let player = world.player
            let lowFuel = player.fuel < 100 && player.maxFuel > 0
            guard lowFuel || player.disabled else { return .reply(prompt: P.notInTrouble) }
            guard rec.behavior < 5 else { return .reply(prompt: P.cantDoThat) }
            return priced(0x1c, .assist, free: session.assistFree)
        }
        guard isThreatenedByEnemy(world.player, of: ship, host: host) else { return .reply(prompt: P.refused) }
        if session.rankDefends { return .done(prompt: P.onMyWay, effect: .attackAndReinforce) }
        switch rec.behavior {
        case 1:
            return .reply(prompt: P.ratherNot)
        case 2:
            let factionless = ship.government < govtResourceBase
            return factionless && ship.entityID % 3 == 0 ? priced(0x12, .attackUnengaged, free: false)
                                                          : .reply(prompt: P.ratherNot)
        case 3, 4:
            return priced(0x12, .attackUnengaged, free: false)
        default:
            return .done(prompt: P.onMyWay, effect: .attackThreat)
        }
    }

    /// The payment window closed (or a free answer settled at once): apply
    /// the effect. Returns the prompt to show: 0x14 / 0x1D when paid, 0x1E
    /// (and the ship turns hostile, the price up 1000) for a refused bribe,
    /// 0x1F for refused help.
    @discardableResult
    public func settle(_ session: inout OriginalComms.Session, effect: OriginalComms.Effect, paid: Bool,
                       ship: Ship, world: World) -> Int {
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        defer { mirror(rec, ship) }
        guard paid else {
            if effect == .bribe {
                setHostileToPlayer(rec, ship: ship, host: host)
                session.price += 1000
                return OriginalComms.Prompt.bribeRefused
            }
            return OriginalComms.Prompt.assistanceRefused
        }
        switch effect {
        case .bribe:
            rec.enterDeparture(clock60: clock60)
            rec.behavior = 1
            return OriginalComms.Prompt.bribePaid
        case .assist:
            beginAssistance(rec, repair: world.player.disabled)
        case .attackUnengaged:
            attackRandomUnengaged(rec, ship: ship, host: host)
        case .attackThreat:
            attackRandomThreat(rec, ship: ship, host: host)
        case .attackAndReinforce:
            attackRandomUnengaged(rec, ship: ship, host: host)
            host.tryAssistanceEncounter(ship, odds: 1)
        }
        return OriginalComms.Prompt.onMyWay
    }

    /// The window closed after a mission escort was let go: it hands over
    /// to its class AI and jumps out.
    public func releaseEscort(_ ship: Ship, world: World) {
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        setLeader(ship, nil)
        rec.behavior = host.hull(of: ship).inherentAI
        rec.resetTargets()
        rec.enterDeparture(clock60: clock60)
        mirror(rec, ship)
    }

    /// `Ship_EnterShipAiState0x04_TargetRandomUnengagedShip` (0x00410b00): a
    /// uniformly random enabled ship attacking the player (state 3/4).
    func attackRandomUnengaged(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let candidates = host.ships.filter { c in
            guard !c.isPlayer, c.entityID != ship.entityID, c.isAlive, !c.disabled,
                  let o = records[c.entityID] else { return false }
            return o.primary == World.playerEntityID
                && (o.state == OriginalAIState.retreat || o.state == OriginalAIState.attack)
        }
        guard !candidates.isEmpty else { rec.primary = nil; return }
        rec.primary = candidates[slotPick(count: candidates.count, host: host)].entityID
        rec.state = OriginalAIState.attack
    }

    /// `Ship_EnterShipAiState0x04_TargetRandomCombatCandidate` (0x004107e0):
    /// a uniformly random enabled threat to the player's squad.
    func attackRandomThreat(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let candidates = host.ships.filter { c in
            guard !c.isPlayer, c.entityID != ship.entityID, c.isAlive, !c.disabled,
                  let o = records[c.entityID] else { return false }
            return isThreatToPlayerSquad(o, ship: c, host: host)
        }
        guard !candidates.isEmpty else { rec.primary = nil; return }
        rec.secondary = .none
        rec.primary = candidates[slotPick(count: candidates.count, host: host)].entityID
        rec.state = OriginalAIState.attack
    }

    // MARK: Greeting text (0x004819d0)

    /// The Greetings text. Default STR# 2002 #175 "Greetings."; a düde's
    /// InfoTypes (+0x06) pick one set type uniformly: 0x1000 a trade tip,
    /// 0x2000 a disaster report, 0x4000 STR# (bits & 0xfff) + 7500, 0x8000 the
    /// government's quotes. A përs with Flags 0x8000 and no CommQuote reports
    /// a disaster. Short or `*` text falls back to STR# 3000 #46–50; a përs
    /// CommQuote overrides everything.
    func buildGreeting(_ ship: Ship, variant: Int, world: World,
                       context: OriginalComms.GreetingContext) -> String {
        guard let game = world.galaxy?.game else { return "" }
        func str(_ list: Int, _ index: Int) -> String { game.stringList(list)?.string(at: index) ?? "" }
        var text = str(2002, 175)
        var type = -1
        let info = ship.dudeID.flatMap { game.dude($0) }.map { Int($0.infoTypes) } ?? 0
        if info & 0xf000 != 0 {
            repeat {
                type = world.rng.range(4)
            } while !(type == 0 && info & 0x1000 != 0 || type == 1 && info & 0x2000 != 0
                      || type == 2 && info & 0x4000 != 0 || type == 3 && info & 0x8000 != 0)
        }
        if let pid = ship.personID, let pers = game.pers(pid), pers.showsDisasterInfo, pers.commQuote < 0 {
            type = 1
        }
        switch type {
        case 0:
            text = tradeTip(game: game, world: world) ?? str(2002, 175)
        case 1:
            if let d = disasterReport(game: game, world: world, disasters: context.disasters) { text = d }
        case 2:
            let listID = (info & 0xfff) + 7500
            let count = game.stringList(listID)?.strings.count ?? 0
            if count > 0 {
                let roll = Int(Int16(truncatingIfNeeded: world.commQuoteRoll))
                let pick = world.rng.range(roll % count + 1)
                let line = str(listID, pick + 1)
                text = line.isEmpty ? str(2002, 175) : line
            }
        case 3:
            let gIndex = ship.government - govtResourceBase
            let behavior = records[ship.entityID]?.behavior ?? 1
            let single = gIndex * 10 + (behavior < 3 ? 10010 : 10015) + variant
            if let s = game.singleString(single), !s.isEmpty {
                text = s
            } else {
                text = str(ship.government - govtResourceBase + 7000, variant + (behavior < 3 ? 1 : 6))
            }
        default:
            break
        }
        if text.hasPrefix("*") || text.dropFirst().hasPrefix("*") || text.count < 3 {
            text = str(3000, variant + OriginalComms.Prompt.greetingFallback)
        }
        if let quote = context.persCommQuote { text = quote }
        return text
    }

    /// A random stellar galaxy-wide with a low or high price for a random
    /// commodity: "<name> is a good place to buy|sell <commodity>."
    private func tradeTip(game: NovaGame, world: World) -> String? {
        let spobs = game.spobs()
        func eligible(_ s: SpobRes) -> Bool {
            s.flags & 0x3 != 0 && s.flags & 0x20 == 0
        }
        guard spobs.contains(where: { eligible($0) && $0.flags & 0x5555_5500 != 0 }) else { return nil }
        let byIndex = Dictionary(uniqueKeysWithValues: spobs.map { ($0.id - 128, $0) })
        var pick: (SpobRes, Int, PriceLevel)?
        for _ in 0..<100_000 {
            let commodity = world.rng.range(6)
            let slot = world.rng.range(0x800)
            guard let s = byIndex[slot], eligible(s), let c = Commodity(rawValue: commodity) else { continue }
            let level = s.priceLevel(c)
            if level == .low || level == .high { pick = (s, commodity, level); break }
        }
        guard let (spob, commodity, level) = pick, let c = Commodity(rawValue: commodity) else { return nil }
        let list = game.stringList(2002)
        let verb = list?.string(at: level == .low ? 177 : 178) ?? ""
        return "\(spob.name) \(list?.string(at: 176) ?? "") \(verb) \(game.commodityName(c))."
    }

    /// "The last time I was on|at <stellar>, the price of <commodity> was
    /// very|really|pretty low|high."
    private func disasterReport(game: NovaGame, world: World,
                                disasters: [OriginalComms.Disaster]) -> String? {
        let list = game.stringList(2002)
        func s(_ i: Int) -> String { list?.string(at: i) ?? "" }
        guard !disasters.isEmpty else { return nil }
        let d = disasters.count == 1 ? disasters[0] : disasters[world.rng.range(disasters.count)]
        guard let spob = game.spob(d.stellarID), let c = Commodity(rawValue: d.commodity) else { return s(175) }
        let where_ = spob.isStation ? s(180) : s(60)
        let degree = s(182 + world.rng.range(3))
        let direction = d.priceDelta < 0 ? s(185) : s(186)
        return "\(s(179)) \(where_) \(spob.name), \(s(181)) \(game.commodityName(c)) \(degree) \(direction)."
    }
}

extension OriginalAI {

    /// Enter the comm-window help states with the player as the target:
    /// `Ship_EnterShipAiState0x09` (0x00410c30) or `0x0F` (0x00410c70).
    func beginAssistance(_ rec: OriginalAIShipState, repair: Bool) {
        rec.hostility = 0
        rec.jumpTimer = 0
        rec.primary = World.playerEntityID
        rec.state = repair ? OriginalAIState.repair : OriginalAIState.refuel
        rec.mode = OriginalAIMode.idle
        rec.maneuverTimer = -1
    }

    /// Start a paid assistance run from `ship` to the player.
    public func beginAssistance(by ship: Ship, world: World) {
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        beginAssistance(rec, repair: world.player.disabled)
        mirror(rec, ship)
    }

    /// Request Assistance's decision for `ship`, summarised.
    public func assistanceReply(from ship: Ship, world: World) -> OriginalComms.AssistanceReply {
        let session = openComm(with: ship, world: world, playerCredits: 0)
        switch pressAssistance(session, ship: ship, world: world) {
        case let .offer(_, _, _, effect), let .done(_, effect):
            return effect == .assist ? .helps(repair: world.player.disabled, againstThreat: false)
                                     : .helps(repair: false, againstThreat: true)
        case let .reply(prompt):
            switch prompt {
            case OriginalComms.Prompt.busy, OriginalComms.Prompt.cantHelpSir: return .busy
            case OriginalComms.Prompt.notInTrouble: return .notInTrouble
            case OriginalComms.Prompt.ratherNot: return .ratherNot
            default: return .refused
            }
        default:
            return .refused
        }
    }
}

extension OriginalAI {

    /// A ship whose target was just taken from it: primary and secondary
    /// cleared, state and mode 0 (0x00412550's stand-down loop).
    func standDown(_ ship: Ship) {
        guard let rec = records[ship.entityID] else { return }
        rec.primary = nil
        rec.secondary = .none
        rec.state = OriginalAIState.idle
        rec.mode = OriginalAIMode.idle
        mirror(rec, ship)
    }

    /// `Ship_ClearOtherShipsTargetingShip` 0x00415dc0: every other ship whose
    /// primary or secondary target is `boarded` stands down — state and mode
    /// 0, both targets cleared, hostility 0. The player's own target stays.
    func clearShipsTargeting(_ boarded: Ship, in world: World) {
        for npc in world.npcs where npc !== boarded && npc.isAlive {
            guard let rec = records[npc.entityID],
                  rec.primary == boarded.entityID || rec.secondary == .ship(boarded.entityID) else { continue }
            standDown(npc)
            rec.hostility = 0
        }
    }

    /// The boarded mission ship coasts for `ticks` before it acts again.
    func setManeuverTimer(_ ship: Ship, _ ticks: Double) {
        records[ship.entityID]?.maneuverTimer = ticks
    }

    /// A captured ship joins its captor's wing: behavior 6, state and mode 0,
    /// coasting `coastTicks` before it acts.
    func joinWing(_ ship: Ship, coastTicks: Double) {
        guard let rec = records[ship.entityID] else { return }
        rec.behavior = 6
        rec.primary = nil
        rec.secondary = .none
        rec.state = OriginalAIState.idle
        rec.mode = OriginalAIMode.idle
        rec.maneuverTimer = coastTicks
        mirror(rec, ship)
    }
}
