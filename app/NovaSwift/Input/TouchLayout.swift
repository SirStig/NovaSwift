import SwiftUI
import NovaSwiftEngine

/// Which screen corner a touch control is measured from. Edge-anchored (rather
/// than absolute x/y) so a layout survives rotation and a different device:
/// a thrust button 12 units in from the bottom-right stays there on any screen.
enum TouchCorner: String, Codable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var unitPoint: UnitPoint {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The same corner on the other side of the screen.
    var mirrored: TouchCorner {
        switch self {
        case .topLeading: return .topTrailing
        case .topTrailing: return .topLeading
        case .bottomLeading: return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        }
    }
}

/// What a hold control does while pressed — the `input.touch` field it drives.
enum TouchHoldEffect: String, Codable, CaseIterable, Identifiable {
    case turnLeft, turnRight, thrust, reverse, afterburner, firePrimary, fireSecondary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turnLeft: return "Turn Left"
        case .turnRight: return "Turn Right"
        case .thrust: return "Thrust"
        case .reverse: return "Reverse"
        case .afterburner: return "Afterburner"
        case .firePrimary: return "Fire Primary"
        case .fireSecondary: return "Fire Secondary"
        }
    }

    var caption: String {
        switch self {
        case .afterburner: return "Afterburn"
        case .firePrimary: return "Fire"
        case .fireSecondary: return "Fire 2nd"
        default: return title
        }
    }

    var icon: String {
        switch self {
        case .turnLeft: return "arrowtriangle.left.fill"
        case .turnRight: return "arrowtriangle.right.fill"
        case .thrust: return "chevron.up.2"
        case .reverse: return "chevron.down.2"
        case .afterburner: return "flame.fill"
        case .firePrimary: return "bolt.fill"
        case .fireSecondary: return "burst.fill"
        }
    }

    var accent: Bool {
        switch self {
        case .afterburner, .firePrimary, .fireSecondary: return true
        default: return false
        }
    }

    /// Press or release: write the matching field of the touch intent.
    func apply(to intent: inout ControlIntent, down: Bool) {
        switch self {
        case .turnLeft: intent.turnLeft = down
        case .turnRight: intent.turnRight = down
        case .thrust: intent.thrust = down
        case .reverse: intent.reverse = down
        case .afterburner: intent.afterburner = down
        case .firePrimary: intent.firePrimary = down
        case .fireSecondary: intent.fireSecondary = down
        }
    }
}

extension GameAction {
    /// Glyph for a tap control bound to this action (stock buttons keep theirs).
    var touchIcon: String {
        switch self {
        case .targetNearest: return "scope"
        case .targetNext, .targetPrevious, .targetEscortNext: return "arrow.triangle.2.circlepath"
        case .nearestHostile: return "exclamationmark.triangle.fill"
        case .clearTarget, .clearShipTarget: return "xmark.circle"
        case .hailTarget, .hailStellar: return "antenna.radiowaves.left.and.right"
        case .openEscorts: return "person.3.fill"
        case .board: return "shippingbox.fill"
        case .toggleCloak: return "eye.slash"
        case .recallFighters, .commandEscortReturnHangar: return "airplane.arrival"
        case .eject: return "lifepreserver"
        case .galaxyMap: return "map.fill"
        case .hyperjump, .hyperspaceArm, .cycleHyperspaceLink: return "bolt.horizontal.circle.fill"
        case .land: return "arrow.down.to.line"
        case .selectSecondaryPrev, .selectSecondaryNext, .clearSecondary: return "arrow.triangle.2.circlepath"
        case .missionInfo: return "list.bullet.clipboard"
        case .playerInfo, .shipInfo: return "person.crop.circle"
        case .autopilot: return "location.fill"
        case .pauseGame: return "pause.fill"
        case .openMenu: return "line.3.horizontal"
        case .cycleCameraView: return "camera.fill"
        case .cameraZoomIn: return "plus.magnifyingglass"
        case .cameraZoomOut: return "minus.magnifyingglass"
        default: return "circle.grid.2x2.fill"
        }
    }

    /// Actions a touch tap button may be bound to: the discrete ones.
    static var touchTapActions: [GameAction] { allCases.filter { !$0.continuous } }
}

