import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The new-pilot travel hint chain (UI-11): STR# 2002 #22–#31 shown on the
/// status bar to a fresh pilot, driven by the original's `DAT_007cab1c`
/// ("travel hint state"), read from `PlayerTick_FlightTutorialHints`
/// (the fragment at 0x00451f8f in `Ship_HandlePlayerShipCore` 0x0044aa70) and
/// the launch tail of `Stellar_RunDockAndLaunchSequence` (0x00456134).
///
/// State machine (all values are the original's):
/// - `-3` a brand-new pilot (`new_pilot_flow` end). Near a landing stellar the
///   welcome hint shows (#22 docking / #23 landing + stellar + #24 + the Land
///   key + #25), state → `-2`.
/// - `-1` set at every launch while the state is below 3. The hyperspace hint
///   shows (#26 + the map key + #27 + the jump key + #28), state → `0`.
/// - `0` / `-2` the range hints: inside the not-yet-far-enough radius
///   (`dist² <= 2,000,000`) with state ≤ 0 nothing; beyond it, #30 shows and
///   state → `1`; with state `1` and `dist² > 10,000,000`, #31 shows and
///   state → `2` (the chain is over; both range hints are suppressed while the
///   ship is disabled).
/// - `0x7fff` (a loaded pilot, and set by a jump spin-up, a hyperspace arrival
///   and ship resets): no hints. Every hint also sounds snd 154, priority 1,
///   and runs 0x200 raw calls.
///
/// The launch line (`launch`, #55–60) is shown only when the state is `>= 3`;
/// below that it is silent and the state is reset to `-1`, which is the
/// original's quirk: until the first jump the hyperspace hint reappears at
/// every launch.
public final class TravelHintTracker {
    /// The latched "no hints" value.
    public static let latched = 0x7fff
    /// `kNotYetFarEnoughSq` / `kSafeRangeSq` (0x00575650 / 0x00575658): squared
    /// distance from the system centre.
    public static let nearRadiusSq = 2_000_000.0
    public static let farRadiusSq = 10_000_000.0
    /// The hint overlay's length in raw calls and the beep it sounds.
    public static let hintRawCalls = 0x200
    public static let hintBeep = 5
    /// Evaluated once every 60 raw calls (`frame % 60 == 0`).
    public static let framePeriod = 60

    public private(set) var state: Int
    private var frames = 0.0
    private var evaluations = 0

    public init(state: Int = TravelHintTracker.latched) { self.state = state }

    /// What the host shows.
    public struct Hint: Equatable, Sendable {
        public var text: String
        public var rawCalls: Int
        public var beep: Int
    }

    /// Key display names for the hint text (empty = unbound, as the original's
    /// map miss expands to the empty string).
    public struct Keys: Equatable, Sendable {
        public var land: String
        public var map: String
        public var jump: String
        public init(land: String, map: String, jump: String) {
            self.land = land; self.map = map; self.jump = jump
        }
    }

    /// The nearest stellar the Land key could reach (`Stellar_FindNearestAvailableTravelStellar`).
    public struct Stellar: Equatable, Sendable {
        public var name: String
        /// spöb Flags 0x0010 — a station ("docking" lead) rather than a planet.
        public var isStation: Bool
        public init(name: String, isStation: Bool) { self.name = name; self.isStation = isStation }
    }

    // MARK: Transitions

    /// A freshly created pilot (`new_pilot_flow.cpp:1168`).
    public func beginNewPilot() { state = -3; frames = 0; evaluations = 0 }

    /// A loaded pilot, a jump spin-up, a hyperspace arrival or a ship reset
    /// (`pilot_file.cpp:1602`, 0x0044c561, 0x0044f83f).
    public func latch() { state = Self.latched }

    /// Whether the chain is still running (state below 2).
    public var isActive: Bool { state < 2 }

    /// The launch tail (0x00456134): returns whether the launch line may show.
    /// Below state 3 the line is skipped and the state is reset to -1.
    public func launched() -> Bool {
        if state < 3 { state = -1; return false }
        return true
    }

    // MARK: The per-second check

    /// Advance `rawCalls` raw sim calls and run the check when the counter
    /// crosses a multiple of 60. `distanceSquared` is the player's squared
    /// distance from the system centre; `disabled` the player's ship state.
    public func tick(rawCalls: Double, distanceSquared: Double, disabled: Bool, nearest: Stellar?,
                     keys: Keys, text: OriginalText) -> Hint? {
        guard state < 2, rawCalls > 0 else { return nil }
        frames += rawCalls
        let boundaries = Int(frames / Double(Self.framePeriod))
        guard boundaries > evaluations else { return nil }
        evaluations = boundaries
        return evaluate(distanceSquared: distanceSquared, disabled: disabled, nearest: nearest, keys: keys, text: text)
    }

    /// One evaluation (`frame % 60 == 0` while the state is below 2). Exposed
    /// for tests.
    public func evaluate(distanceSquared: Double, disabled: Bool, nearest: Stellar?, keys: Keys,
                         text: OriginalText) -> Hint? {
        guard state < 2 else { return nil }
        var shown: Hint?
        func hint(_ s: String) -> Hint { Hint(text: s, rawCalls: Self.hintRawCalls, beep: Self.hintBeep) }

        if state == -3 {
            let docking = text.misc(22), landing = text.misc(23)
            if !docking.isEmpty, !landing.isEmpty, let nearest {
                shown = hint("\(nearest.isStation ? docking : landing) \(nearest.name) \(text.misc(24))\(keys.land)\(text.misc(25))")
            }
            state = -2
        }
        if state == -1 {
            let intro = text.misc(26)
            if !intro.isEmpty, nearest != nil {
                shown = hint("\(intro)\(keys.map)\(text.misc(27))\(keys.jump)\(text.misc(28))")
            }
            state = 0
        }
        if distanceSquared <= Self.nearRadiusSq || state > 0 {
            if distanceSquared > Self.farRadiusSq, state == 1, !disabled {
                let line = text.misc(31)
                if !line.isEmpty { shown = hint(line); state = 2 }
            }
        } else if !disabled {
            let line = text.misc(30)
            if !line.isEmpty { shown = hint(line); state = 1 }
        }
        return shown
    }
}
