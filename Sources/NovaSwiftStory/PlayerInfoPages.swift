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

    /// Whether the cargo page has anything to list (0x0046a680): a commodity
    /// or junk ton, or a loaded mission cargo of some type — even at 0 tons.
    public var hasCargo: Bool {
        if player.cargo.values.contains(where: { $0 > 0 }) { return true }
        return player.activeMissions.contains { am in
            am.isCarryingCargo && (am.resolvedCargoType ?? game.mission(am.missionID)?.cargoType ?? -1) >= 0
        }
    }

    /// Whether Jettison Cargo is offered (0x0046f140): a commodity or junk
    /// ton, or the loaded cargo of an abortable mission (0 tons included).
    /// A non-abortable mission's cargo alone doesn't count.
    public var canJettison: Bool {
        let mission = PilotEconomy.missionCargo(player, game: game)
        if player.cargo.contains(where: { $0.value - (mission[$0.key] ?? 0) > 0 }) { return true }
        return player.activeMissions.contains { am in
            guard am.isCarryingCargo, let m = game.mission(am.missionID), m.canAbort else { return false }
            return (am.resolvedCargoType ?? m.cargoType) >= 0
        }
    }

    /// Cargo (page 2, `NovaUi_BuildPlayerSpecialInteractionStrings` 0x0049c050):
    /// one running sentence, not a list — "Current cargo in your ship (#362 +
    /// #365, or #366 "in your fleet" when the fleet holds more than the ship):",
    /// a blank line, then the held types in id order, commodities first and
    /// junk after, each "<count word> ton(s) of <name>" (the first count word
    /// capitalised; `Ship_FormatLocalizedCountWord`, STR# 137 words for 1…10,
    /// digits beyond, the junk's lower-case name), joined by ", " with
    /// "and" (#392) before the last, ending in "." and a blank line, then the
    /// free-space footer (#364: "Free cargo space in your fleet:  N tons",
    /// plus "  (M tons free in your ship)" / "(none free in your ship)" when
    /// the ship's own share differs). Empty: "You don't have any cargo aboard
    /// your ship" (#269), or #268 when the fleet carries more than the ship
    /// (freighter escorts, 0x0049a540).
    public func cargo(shipCapacity: Int = 0, fleetCapacity: Int = 0) -> String {
        let held = player.cargo.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        guard hasCargo, !held.isEmpty else { return text.misc(shipCapacity < fleetCapacity ? 268 : 269) }
        let fleet = shipCapacity < fleetCapacity
        var out = "\(text.misc(362)) \(text.misc(fleet ? 366 : 365)):\n\n"
        // Commodities (Commodity ids) come before junk, each in id order.
        let ordered = held.filter { Commodity(rawValue: $0.key) != nil } + held.filter { Commodity(rawValue: $0.key) == nil }
        var items: [String] = []
        for (index, entry) in ordered.enumerated() {
            let (id, tons) = entry
            let name = Commodity(rawValue: id).map { game.commodityName($0) } ?? game.junk(id)?.runningTextName ?? ""
            let count = index == 0 ? text.capitalizedCountWord(tons) : text.localizedCountWord(tons)
            items.append("\(count) \(text.misc(tons == 1 ? 1 : 2)) \(text.misc(391)) \(name)")
        }
        var list = ""
        for (i, item) in items.enumerated() {
            list += item
            if i < items.count - 2 { list += ", " }
            else if i == items.count - 2 { list += (items.count > 2 ? "," : "") + " \(text.misc(392)) " }
        }
        if let first = list.first { list = first.uppercased() + list.dropFirst() }
        out += list + ".\n\n"

        let used = player.usedCargoSpace
        let free = max(0, fleetCapacity - used)
        guard free > 0 else { return out }
        let tonWord = text.misc(free == 1 ? 1 : 2)
        if fleet {
            out += "\(text.misc(364)) \(text.misc(366)):  \(OriginalText.grouped(free)) \(tonWord)"
            let inShip = max(0, shipCapacity - used)
            if inShip != free, inShip < 1 {
                out += "(\(text.misc(336)) \(text.misc(369)))"
            } else if inShip != free {
                out += "  (\(OriginalText.grouped(inShip)) \(text.misc(inShip == 1 ? 1 : 2)) \(text.misc(369)))"
            }
        } else {
            out += "\(text.misc(364)): \(OriginalText.grouped(free)) \(tonWord)"
        }
        return out
    }

    // MARK: Extras and Honors (grouped prose, 0x0049c050)

    /// One owned-outfit group on the Extras / Honors pages: the owned totals of
    /// every outfit that shares the representative's lower-case name.
    struct OutfitGroup {
        let representative: OutfRes
        let count: Int
    }

    /// The owned outfits grouped the way `NovaUi_BuildPlayerSpecialInteractionStrings`
    /// 0x0049c050 groups them. An outfit is listed only when its lower-case
    /// name (`LCName`, the table at 0x0063cccc) is non-empty and its Flags
    /// 0x2000 bit matches the page (`honors`). Its slot adds to its
    /// `similar_to` representative, which the loader (0x004bd3c0) points at the
    /// first earlier outfit with an identical non-empty `LCName` (itself
    /// otherwise). Extras order the groups by the representative's `DispWeight`
    /// (signed, descending, equal weights in slot order); Honors keep slot order.
    func outfitGroups(honors: Bool) -> [OutfitGroup] {
        var firstWithName: [String: Int] = [:]
        var representative: [Int: Int] = [:]
        for outfit in game.outfits().sorted(by: { $0.id < $1.id }) where !outfit.lowercaseName.isEmpty {
            if let first = firstWithName[outfit.lowercaseName] {
                representative[outfit.id] = first
            } else {
                firstWithName[outfit.lowercaseName] = outfit.id
                representative[outfit.id] = outfit.id
            }
        }
        var totals: [Int: Int] = [:]
        for (id, n) in player.outfits where n > 0 {
            guard let outfit = game.outfit(id), !outfit.lowercaseName.isEmpty,
                  outfit.showsInRanksSection == honors, let rep = representative[id] else { continue }
            totals[rep, default: 0] += n
        }
        var groups = totals.keys.sorted().compactMap { id in
            game.outfit(id).map { OutfitGroup(representative: $0, count: totals[id] ?? 0) }
        }
        if !honors {
            // Stable: `sorted(by:)` isn't, so key on (weight desc, id asc).
            groups.sort { a, b in
                let wa = Int16(truncatingIfNeeded: a.representative.displayWeight)
                let wb = Int16(truncatingIfNeeded: b.representative.displayWeight)
                return wa != wb ? wa > wb : a.representative.id < b.representative.id
            }
        }
        return groups
    }

    /// One group's phrase: 1 -> "a"/"an" (by the first letter of the
    /// lower-case name; STR# 2002 #393 / #394), 2 and 3 -> the STR# 137 words
    /// ("two", "three"), 4 and up -> digits, then the lower-case singular or
    /// plural. The original upper-cases the very first letter of the page's
    /// first phrase only when its count is below 4 (a word, not digits).
    func groupPhrase(_ group: OutfitGroup, capitalize: Bool) -> String {
        let outfit = group.representative
        var word: String
        switch group.count {
        case 1: word = text.article(before: outfit.lowercaseName)
        case 2, 3: word = text.localizedCountWord(group.count)
        default: word = OriginalText.grouped(group.count)
        }
        if capitalize, group.count < 4, let first = word.first { word = first.uppercased() + word.dropFirst() }
        return "\(word) \(group.count > 1 ? outfit.lowercasePluralDisplayName : outfit.lowercaseName)"
    }

    /// Extras (page 3): "Current extras for your ship:" (#272) and a blank
    /// line, then one sentence of count-word phrases over the `similar_to`
    /// groups ("A fuel scoop, two shield boosters, and 5 light blasters."),
    /// with a comma after every phrase but the last when there are more than
    /// two, and "and" (#392) before the last. Then ".\n\n" and, when the
    /// ship's trade-in value is positive, "Ship trade-in value: N credit(s)"
    /// (#273, #32 / #33). Nothing owned: only #270 (the draw routine's
    /// fallback).
    public func extras(tradeInValue: Int?) -> String {
        let groups = outfitGroups(honors: false)
        guard !groups.isEmpty else { return text.misc(270) }
        let n = groups.count
        var out = text.misc(272) + "\n\n"
        for (i, group) in groups.enumerated() {
            let e = i + 1
            out += groupPhrase(group, capitalize: i == 0)
            if e <= n - 1, n > 2 { out += "," }
            if e < n - 1 { out += " " } else if e == n - 1 { out += " \(text.misc(392)) " }
        }
        if let tradeInValue, tradeInValue > 0 {
            out += ".\n\n\(text.misc(273)) \(OriginalText.grouped(tradeInValue)) \(text.misc(tradeInValue == 1 ? 32 : 33))"
        } else {
            out += "."
        }
        return out
    }

    /// Honors (page 4): "Your ranks and honors:" (#274) and a blank line, the
    /// held ranks with a name by `Weight` (highest first, equal weights in slot
    /// order), then the Flags 0x2000 outfit groups in slot order with the same
    /// count-word phrases. The list glue is the original's: after every entry
    /// but the last a comma, plus "and" (#392) after the second-to-last, but
    /// the outfit entries get only ", " (so a list that ends in two or more
    /// outfits has no "and" between them). No closing period. Nothing: #271.
    public func honors() -> String {
        let ranks = player.activeRanks.compactMap { game.rank($0) }
            .filter { !$0.conversationName.isEmpty }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
        let groups = outfitGroups(honors: true)
        let total = ranks.count + groups.count
        guard total > 0 else { return text.misc(271) }
        var out = text.misc(274) + "\n\n"
        var e = 0
        for rank in ranks {
            e += 1
            out += rank.conversationName
            if e <= total - 1 { out += "," }
            if e < total - 1 { out += " " } else if e == total - 1 { out += " \(text.misc(392)) " }
        }
        for group in groups {
            e += 1
            out += groupPhrase(group, capitalize: ranks.isEmpty && e == 1)
            if e <= total - 1 { out += ", " }
        }
        return out
    }
}