/// One on-screen flight control.
struct TouchControl: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Press-and-hold, drives an `input.touch` field (`effect`).
        case hold
        /// Momentary, fires `onDiscrete(action)`.
        case tap
        /// The secondary-weapon chip (cycle forward / back).
        case weaponChip
        /// The Actions open/close toggle — always present (it owns the grid).
        case actionsToggle
    }

    /// Base cap diameter class (points at metric scale 1).
    enum Cap: String, Codable {
        case big, small, toggle
        var base: CGFloat {
            switch self {
            case .big: return 52
            case .small: return 36
            case .toggle: return 40
            }
        }
        var glyphScale: CGFloat { self == .toggle ? 0.42 : 0.4 }
    }

    var id: String
    var kind: Kind
    var effect: TouchHoldEffect?
    var action: GameAction?
    var icon: String
    var caption: String
    var accent: Bool
    var cap: Cap
    var anchor: TouchCorner
    /// Distance from the anchor corner to the nearest edge of the control's
    /// hit box, in units of the scaled metric (see `TouchLayout.unit`).
    var x: Double
    var y: Double
    /// Per-control size multiplier, `TouchControl.sizeRange`.
    var size: Double = 1
    var hidden = false
    var isCustom = false

    static let sizeRange: ClosedRange<Double> = 0.6...1.6

    /// Hit box padding around a cap, as a fraction of the cap (see `HoldButton`).
    static let hitPad: CGFloat = 0.12

    /// Cap diameter for a given unit.
    func capSize(unit u: CGFloat) -> CGFloat { cap.base * CGFloat(size) * u }

    /// The hit box (cap + padding) in points; the chip uses a typical width.
    func boxSize(unit u: CGFloat) -> CGSize {
        switch kind {
        case .weaponChip:
            return CGSize(width: 140 * CGFloat(size) * u, height: 26 * CGFloat(size) * u)
        default:
            let d = capSize(unit: u) * (1 + 2 * Self.hitPad)
            return CGSize(width: d, height: d)
        }
    }

    /// The hit box within a safe area of `area` points (right inset already removed).
    func frame(in area: CGSize, unit u: CGFloat) -> CGRect {
        let b = boxSize(unit: u)
        let px = CGFloat(x) * u, py = CGFloat(y) * u
        let ox = anchor.isTrailing ? area.width - px - b.width : px
        let oy = anchor.isBottom ? area.height - py - b.height : py
        return CGRect(x: ox, y: oy, width: b.width, height: b.height)
    }

    /// Store a hit box position back as anchor-relative units; `reanchor` picks
    /// the nearest corner so the control keeps hugging the closest edges.
    mutating func place(_ rect: CGRect, in area: CGSize, unit u: CGFloat, reanchor: Bool) {
        var corner = anchor
        if reanchor {
            let trailing = rect.midX > area.width / 2
            let bottom = rect.midY > area.height / 2
            switch (bottom, trailing) {
            case (false, false): corner = .topLeading
            case (false, true): corner = .topTrailing
            case (true, false): corner = .bottomLeading
            case (true, true): corner = .bottomTrailing
            }
        }
        let px = corner.isTrailing ? area.width - rect.maxX : rect.minX
        let py = corner.isBottom ? area.height - rect.maxY : rect.minY
        anchor = corner
        x = Double(px / u)
        y = Double(py / u)
    }

    /// Re-skin a stock/custom tap for a newly chosen action.
    mutating func setAction(_ a: GameAction) {
        action = a
        icon = a.touchIcon
        caption = a.title
    }

    /// Re-skin a hold for a newly chosen effect.
    mutating func setEffect(_ e: TouchHoldEffect) {
        effect = e
        icon = e.icon
        caption = e.caption
        accent = e.accent
    }
}

/// The user-editable touch cockpit: global scale/opacity plus every control.
/// `TouchControlsOverlay` renders from this; `.default` reproduces the original
/// fixed arrangement so nobody's screen changes until they edit it.
struct TouchLayout: Codable, Equatable {
    var scale: Double = 1
    var opacity: Double = 1
    var controls: [TouchControl]

    static let scaleRange: ClosedRange<Double> = 0.7...1.4
    static let opacityRange: ClosedRange<Double> = 0.3...1.0

    static let storageKey = "com.novaswift.touchlayout.v1"

    static func load() -> TouchLayout {
        UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(TouchLayout.self, from: $0) }
            ?? .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// The metric the offsets are measured in: the overlay's screen-derived
    /// scale (`TouchMetrics.s`) times the player's global scale.
    func unit(metric s: CGFloat) -> CGFloat { s * CGFloat(scale) }

    var actionsToggle: TouchControl? { controls.first { $0.kind == .actionsToggle } }

    func index(of id: String) -> Int? { controls.firstIndex { $0.id == id } }

    /// A fresh custom tap button for any discrete action.
    static func customTap(_ action: GameAction) -> TouchControl {
        TouchControl(id: "custom-" + UUID().uuidString, kind: .tap, effect: nil, action: action,
                     icon: action.touchIcon, caption: action.title, accent: true, cap: .small,
                     anchor: .topTrailing, x: 12, y: 80, isCustom: true)
    }

