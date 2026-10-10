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
/// It follows the original pass (0x004444f0, MS-16): each tag is replaced in a
/// fixed order, and a tag with nothing behind it reads `[Error]`, exactly as
/// the original prints it.
enum MissionText {

    /// What a mission tag can name: an offer's resolved targets, or an
    /// accepted mission's slot. `nil` fields (a mission no longer running)
    /// leave every mission tag as `[Error]`.
    struct Fields {
        var travelSpob: Int?
        var returnSpob: Int?
        var cargoType: Int
        var cargoQty: Int
        var pay: Int
        var deadline: GameDate?
        /// `<SN>`: the name rolled at accept; nil on an offer.
        var specialShipName: String?
        var accepted: Bool
    }

    static let errorText = "[Error]"

    /// `otherShipName` is `<OSN>`: the speaking ship's përs name on a hail
    /// quote (0x004444f0 reads it from the announcing ship), `[Error]` otherwise.
    static func resolve(_ text: String, fields: Fields?, player: PlayerState, game: NovaGame,
                        otherShipName: String? = nil) -> String {
        guard text.contains("<") else { return text }
        var out = text

        var destination = errorText, destinationSystem = errorText
        var returnName = errorText, returnSystem = errorText
        var cargoName = errorText, cargoQty = errorText, shipName = errorText
        var deadline = errorText
        if let f = fields {
            destination = stellarName(f.travelSpob, game)
            destinationSystem = systemName(ofSpob: f.travelSpob, game)
            returnName = stellarName(f.returnSpob, game)
            returnSystem = systemName(ofSpob: f.returnSpob, game)
            // An unresolvable destination borrows the return stellar's name.
            if destination == errorText, returnName != errorText { destination = returnName }
            if destinationSystem == errorText, returnSystem != errorText { destinationSystem = returnSystem }
            cargoName = cargoTypeName(f.cargoType, game)
            if f.cargoType >= 0 { cargoQty = "\(f.cargoQty)" }
            if f.accepted { shipName = f.specialShipName ?? "" }
            // Due today reads "[Error]"; no time limit prints the zero date.
            if f.deadline != player.date {
                deadline = longDate(f.deadline, game: game)
            }
        }
        let pay = fields.map { payText($0.pay, credits: player.credits) } ?? "0"
        let shipType = game.ship(player.shipType)?.displayName ?? ""

        let replacements: [(String, String)] = [
            ("<DST>", destination), ("<DSY>", destinationSystem),
            ("<RST>", returnName), ("<RSY>", returnSystem),
            ("<CT>", cargoName), ("<CQ>", cargoQty), ("<SN>", shipName), ("<DL>", deadline),
            ("<PN>", player.pilotName),
            ("<PNN>", (player.nickname ?? "").isEmpty ? player.pilotName : player.nickname!),
            ("<PSN>", player.shipName.isEmpty ? errorText : player.shipName),
            ("<PST>", shipType.isEmpty ? errorText : shipType),
            ("<OSN>", otherShipName ?? errorText),   // only a speaking ship's hail fills it
            ("<PRK>", topRank(player, game, short: false, govt: nil)),
            ("<SRK>", topRank(player, game, short: true, govt: nil)),
            ("<RRK>", player.recentRank.flatMap { game.rank($0)?.name } ?? captain(game)),
            ("<PAY>", pay),
            ("<REG>", "EV Nova Community"),
        ]
        // The per-government rank tags are found before any replacement. The
        // original fills them crosswise: `<PRKnnn>` gets the short name of the
        // government named by the text's `<SRKnnn>`, and `<SRKnnn>` that of the
        // `<PRKnnn>` government, "captain" when the other tag is absent.
        let prkGovt = firstGovtTag("<PRK", in: text)
        let srkGovt = firstGovtTag("<SRK", in: text)
        for (tag, value) in replacements { out = out.replacingOccurrences(of: tag, with: value) }
        if let g = prkGovt {
            out = out.replacingOccurrences(of: "<PRK\(g)>",
                                           with: srkGovt.map { topRank(player, game, short: true, govt: $0) } ?? captain(game))
        }
        if let g = srkGovt {
            out = out.replacingOccurrences(of: "<SRK\(g)>",
                                           with: prkGovt.map { topRank(player, game, short: true, govt: $0) } ?? captain(game))
        }
        return out
    }

