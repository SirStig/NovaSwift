import Foundation

/// Why the app wants to write the durable pilot file, and whether it should.
///
/// The original (`PilotFile_SaveGame` 0x004c7db0) saves at exactly three
/// moments: a new pilot, the spaceport launch tail (which also runs on a quit
/// while landed), and — under Strict Play only — an escape-pod respawn. There is
/// no jump save and no periodic save, so dying or quitting in flight rolls the
/// pilot back to its last launch, docked at that stellar (UI-01). Every other
/// reason is NovaSwift's own and writes only under the `frequentAutosave`
/// enhancement.
public enum PilotSaveReason: Sendable, Equatable {
    /// A pilot was just created.
    case newPilot
    /// Leaving a spaceport.
    case launch
    /// The escape pod brought the pilot back.
    case podRespawn
    /// The in-game menu's Save / quit-to-menu.
    case manual
    /// Touching down at a spaceport.
    case land
    /// A hyperjump or gate transit.
    case jump
    /// A story, combat or mission event in flight.
    case event
    /// The periodic in-flight heartbeat.
    case periodic
    /// The app is going to the background or quitting.
    case background
    /// The app is going to the background or quitting while landed. The
    /// original saves on a quit while landed (the launch tail runs), and an iOS
    /// suspend can end in a kill, so this saves regardless of the enhancement.
    case backgroundLanded

    public func shouldSave(frequentAutosave: Bool, strictPlay: Bool) -> Bool {
        switch self {
        case .newPilot, .launch, .backgroundLanded: return true
        case .podRespawn:        return strictPlay || frequentAutosave
        default:                 return frequentAutosave
        }
    }

    /// Whether the save first rotates a backup of the previous file.
    public var wantsBackup: Bool {
        switch self {
        case .launch, .land, .manual, .periodic: return true
        default: return false
        }
    }
}

extension PlayerState {
    /// Strict Play, dying without a pod: the original deletes the pilot file
    /// (`Ship_RunSpaceflightMode` 0x00489210 → `PilotFile_Delete` 0x004cd040),
    /// unless the ship is the escape pod itself (class index 0x2ff, shïp 895).
    public var strictPlayDeathDeletesPilot: Bool {
        isStrictPlay && shipType != Self.escapePodShipID
    }

    /// shïp 895, the escape pod's hull (class index 0x2ff).
    public static let escapePodShipID = 895

    /// Prepare a pilot read from disk for play, as `PilotFile_LoadSave`
    /// (0x004cb260) does: shield and armor are recomputed from the hull, so a
    /// ship always loads at full (UI-03) — only fuel is restored. Outfits and
    /// junk cargo whose definitions are gone (a removed plug-in) are dropped,
    /// and a hull that no longer exists becomes `fallbackShipID`. Returns true
    /// when anything that came from missing data was repaired.
    @discardableResult
    public mutating func normalizeForLoad(outfitExists: (Int) -> Bool,
                                          junkExists: (Int) -> Bool = { _ in true },
                                          shipExists: (Int) -> Bool,
                                          fallbackShipID: Int?) -> Bool {
        shield = nil
        armor = nil
        var repaired = false
        for id in outfits.keys where !outfitExists(id) {
            outfits[id] = nil
            repaired = true
        }
        for id in cargo.keys where id >= 128 && !junkExists(id) {
            cargo[id] = nil
            repaired = true
        }
        if !shipExists(shipType), let fallbackShipID {
            shipType = fallbackShipID
            repaired = true
        }
        return repaired
    }
}
