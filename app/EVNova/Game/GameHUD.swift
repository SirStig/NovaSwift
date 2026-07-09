import SwiftUI

/// Live HUD state, updated by `GameScene` (throttled) and read by `GameHUDView`.
@MainActor
final class GameHUDModel: ObservableObject {
    @Published var shipName = ""
    @Published var speed = 0
    @Published var maxSpeed = 1
    @Published var shield = 1.0     // 0…1
    @Published var armor = 1.0      // 0…1
    @Published var fuel = 1.0       // 0…1
    @Published var jumps = 0        // whole hyperjumps of fuel remaining
    @Published var thrusting = false
    @Published var afterburning = false
    @Published var headingDegrees = 0.0
    @Published var controllerConnected = false
    @Published var systemName = ""
    // Loadout readout.
    @Published var weaponName = ""      // active primary weapon (empty = unarmed)
    @Published var weaponAmmo = -1      // rounds left; -1 = unlimited / n/a
    @Published var cargoUsed = 0
    @Published var cargoCapacity = 0
    /// Non-empty while a landable stellar object is in reach (shown as a prompt).
    @Published var landPrompt = ""
    /// Non-empty briefly after hailing a ship (bottom-left banner), e.g. "The
    /// Federation hails you." Cleared on a fade timer by whoever sets it.
    @Published var hailMessage = ""
    /// The player's locked target, if any (empty name = no target locked).
    @Published var targetName = ""
    @Published var targetShield = 1.0   // 0…1
    @Published var targetArmor = 1.0    // 0…1
    @Published var targetHostile = false
    /// Ship contacts in normalized [-1, 1] radar space (out-of-range ships are omitted).
    @Published var blips: [RadarContact] = []
    /// Stellar-object contacts (planets/stations) in normalized radar space.
    @Published var planetBlips: [RadarContact] = []
}

/// How a radar contact relates to the player, driving its dot color: red for a
/// hostile, yellow for a neutral that's neither friend nor foe, green for
/// something the player owns/is allied with, grey for anything disabled,
/// uninhabited, or otherwise non-functional (drifting hulks, dead stations).
enum RadarRelationship {
    case hostile, neutral, friendlyOrOwned, disabled

    var color: Color {
        switch self {
        case .hostile: return Color(red: 0.95, green: 0.3, blue: 0.25)
        case .neutral: return Color(red: 0.95, green: 0.85, blue: 0.25)
        case .friendlyOrOwned: return Color(red: 0.4, green: 0.9, blue: 0.4)
        case .disabled: return Color(white: 0.55)
        }
    }
}

/// One contact (ship or stellar object) on the radar scope, in normalized
/// [-1, 1] space.
struct RadarContact {
    var x: CGFloat
    var y: CGFloat
    var relationship: RadarRelationship
}

/// The player marker at the centre of the radar: a slim needle arrow pointing
/// "up" in its rect, meant to be rotated to the ship's heading.
struct RadarPlayerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))                // nose
        p.addLine(to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.92))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.68)) // tail notch
        p.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.92))
        p.closeSubpath()
        return p
    }
}

/// An original, EV-style flight HUD (our own artwork — not EV Nova's interface):
/// status bars on the left, a radar scope on the right, a heading/velocity strip.
struct GameHUDView: View {
    @ObservedObject var model: GameHUDModel
    var showRadar: Bool = true

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let panel = Color.black.opacity(0.35)

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    statusPanel
                    Spacer()
                    if showRadar { radar }
                }
                Spacer()
                velocityStrip
            }
            .padding(16)
        }
        .allowsHitTesting(false)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.shipName.uppercased())
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundStyle(amber)
            if !model.systemName.isEmpty {
                Text(model.systemName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            bar("SHIELD", model.shield, Color.cyan)
            bar("ARMOR", model.armor, amber)
            bar(model.jumps > 0 ? "FUEL · \(model.jumps) JUMP\(model.jumps == 1 ? "" : "S")" : "FUEL",
                model.fuel, Color.green)
            if model.cargoCapacity > 0 {
                Text("CARGO \(model.cargoUsed)/\(model.cargoCapacity)t")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
    }

    private func bar(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * value))
                }
            }
            .frame(width: 140, height: 8)
        }
    }

    private var radar: some View {
        ZStack {
            Circle().fill(panel)
            Circle().strokeBorder(amber.opacity(0.5), lineWidth: 1)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).scaleEffect(0.6)
            // Contacts, drawn crisply in one pass.
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 5
                for b in model.planetBlips {
                    let rect = CGRect(x: c.x + b.x * r - 2.5, y: c.y + b.y * r - 2.5,
                                      width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: rect), with: .color(b.relationship.color))
                }
                for b in model.blips {
                    let rect = CGRect(x: c.x + b.x * r - 1.5, y: c.y + b.y * r - 1.5,
                                      width: 3, height: 3)
                    ctx.fill(Path(ellipseIn: rect), with: .color(b.relationship.color))
                }
            }
            // Player at center.
            ZStack {
                RadarPlayerArrow().fill(.cyan)
                RadarPlayerArrow().stroke(.white.opacity(0.8), lineWidth: 0.5)
            }
            .frame(width: 9, height: 12)
            .rotationEffect(.degrees(model.headingDegrees))
        }
        .frame(width: 108, height: 108)
    }

    private var velocityStrip: some View {
        HStack(spacing: 14) {
            Label("\(model.speed)", systemImage: "gauge.with.dots.needle.67percent")
            Text("HDG \(Int(model.headingDegrees))°")
            if !model.weaponName.isEmpty {
                Label {
                    Text(model.weaponAmmo >= 0 ? "\(model.weaponName) ×\(model.weaponAmmo)" : model.weaponName)
                } icon: {
                    Image(systemName: "scope")
                }
                .foregroundStyle(.cyan)
            }
            if model.afterburning {
                Label("BURN", systemImage: "flame.circle.fill").foregroundStyle(.orange)
            } else if model.thrusting {
                Label("THRUST", systemImage: "flame.fill").foregroundStyle(amber)
            }
            if model.controllerConnected {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(panel, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: .infinity)
    }
}
