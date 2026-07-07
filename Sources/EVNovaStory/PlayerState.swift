import Foundation

/// Runtime progress of one accepted mission. The static definition lives in the
/// `MissionRes` (looked up by `missionID`); this holds only what changes as the
/// player plays: which sub-objectives are done and when it must be finished by.
public struct ActiveMission: Codable, Hashable, Sendable {
    public let missionID: Int
    public var acceptedDate: GameDate
    public var deadline: GameDate?      // nil = no time limit

    /// Cargo has been loaded aboard (relevant when pickup isn't "at start").
    public var cargoPickedUp: Bool
    /// Special-ship objectives still outstanding (destroy/disable/board count).
    /// 0 means the ship objective is satisfied (or there was none).
    public var shipObjectivesRemaining: Int
    /// The player has visited the travel stellar at least once.
    public var visitedTravelStellar: Bool

    public init(missionID: Int, acceptedDate: GameDate, deadline: GameDate?,
                cargoPickedUp: Bool, shipObjectivesRemaining: Int,
                visitedTravelStellar: Bool = false) {
        self.missionID = missionID
        self.acceptedDate = acceptedDate
        self.deadline = deadline
        self.cargoPickedUp = cargoPickedUp
        self.shipObjectivesRemaining = shipObjectivesRemaining
        self.visitedTravelStellar = visitedTravelStellar
    }
}

/// Persisted runtime state of one `crön` background event.
public struct CronRuntime: Codable, Hashable, Sendable {
    public let cronID: Int
    /// Date the event became active (its OnStart has run); nil if not running.
    public var startedDate: GameDate?
    /// Date the event is scheduled to end (start + duration).
    public var endDate: GameDate?
    /// Earliest date the event may (re)start, enforcing pre/post hold-off.
    public var earliestStart: GameDate?

    public init(cronID: Int, startedDate: GameDate? = nil, endDate: GameDate? = nil,
                earliestStart: GameDate? = nil) {
        self.cronID = cronID
        self.startedDate = startedDate
        self.endDate = endDate
        self.earliestStart = earliestStart
    }

    public var isActive: Bool { startedDate != nil }
}

/// The complete, serialisable player / campaign state — the "pilot file". Owns
/// the control-bit vector, mission log, ranks, standings and galaxy clock. This
/// is the single source of truth the story engine reads and mutates; combat,
/// trading and the UI layer share it too.
public struct PlayerState: Codable, Sendable {
    // Identity
    public var pilotName: String
    public var isMale: Bool
    public var unregisteredDays: Int

    // Assets
    public var credits: Int
    public var shipType: Int              // shïp id
    public var shipName: String
    public var outfits: [Int: Int]        // outfit id → quantity owned
    public var cargo: [Int: Int]          // cargo/commodity type → tons held

    // Position & exploration
    public var currentSystem: Int
    public var exploredSystems: Set<Int>

    // Reputation
    public var combatRating: Int
    public var legalRecord: [Int: Int]    // govt id → standing (+ good, − wanted)
    public var activeRanks: Set<Int>      // ränk ids currently held

    // Story
    public var setBits: Set<Int>          // the NCB control-bit vector
    public var date: GameDate
    public var activeMissions: [ActiveMission]
    public var completedMissions: Set<Int>
    public var failedMissions: Set<Int>
    public var cronRuntime: [Int: CronRuntime]  // cron id → its runtime state

    public init(pilotName: String = "Captain",
                isMale: Bool = true,
                shipType: Int = 128,
                shipName: String = "",
                credits: Int = 0,
                currentSystem: Int = 128,
                date: GameDate = .defaultStart) {
        self.pilotName = pilotName
        self.isMale = isMale
        self.unregisteredDays = 0
        self.credits = credits
        self.shipType = shipType
        self.shipName = shipName
        self.outfits = [:]
        self.cargo = [:]
        self.currentSystem = currentSystem
        self.exploredSystems = [currentSystem]
        self.combatRating = 0
        self.legalRecord = [:]
        self.activeRanks = []
        self.setBits = []
        self.date = date
        self.activeMissions = []
        self.completedMissions = []
        self.failedMissions = []
        self.cronRuntime = [:]
    }

    // MARK: Convenience queries

    public func activeMission(_ id: Int) -> ActiveMission? {
        activeMissions.first { $0.missionID == id }
    }
    public func isMissionActive(_ id: Int) -> Bool { activeMission(id) != nil }

    /// Total cargo tons currently held (for free-hold checks on cargo missions).
    public var usedCargoSpace: Int { cargo.values.reduce(0, +) }

    // MARK: Mutation helpers used by the SET-op executor

    public mutating func setBit(_ n: Int)    { setBits.insert(n) }
    public mutating func clearBit(_ n: Int)  { setBits.remove(n) }
    public mutating func toggleBit(_ n: Int) {
        if setBits.contains(n) { setBits.remove(n) } else { setBits.insert(n) }
    }

    public mutating func grantOutfit(_ id: Int, count: Int = 1) {
        outfits[id, default: 0] += count
    }
    public mutating func removeOutfit(_ id: Int, count: Int = 1) {
        let remaining = (outfits[id] ?? 0) - count
        if remaining > 0 { outfits[id] = remaining } else { outfits[id] = nil }
    }
}

// MARK: NCBTestContext conformance — lets any NCB test evaluate against a pilot.

extension PlayerState: NCBTestContext {
    public func isBitSet(_ n: Int) -> Bool { setBits.contains(n) }
    public func hasOutfit(_ id: Int) -> Bool { (outfits[id] ?? 0) > 0 }
    public func isSystemExplored(_ id: Int) -> Bool { exploredSystems.contains(id) }
    public var playerIsMale: Bool { isMale }
}
