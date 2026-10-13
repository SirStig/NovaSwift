import Foundation

/// The movie the original plays when the player enters a hypergate or a wormhole.
///
/// `Stellar_EnterHypergate` (0x00456480) and `Stellar_EnterWormhole` (0x00456ca0) both call
/// `FUN_0049e3c0(player.travelSelection + 0x80)` **before** the transport moves the ship (hypergate:
/// after the map's destination pick; wormhole: right after the exit is chosen): it loads the `dësc`
/// whose resource id is the travel selection (`ship+0x6c`, whose meaning follows the travel mode
/// `ship+0x6a`; -1 names `dësc 127`, so nothing plays) and hands its MovieFile plus the dësc Flags
/// (0x0002 = double size, 0x0004 = blank the screen) to `Ui_PlayMovieFileModal` (0x0049db00).
///   * hypergate (mode 4, the gate map): the chosen **destination sÿst** id;
///   * wormhole (mode 2, the travel stellar the player landed on): the **wormhole's own spöb** id.
/// No text is shown (this is not `Ui_RunTravelSelectionDialog`), the movie is modal and skippable, and
/// `Ui_PlayMovieFileModal` returns at once when the "QuickTime Movies" preference is off
/// (`DAT_005914d3`).
///
/// In resource-id terms the dësc id equals that sÿst / spöb id. Base EV Nova ships no such dësc
/// records (the movie is for total conversions / plug-ins), so this normally returns nil.
public enum GateTravelMovie {
    /// The `dësc` id a gate transport plays for travel-target system `systemID` (a sÿst resource id).
    public static func descID(forTravelSelection id: Int) -> Int { id }
}

extension NovaGame {
    /// The `dësc` carrying the gate-entry movie for the travel selection (hypergate: destination sÿst id;
    /// wormhole: the wormhole's spöb id), or nil when there is none, no such record, or it names no movie.
    public func gateTravelMovieDesc(selection: Int?) -> DescRes? {
        guard let selection, selection >= 128,
              let d = desc(GateTravelMovie.descID(forTravelSelection: selection)),
              let name = d.movieFilename?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return d
    }
}