    // MARK: - Tag values

    private static func stellarName(_ spobID: Int?, _ game: NovaGame) -> String {
        guard let spobID, let spob = game.spob(spobID) else { return errorText }
        return spob.displayName
    }

    private static func systemName(ofSpob spobID: Int?, _ game: NovaGame) -> String {
        guard let spobID, let sys = game.systemContaining(spob: spobID).flatMap({ game.system($0) }) else {
            return errorText
        }
        return sys.displayName
    }

    /// `<CT>`: `STR ` 9100+type over STR# 4001 entry `type + 1`, its leading `*` (a quantityless
    /// cargo) stripped.
    private static func cargoTypeName(_ type: Int, _ game: NovaGame) -> String {
        guard (0..<256).contains(type), var name = game.cargoTypeName(type) else {
            return errorText
        }
        if name.hasPrefix("*") { name.removeFirst() }
        return name
    }

    /// `<PAY>` (0x00465c10): credits, an acceptance fee (`|PayVal| - 50000`) or
    /// a percent of the player's credits; other codes show 0. Grouped with
    /// commas, or `x.xxM` past a million.
    static func payText(_ pay: Int, credits: Int) -> String {
        var shown = 0
        if pay > 0 {
            shown = pay
        } else if pay < -50000 {
            shown = -pay - 50000
        } else if pay < -40000, pay >= -40035 {
            shown = max(0, Int((Double(credits) * Double(-pay - 40000) * 0.01).rounded(.toNearestOrEven)))
        }
        return formatQuantity(shown)
    }

    static func formatQuantity(_ value: Int) -> String {
        let v = max(0, value)
        if v < 1000 { return "\(v)" }
        if v < 1_000_000 { return "\(v / 1000)," + String(format: "%03d", v % 1000) }
        return "\(v / 1_000_000)." + String(format: "%02d", (v % 1_000_000) / 10000) + "M"
    }

    /// `<DL>`: "<prefix>Month Dth, Year<suffix>" with the STR# 137 month and
    /// ordinal strings and the scenario's date affixes. A missing date is the
    /// zero date the original prints for a mission with no time limit.
    static func longDate(_ date: GameDate?, game: NovaGame) -> String {
        let (day, month, year) = date.map { ($0.day, $0.month, $0.year) } ?? (0, 0, 0)
        let months = game.stringList(137)
        var ordinal = 28                                  // "th"
        switch day % 10 {
        case 1: ordinal = 25
        case 2: ordinal = 26
        case 3: ordinal = 27
        default: break
        }
        if (11...13).contains(day) { ordinal = 28 }
        let affixes = game.characters().sorted { $0.id < $1.id }.first
        return (affixes?.datePrefix ?? "") + (months?.string(at: month) ?? "") + " \(day)"
            + (months?.string(at: ordinal) ?? "th") + ", \(year)" + (affixes?.dateSuffix ?? "")
    }

    private static func captain(_ game: NovaGame) -> String {
        game.stringList(2002)?.string(at: 0x155) ?? "captain"
    }

    /// The highest-weighted active rank (optionally of one government) that
    /// has the wanted name set; the lowest id wins a tie.
    private static func topRank(_ player: PlayerState, _ game: NovaGame, short: Bool, govt: Int?) -> String {
        var best: RankRes?
        for id in player.activeRanks.sorted() {
            guard let r = game.rank(id) else { continue }
            if let govt, r.govt != govt { continue }
            let name = short ? r.shortName : r.conversationName
            guard !name.isEmpty else { continue }
            if best == nil || r.weight > best!.weight { best = r }
        }
        guard let best else { return captain(game) }
        return short ? best.shortName : best.conversationName
    }

    /// The government id of the first `<PRKnnn>` / `<SRKnnn>` tag in `text`.
    private static func firstGovtTag(_ prefix: String, in text: String) -> Int? {
        var search = text[...]
        while let r = search.range(of: prefix) {
            let rest = search[r.upperBound...]
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, rest.dropFirst(digits.count).first == ">", let g = Int(digits),
               (128...383).contains(g) {
                return g
            }
            search = rest
        }
        return nil
    }
}
