import Foundation
import NovaSwiftKit

/// The story-flavoured spaceport screens' content — the Bar's description and the
/// Holovid news — resolved from the data the way the Apple `BarView` /
/// `HolovidView` do, so a second frontend (the Godot one) shows the same text.
public enum SpaceportStory {
    /// The bar description: `dësc` (spöb id + 9872), with the Apple screen's
    /// fallback line when the stellar has none.
    public static func barText(game: NovaGame, spob: SpobRes) -> String {
        let t = game.descText(spob.id + 9872)
        return t.isEmpty ? "The spaceport bar is quiet tonight." : t
    }

    /// The `dësc` picture of the bar description, if it carries one.
    public static func barPictureID(game: NovaGame, spob: SpobRes) -> Int? {
        game.desc(spob.id + 9872)?.pictureID
    }

    /// The Holovid window: the backdrop PICT (the station government's `NewsPic`
    /// when >= 128, else the generic 9000) and its body — the headline (STR#
    /// 8100), then this station's crön news, else a generic item (STR# 8101),
    /// else STR# 2002 #191 (MS-20).
    public static func holovid(game: NovaGame, player: PlayerState, spob: SpobRes) -> (pict: Int, text: String) {
        let stationGovt: Int? = spob.government >= 128 ? spob.government : nil
        let pict: Int
        if let g = stationGovt.flatMap({ game.govt($0) }), g.newsPic >= 128 { pict = g.newsPic } else { pict = 9000 }
        let seed = StoryEngine.landingSeed(player: player, spobID: spob.id)
        let headline = StoryEngine(game: game, player: player, seed: seed &+ 1).newsHeadline()
        let engine = StoryEngine(game: game, player: player, seed: seed)
        let cron = engine.stationNews(forGovt: stationGovt)
        let items = cron.isEmpty ? engine.genericNews().map { [$0] } ?? [] : cron
        let story = items.isEmpty ? " " + OriginalText(game: game).misc(191) : items.joined(separator: "\n\n")
        return (pict, headline.isEmpty ? story : headline + "\n\n" + story)
    }
}
