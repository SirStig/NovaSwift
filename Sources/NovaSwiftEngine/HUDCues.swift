import Foundation

/// The threat "Red Alert" cue (snd 370) and its low-volume blink.
///
/// `Ship_HandlePlayerShipCore` 0x0044aa70 (the same block in 0x0044d371):
/// every 60th spaceflight-loop frame (the raw ~47.6 Hz call, FL-01) it reads
/// `Ship_IsAnyShipThreatToPlayerSquad` 0x00410060; on the rising edge (no
/// threat at the last check, one now), unless the escape pod is running,
/// it plays snd 370 at priority 5 and — when the sound-volume pref is below
/// 2 — sets a 30-step blink counter that `FUN_0042cc30` shows as cicn
/// 18000/18001 (toggling by parity, one step every 5th frame).
public struct RedAlertCue: Sendable {
    /// The spaceflight frame counter `DAT_00597992`.
    public private(set) var frame = 0
    private var threatAtLastCheck = false
    /// The blink counter `DAT_00734c18`; the indicator shows while > 0.
    public private(set) var blink = 0

    public init() {}

    /// Advance `rawCalls` spaceflight frames. Returns true when snd 370
    /// should play.
    public mutating func advance(rawCalls: Int, lowVolume: Bool, inEscapePod: Bool,
                                 threat: () -> Bool) -> Bool {
        var play = false
        for _ in 0..<max(0, rawCalls) {
            if frame % 60 == 0 {
                let previous = threatAtLastCheck
                threatAtLastCheck = threat()
                if threatAtLastCheck, !previous, !inEscapePod {
                    play = true
                    if lowVolume { blink = 30 }
                }
            }
            if blink > 0, frame % 5 == 0 { blink -= 1 }
            frame = frame >= 0x7FFF ? 0 : frame + 1
        }
        return play
    }

    /// Which blink frame shows (cicn 18000 + this), or nil when hidden.
    public var blinkFrame: Int? { blink > 0 ? blink & 1 : nil }
}

extension World {
    /// Whether the player's death timer is running — the window in which the
    /// original keeps snd 371 "Klaxxon" playing (0x0044b120 and the other
    /// player handlers re-start it whenever it isn't already sounding).
    /// Whether the last escort order changed anything (the panel re-shows).
    public var lastEscortOrderChanged: Bool {
        get { originalAI.lastEscortOrderChanged }
        set { originalAI.lastEscortOrderChanged = newValue }
    }

    public var isPlayerDeathTimerRunning: Bool {
        playerDeathReportedForEject && !playerDeathSequenceOver && !playerDeathEjected
    }
}

/// The in-flight Escort Commands panel (`Ui_DrawTargetCategoryPanel`
/// 0x0049e430, `Ui_ShowTargetCategoryPanel` 0x0049e8d0, driven from the
/// player handlers, e.g. 0x0044b120): E shows it, keys 1–5 then pick a
/// group (All, or EscortType 0 fighters / 1 medium / 2 warships /
/// 3 freighters), and F / D / V / C (Alt-C) order only that group. The
/// panel holds for 0x1e0 `TickCount` ticks (60 Hz) after the last input,
/// then fades one level a frame from 0x20 to 0. While it is up, a command
/// bound to keys 1–5 reads as up (`nv_KeyCheck` 0x00469ca0).
public struct EscortCommandPanel: Sendable, Equatable {
    /// Display level 0…0x20 (`DAT_007354b4`); the panel shows while > 0.
    public private(set) var level = 0
    /// Last input, in 60 Hz ticks (`DAT_00597978`).
    public private(set) var stamp: Double = 0
    /// Selected group (`DAT_007cab54`): −1 All, else an EscortType.
    public private(set) var group = -1
    /// The order shown for each EscortType (`DAT_007354c4`).
    public private(set) var orders = [0, 0, 0, 0]
    private var liveCount = -1
    /// The 0x1e0-tick hold before the fade.
    public static let holdTicks: Double = 0x1e0

    public init() {}

    public var isOpen: Bool { level > 0 }

    public enum EResult: Equatable, Sendable { case opened, noEscorts, closed }

    /// E: open (with at least one escort), or say there are none, or close.
    public mutating func pressE(hasEscorts: Bool, now: Double) -> EResult {
        if isOpen { level = 0; return .closed }
        guard hasEscorts else { return .noEscorts }
        group = -1
        show(now)
        return .opened
    }

    /// Key `k` (0 = key 1 … 4 = key 5) while the panel is up: key 1 selects
    /// All, key k+2 EscortType k when some escort is of that type. Returns
    /// whether a group was picked; the stamp refreshes either way.
    @discardableResult
    public mutating func pressGroupKey(_ k: Int, hasCategory: (Int) -> Bool, now: Double) -> Bool {
        guard isOpen, (0...4).contains(k) else { return false }
        let picked = k == 0 || hasCategory(k - 1)
        if picked {
            group = k - 1
            show(now)
        }
        stamp = now
        return picked
    }

    /// An order key (F 2 attack, D 1 defend, V 4 hold, C 0 formation, Alt-C
    /// 3 return to hangar). Returns the EscortType to command, nil for every
    /// escort. With the panel closed or All selected, every group's cell takes
    /// the order.
    public mutating func order(_ code: Int) -> Int? {
        if group == -1 || !isOpen {
            orders = [code, code, code, code]
            return nil
        }
        orders[group] = code
        return group
    }

    /// The order changed something while the panel is up: re-show it.
    public mutating func orderTaken(now: Double) { if isOpen { show(now) } }

    /// One spaceflight frame: track the live escort count (0 resets the
    /// stamp and the group), drop a Return-to-Hangar cell with no carried
    /// fighter out, and fade once the hold has run out.
    public mutating func tick(frames: Int, now: Double, liveEscorts: Int, fighterOut: (Int) -> Bool) {
        for i in 0..<4 where orders[i] == 3 && !fighterOut(i) { orders[i] = 0 }
        guard isOpen else { liveCount = -1; return }
        if liveEscorts != liveCount {
            if liveEscorts == 0 { stamp = 0; group = -1 }
            liveCount = liveEscorts
        }
        if now > stamp + Self.holdTicks { level = max(0, level - frames) }
    }

    private mutating func show(_ now: Double) {
        level = 0x20
        stamp = now
    }
}

extension World {
    /// The player's escorts as the Escort Commands panel reads them: every
    /// active ship the player leads, grouped by its EscortType.
    public struct EscortRoster: Sendable, Equatable {
        /// Escorts of each EscortType (0…3), any state.
        public var perCategory = [0, 0, 0, 0]
        /// Escorts neither disabled nor destroyed (the panel's redraw count).
        public var live = 0
        /// EscortTypes with a carried fighter out (a Return-to-Hangar cell
        /// stays only while one is).
        public var fighterOut = [false, false, false, false]
        public var any: Bool { perCategory.contains { $0 > 0 } }
    }

    public func playerEscortRoster() -> EscortRoster {
        var r = EscortRoster()
        for ship in npcs where ship.isAlive && ship.brain?.leaderID == Self.playerEntityID {
            let c = originalAI.hull(of: ship, world: self).escortClass
            guard (0..<4).contains(c) else { continue }
            r.perCategory[c] += 1
            if !ship.disabled { r.live += 1 }
            if ship.carrierID != nil { r.fighterOut[c] = true }
        }
        return r
    }
}
