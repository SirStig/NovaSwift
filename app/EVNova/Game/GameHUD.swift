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
    @Published var thrusting = false
    @Published var headingDegrees = 0.0
    @Published var controllerConnected = false
    /// Radar contacts in normalized [-1, 1] space (currently none until NPCs exist).
    @Published var blips: [CGPoint] = []
}

/// An original, EV-style flight HUD (our own artwork — not EV Nova's interface):
/// status bars on the left, a radar scope on the right, a heading/velocity strip.
struct GameHUDView: View {
    @ObservedObject var model: GameHUDModel

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let panel = Color.black.opacity(0.35)

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    statusPanel
                    Spacer()
                    radar
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
            bar("SHIELD", model.shield, Color.cyan)
            bar("ARMOR", model.armor, amber)
            bar("FUEL", model.fuel, Color.green)
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
            // Player at center.
            Image(systemName: "location.north.fill")
                .font(.system(size: 10))
                .foregroundStyle(.cyan)
                .rotationEffect(.degrees(model.headingDegrees))
            // Contacts.
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                ForEach(Array(model.blips.enumerated()), id: \.offset) { _, b in
                    Circle().fill(.red).frame(width: 4, height: 4)
                        .position(x: geo.size.width/2 + b.x * r, y: geo.size.height/2 + b.y * r)
                }
            }
        }
        .frame(width: 108, height: 108)
    }

    private var velocityStrip: some View {
        HStack(spacing: 14) {
            Label("\(model.speed)", systemImage: "gauge.with.dots.needle.67percent")
            Text("HDG \(Int(model.headingDegrees))°")
            if model.thrusting {
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
