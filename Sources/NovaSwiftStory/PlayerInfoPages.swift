import Foundation
import NovaSwiftKit

/// The Player Info window's text (UI-13; `NovaUi_DrawPlayerInfoWindow`
/// 0x0049a540 and `NovaUi_BuildPlayerSpecialInteractionStrings` 0x0049c050):
/// a stat grid on page 1 and the cargo, extras and honors pages, every label
/// read from STR# 2002 / 134 / 137 / 138.
public struct PlayerInfoPages {
    public let game: NovaGame
    public let player: PlayerState
    private let text: OriginalText

    public init(game: NovaGame, player: PlayerState) {
        self.game = game
        self.player = player
        self.text = OriginalText(game: game)
    }

    /// The live ship's figures, read off the flying ship (the original reads
    /// its runtime struct).
    public struct ShipFigures: Sendable {
        /// Whole degrees per tick the player turns.
        public var turnDegPerTick: Int
        /// Effective thrust, px/tick².
        public var thrustPerTick2: Double
        /// Effective top speed, px/tick (the non-strict ×1.5 included).
        public var maxSpeedPerTick: Double
        public var shield: Double, maxShield: Double
        public var armor: Double, maxArmor: Double
        public var destroyed: Bool
        public var fuel: Double

        public init(turnDegPerTick: Int, thrustPerTick2: Double, maxSpeedPerTick: Double,
                    shield: Double, maxShield: Double, armor: Double, maxArmor: Double,
                    destroyed: Bool, fuel: Double) {
            self.turnDegPerTick = turnDegPerTick
            self.thrustPerTick2 = thrustPerTick2
            self.maxSpeedPerTick = maxSpeedPerTick
            self.shield = shield
            self.maxShield = maxShield
            self.armor = armor
            self.maxArmor = maxArmor
            self.destroyed = destroyed
            self.fuel = fuel
        }
    }

    public struct Row: Hashable, Sendable {
        public let label: String
        public let value: String
    }

    // MARK: Page 1

    /// The left column: pilot, date, system, legal status, combat rating, then
    /// shield / armor / energy status.
    public func leftColumn(_ ship: ShipFigures?) -> [Row] {
        let na = text.misc(396)
        var rows = [
            Row(label: text.misc(251), value: player.pilotName),
            Row(label: text.misc(252), value: text.date(for: player)),
            Row(label: text.misc(253), value: game.system(player.currentSystem)?.displayName ?? ""),
            Row(label: text.misc(326), value: LegalStatus.label(inSystem: player.currentSystem, player: player,
                                                                game: game, requireUsableDestination: true)),
            Row(label: text.misc(254), value: text.combatRating(player.combatRating)),
        ]
        guard let ship else { return rows }
        let shield = ship.maxShield <= 0 ? na
            : ship.shield <= 0 ? text.misc(15)
            : "\(Int((ship.shield / ship.maxShield * 100).rounded()))%"
        let armor = ship.destroyed ? text.misc(261)
            : ship.maxArmor <= 0 ? na
            : "\(Int((ship.armor / ship.maxArmor * 100).rounded()))%"
        rows.append(Row(label: text.misc(12), value: shield))
        rows.append(Row(label: text.misc(17), value: armor))
        rows.append(Row(label: text.misc(8), value: energy(ship.fuel)))
        return rows
    }

    /// "N jump(s) plus maneuvering energy", or "maneuvering energy only" below
    /// one jump (#239 / #240, #262 / #263, #9).
    func energy(_ fuel: Double) -> String {
        let jumps = Int(fuel / 100)
        if jumps < 1 { return fuel > 0 ? "\(text.misc(9)) \(text.misc(263))" : "0 \(text.misc(240))" }
        var s = "\(jumps) \(text.misc(jumps == 1 ? 239 : 240))"
        if fuel.truncatingRemainder(dividingBy: 100) >= 1 { s += " \(text.misc(262)) \(text.misc(9))" }
        return s
    }