    // MARK: Presets

    enum Preset: String, CaseIterable, Identifiable {
        case standard = "Default", leftHanded = "Left-handed", minimal = "Minimal"
        var id: String { rawValue }
        var controls: [TouchControl] {
            switch self {
            case .standard: return TouchLayout.stockControls
            case .leftHanded: return TouchLayout.mirroredBottom(TouchLayout.stockControls)
            case .minimal: return TouchLayout.minimalControls
            }
        }
    }

    static let `default` = TouchLayout(controls: stockControls)
    static let leftHanded = TouchLayout(controls: Preset.leftHanded.controls)
    static let minimal = TouchLayout(controls: Preset.minimal.controls)

    func matches(_ preset: Preset) -> Bool { controls == preset.controls }

    /// Swap in a preset's controls, keeping the player's scale and opacity.
    mutating func apply(_ preset: Preset) { controls = preset.controls }

    /// Today's arrangement, in units of the metric `s` (hit box = 1.24 × cap).
    /// Edge = 12, bottom margin = 16, gap = 8; boxes: big 64.48, small 44.64,
    /// toggle 49.6. Bottom-right: Fire/Thrust row, then the 4 small holds
    /// (gap 5.6) above it, then the weapon chip; top-right: Map, Jump, Actions.
    static let stockControls: [TouchControl] = {
        func hold(_ id: String, _ e: TouchHoldEffect, _ cap: TouchControl.Cap, _ a: TouchCorner,
                  _ x: Double, _ y: Double) -> TouchControl {
            TouchControl(id: id, kind: .hold, effect: e, action: nil, icon: e.icon, caption: e.caption,
                         accent: e.accent, cap: cap, anchor: a, x: x, y: y)
        }
        func tap(_ id: String, _ act: GameAction, _ icon: String, _ caption: String, accent: Bool,
                 _ cap: TouchControl.Cap, _ a: TouchCorner, _ x: Double, _ y: Double) -> TouchControl {
            TouchControl(id: id, kind: .tap, effect: nil, action: act, icon: icon, caption: caption,
                         accent: accent, cap: cap, anchor: a, x: x, y: y)
        }
        return [
            hold("turnLeft", .turnLeft, .big, .bottomLeading, 12, 16),
            hold("turnRight", .turnRight, .big, .bottomLeading, 84.48, 16),
            hold("thrust", .thrust, .big, .bottomTrailing, 12, 16),
            hold("fire", .firePrimary, .big, .bottomTrailing, 84.48, 16),
            hold("fire2", .fireSecondary, .small, .bottomTrailing, 12, 88.48),
            hold("afterburn", .afterburner, .small, .bottomTrailing, 62.24, 88.48),
            tap("next", .targetNext, "arrow.triangle.2.circlepath", "Next", accent: false,
                .small, .bottomTrailing, 112.48, 88.48),
            tap("target", .targetNearest, "scope", "Target", accent: true,
                .small, .bottomTrailing, 162.72, 88.48),
            TouchControl(id: "weapon", kind: .weaponChip, effect: nil, action: nil,
                         icon: "arrow.triangle.2.circlepath", caption: "Weapon", accent: true,
                         cap: .small, anchor: .bottomTrailing, x: 12, y: 141.12),
            TouchControl(id: "actions", kind: .actionsToggle, effect: nil, action: nil,
                         icon: "square.grid.2x2.fill", caption: "Actions", accent: true,
                         cap: .toggle, anchor: .topTrailing, x: 12, y: 12),
            tap("jump", .hyperjump, "bolt.horizontal.circle.fill", "Jump", accent: true,
                .toggle, .topTrailing, 69.6, 12),
            tap("map", .galaxyMap, "map.fill", "Map", accent: true,
                .toggle, .topTrailing, 127.2, 12),
        ]
    }()

    /// Mirror the flight clusters (bottom corners) left-right. The top-right
    /// Map / Jump / Actions row stays put: the top-left belongs to the pause menu.
    private static func mirroredBottom(_ list: [TouchControl]) -> [TouchControl] {
        list.map { c in
            var c = c
            if c.anchor.isBottom { c.anchor = c.anchor.mirrored }
            return c
        }
    }

    private static let minimalControls: [TouchControl] = {
        let keep: Set<String> = ["turnLeft", "turnRight", "thrust", "fire", "actions"]
        return stockControls.map { c in
            var c = c
            c.hidden = !keep.contains(c.id)
            return c
        }
    }()
}
