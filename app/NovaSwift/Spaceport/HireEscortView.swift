import SwiftUI
import NovaSwiftKit

/// The spaceport bar's **Hire Escort** panel. EV Nova lets you rent escort ships
/// at a planet's bar; which hulls are on offer on a given day is gated by each
/// `shïp`'s `HireRandom` percentage (rolled per day / per spöb — see
/// `PilotStore.escortAvailableToday`). Hiring charges a flat up-front fee and
/// then a recurring **daily fee** while the escort stays in your service
/// (`ShipRes.escortHireFee` / `escortDailyFee`); the ship joins you when you next
/// take off. Captured ships, by contrast, are free — so this panel always shows
/// the daily cost prominently, matching the original's "the larger and more
/// powerful the vessel, the higher the fee" framing.
struct HireEscortView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    @State private var refresh = 0
    private var game: NovaGame { graphics.game }
    /// Today's galaxy day — the seed for the per-day availability roll.
    private var day: Int { pilot.state.date.julianDay }

    /// Ships offered for hire at this bar today: `HireRandom > 0` and passing the
    /// day/spöb availability roll, cheapest first.
    private var available: [ShipRes] {
        _ = refresh
        return game.ships()
            .filter { $0.hireRandom > 0 && pilot.escortAvailableToday($0, at: spob, day: day) }
            .sorted { $0.escortHireFee < $1.escortHireFee }
    }

    private static func categoryLabel(_ c: Int) -> String {
        switch c {
        case 0: return "Fighter"
        case 1: return "Medium Ship"
        case 2: return "Warship"
        case 3: return "Freighter"
        default: return "Escort"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(novaAmber.opacity(0.3))
            if available.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash").font(.system(size: 26))
                        .foregroundStyle(Color(white: 0.45))
                    NovaText("No ships are available for hire here today.",
                             size: 12, color: Color(white: 0.6), width: 260, align: .center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(available, id: \.id) { row($0) }
                    }
                    .padding(8)
                }
                .frame(height: 300)
            }
            Divider().overlay(novaAmber.opacity(0.3))
            footer
        }
        .frame(width: 460)
        .background(Color(white: 0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .novaResponsive()
    }

    private var header: some View {
        VStack(spacing: 2) {
            NovaText("Ships for Hire", size: 15, color: .white, weight: .bold)
            NovaText("Hired escorts cost a daily fee — captured ships are free.",
                     size: 10, color: Color(white: 0.55))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }

    private func row(_ ship: ShipRes) -> some View {
        let affordable = pilot.state.credits >= ship.escortHireFee
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                NovaText(ship.name, size: 12, color: .white, weight: .semibold)
                NovaText(Self.categoryLabel(ship.escortCategory), size: 9, color: Color(white: 0.5))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                NovaText("Hire \(ship.escortHireFee)cr", size: 11,
                         color: affordable ? .white : Color(red: 0.85, green: 0.4, blue: 0.4))
                NovaText("\(ship.escortDailyFee)cr/day", size: 10, color: novaAmber)
            }
            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.hireEscort, fallback: "Hire"),
                       width: 84, enabled: affordable) {
                if pilot.hireEscort(ship, at: spob, day: day) { refresh += 1 }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
    }

    private var footer: some View {
        HStack {
            NovaText("Credits: \(pilot.state.credits)", size: 11, color: Color(white: 0.7))
            Spacer()
            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 90, action: onDone)
        }
        .padding(12)
    }
}