    /// The right column: ship name and class, turn rate × 30 "°/sec", thrust
    /// × 2500, top speed × 100 (× 2/3 when not playing strict, cancelling the
    /// ×1.5 the player flies with), and grouped credits.
    public func rightColumn(_ ship: ShipFigures?) -> [Row] {
        let hull = game.ship(player.shipType)
        var rows = [
            Row(label: text.misc(255), value: player.shipName.isEmpty ? (hull?.displayName ?? "") : player.shipName),
            Row(label: text.misc(256), value: hull?.displayName ?? ""),
        ]
        if let ship {
            let speedScale = player.isStrictPlay ? 1.0 : 2.0 / 3.0
            rows.append(Row(label: text.misc(257), value: "\(ship.turnDegPerTick * 30)\(text.misc(258))"))
            rows.append(Row(label: text.misc(259), value: "\(Int((ship.thrustPerTick2 * 2500).rounded()))"))
            rows.append(Row(label: text.misc(260), value: "\(Int((ship.maxSpeedPerTick * 100 * speedScale).rounded()))"))
        }
        let word = text.misc(33)
        rows.append(Row(label: word.prefix(1).uppercased() + word.dropFirst() + ":",
                        value: OriginalText.grouped(player.credits)))
        return rows
    }

    /// Expenses, income or net per day (#264–#267): hired escorts' upkeep
    /// against dominated tribute and rank salaries (paid while under the cap).
    public func dailyEconomy() -> String {
        var expenses = player.totalDailyEscortFee
        var income = (player.dominatedStellars ?? []).compactMap { game.spob($0)?.tribute }.reduce(0, +)
        for id in player.activeRanks {
            guard let r = game.rank(id) else { continue }
            if r.salaryCap < 1 || player.credits < r.salaryCap { income += r.salary }
        }
        if income < 0 { expenses -= income; income = 0 }
        let perDay = "\(text.misc(33)) \(text.misc(267))"
        if expenses > income { return "\(text.misc(264)) \(OriginalText.grouped(expenses)) \(perDay)" }
        if expenses == 0 { return "\(text.misc(265)) \(OriginalText.grouped(income)) \(perDay)" }
        return "\(text.misc(266)) \(text.misc(265)) \(OriginalText.grouped(income - expenses)) \(perDay)"
    }

    // MARK: Pages 2–4

    /// Cargo: commodities and junk with count words, or "You don't have any
    /// cargo aboard your ship" (#269).
    public func cargo() -> String {
        let held = player.cargo.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        guard !held.isEmpty else { return text.misc(269) }
        return held.map { id, tons in
            let name = Commodity(rawValue: id).map { game.commodityName($0) } ?? game.junk(id)?.name ?? ""
            return "\(text.countWord(tons)) \(text.misc(tons == 1 ? 1 : 2)) \(text.misc(391)) \(name)"
        }.joined(separator: "\n")
    }

    /// Extras: "Current extras for your ship:" (#272), outfits by cost,
    /// highest first, with count words; footer "Ship trade-in value:" (#273).
    /// Empty: #270.
    public func extras(tradeInValue: Int?) -> String {
        var owned: [(outfit: OutfRes, count: Int)] = []
        for (id, n) in player.outfits where n > 0 {
            guard let outfit = game.outfit(id), !outfit.showsInRanksSection else { continue }
            owned.append((outfit, n))
        }
        owned.sort { a, b in
            a.outfit.cost != b.outfit.cost ? a.outfit.cost > b.outfit.cost : a.outfit.id < b.outfit.id
        }
        var lines: [String] = []
        if owned.isEmpty {
            lines.append(text.misc(270))
        } else {
            lines.append(text.misc(272))
            for (outfit, n) in owned {
                lines.append(n == 1 ? outfit.lowercaseDisplayName
                                    : "\(text.countWord(n)) \(outfit.lowercasePluralDisplayName)")
            }
        }
        if let tradeInValue {
            lines.append("")
            lines.append("\(text.misc(273)) \(OriginalText.grouped(tradeInValue)) \(text.misc(33))")
        }
        return lines.joined(separator: "\n")
    }

    /// Honors: "Your ranks and honors:" (#274), ranks by Weight then the
    /// outfits flagged 0x2000; empty #271.
    public func honors() -> String {
        let ranks = player.activeRanks.compactMap { game.rank($0) }
            .sorted { $0.weight < $1.weight }
            .map(\.conversationName).filter { !$0.isEmpty }
        let outfits = player.outfits.filter { $0.value > 0 }.sorted { $0.key < $1.key }
            .compactMap { id, _ in game.outfit(id) }.filter(\.showsInRanksSection).map(\.displayName)
        let all = ranks + outfits
        guard !all.isEmpty else { return text.misc(271) }
        return ([text.misc(274), ""] + all).joined(separator: "\n")
    }
}
