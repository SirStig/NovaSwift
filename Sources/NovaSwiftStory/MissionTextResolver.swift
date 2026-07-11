import Foundation
import NovaSwiftKit

/// Expands EV Nova's mission "wildcard" tags in `dësc` text — the `<PN>`,
/// `<CQ>`, `<DSY>`… symbols the game substitutes at display time so a briefing
/// written once can name the specific cargo, destination, pay and pilot for
/// this particular offer (Nova Bible, "Whenever Nova displays a desc resource
/// related to a mission… it replaces a few special wildcard symbols").
///
/// This is distinct from `NovaDescFormatter` (`NovaSwiftKit/TextFormatting.swift`),
/// which resolves the `{bXXX …}` / `{G …}` / `{P …}` *conditionals* every desc
/// carries. The pipeline is: raw bytes → `NovaDescFormatter.render` (conditionals
/// + newline normalization) → `MissionText.resolve` (these `<…>` wildcards).
///
/// Tags whose value isn't yet known (a random destination not chosen until the
/// mission is accepted; a special ship not spawned until accept) resolve to a
/// neutral placeholder rather than leaking the raw `<…>` to the player — the
/// same graceful degradation the Bible notes for `<SN>` used too early.
enum MissionText {

    /// Resolve every `<…>` wildcard in `text` for `mission`, given the current
    /// `player` and `game`. `initialSpob` resolves the "-4 initial stellar"
    /// selector the same way availability matching does.
    /// `travelSpob`/`returnSpob` are the mission's **concrete** destination /
    /// return stellar ids, already resolved from its (possibly random) selectors
    /// by `StoryEngine.concreteStellar` — so `<DST>`/`<DSY>` name a real world
    /// even for the generic "random Federation stellar" cargo runs.
    static func resolve(_ text: String, mission: MissionRes,
                        player: PlayerState, game: NovaGame, initialSpob: Int?,
                        travelSpob: Int? = nil, returnSpob: Int? = nil) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        out.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "<", let close = text[i...].firstIndex(of: ">") else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let tag = String(text[text.index(after: i)..<close])
            if let value = value(for: tag, mission: mission, player: player,
                                  game: game, initialSpob: initialSpob,
                                  travelSpob: travelSpob, returnSpob: returnSpob) {
                out += value
                i = text.index(after: close)
            } else {
                // Not a recognized tag — emit the '<' verbatim and keep scanning
                // (so stray angle brackets in prose survive intact).
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    // MARK: - Tag values

    private static func value(for tag: String, mission: MissionRes, player: PlayerState,
                              game: NovaGame, initialSpob: Int?,
                              travelSpob: Int?, returnSpob: Int?) -> String? {
        switch tag {
        case "PN":  return player.pilotName
        case "PNN": return player.pilotName          // no separate nickname stored
        case "PSN": return player.shipName.isEmpty ? shipTypeName(player.shipType, game) : player.shipName
        case "PST": return shipTypeName(player.shipType, game)
        case "CQ":  return "\(abs(mission.cargoQty))"
        case "CT":  return cargoName(mission.cargoType, game)
        case "DSY": return systemName(ofSpob: travelSpob, game: game)
        case "DST": return stellarName(travelSpob, game: game)
        case "RSY": return systemName(ofSpob: returnSpob, game: game)
        case "RST": return stellarName(returnSpob, game: game)
        case "DL":  return deadlineString(mission, player: player)
        case "PAY": return mission.pay != 0 ? "\(abs(mission.pay))" : ""
        case "REG": return player.pilotName          // this port has no shareware registration
        case "PRK", "RRK": return rankName(player: player, game: game, short: false)
        case "SRK": return rankName(player: player, game: game, short: true)
        case "OSN", "SN": return specialShipName(mission, game: game)
        default:
            // <PRKnnn>/<SRKnnn>: govt-scoped rank name.
            if let govtRank = govtScopedRank(tag, player: player, game: game) { return govtRank }
            return nil
        }
    }

    private static func shipTypeName(_ id: Int, _ game: NovaGame) -> String {
        game.ship(id)?.displayName ?? "ship"
    }

    /// Mission cargo names live in `STR# 4000` (the same list that names the six
    /// standard commodities, extended by the scenario for mission cargo). A
    /// leading '*' marks a "quantityless" proper-noun cargo (Bible) and is
    /// stripped from display.
    private static func cargoName(_ type: Int, _ game: NovaGame) -> String {
        guard type >= 0 else { return "cargo" }
        if let list = game.stringList(4000), type < list.strings.count {
            let s = list.strings[type]
            if !s.isEmpty { return s.hasPrefix("*") ? String(s.dropFirst()) : s }
        }
        if let commodity = Commodity(rawValue: type) { return game.commodityName(commodity) }
        return "cargo"
    }

    /// The name of an already-resolved concrete destination/return stellar.
    private static func stellarName(_ spobID: Int?, game: NovaGame) -> String {
        if let spobID, let spob = game.spob(spobID) { return spob.displayName }
        return "your destination"
    }

    private static func systemName(ofSpob spobID: Int?, game: NovaGame) -> String {
        if let spobID, let sys = game.systems().first(where: { $0.spobs.contains(spobID) }) {
            return sys.name
        }
        return "an unknown system"
    }

    private static func deadlineString(_ mission: MissionRes, player: PlayerState) -> String {
        guard mission.timeLimit > 0 else { return "no deadline" }
        return player.date.adding(days: mission.timeLimit).description
    }

    private static func rankName(player: PlayerState, game: NovaGame, short: Bool) -> String {
        let ranks = player.activeRanks.compactMap { game.rank($0) }
        guard let top = ranks.max(by: { $0.weight < $1.weight }) else { return "captain" }
        let name = short ? top.shortName : top.conversationName
        return name.isEmpty ? "captain" : name
    }

    private static func govtScopedRank(_ tag: String, player: PlayerState, game: NovaGame) -> String? {
        let short: Bool
        let digits: Substring
        if tag.hasPrefix("PRK") { short = false; digits = tag.dropFirst(3) }
        else if tag.hasPrefix("SRK") { short = false; digits = tag.dropFirst(3) }
        else { return nil }
        guard let govt = Int(digits) else { return nil }
        let ranks = player.activeRanks.compactMap { game.rank($0) }.filter { $0.govt == govt }
        guard let top = ranks.max(by: { $0.weight < $1.weight }) else { return "captain" }
        let name = short ? top.shortName : top.conversationName
        return name.isEmpty ? "captain" : name
    }

    private static func specialShipName(_ mission: MissionRes, game: NovaGame) -> String {
        guard mission.shipNameStrID > 0,
              let list = game.stringList(mission.shipNameStrID),
              let first = list.strings.first(where: { !$0.isEmpty }) else { return "the ship" }
        return first
    }
}
