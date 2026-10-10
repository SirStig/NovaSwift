import Foundation

/// The loaded-pilot readout the original draws on the main menu
/// (`FUN_004873b0`, the main-menu redraw), kept as plain data so the layout
/// and text rules can be pinned by tests. Coordinates are offsets from the
/// menu centre (the centre of backdrop PICT 8000 — (512, 384) in the
/// 1024×768 design space) and every y is a **text baseline**; the original's
/// single-line text draw puts the glyph box top at `baseline − fontSize`.
public enum MainMenuReadout {

    public struct Line: Equatable {
        public enum Kind: Equatable {
            /// STR# 2002 entry, drawn in cölr MenuColor2 (dim).
            case label(Int)
            /// A value, drawn in cölr MenuColor1 (bright).
            case value(Field)
        }
        public enum Field: Equatable {
            case pilotName, shipName, shipClass, shipSubtitle, legalStatus, combatRating, date
        }
        public var kind: Kind
        public var dx: Int
        public var baselineDY: Int
    }

    /// The live-pilot readout, in the original's draw order.
    public static let lines: [Line] = [
        .init(kind: .label(251), dx: -190, baselineDY: 250),       // "Pilot Name:"
        .init(kind: .value(.pilotName), dx: -185, baselineDY: 262),
        .init(kind: .label(255), dx: -190, baselineDY: 286),       // "Ship Name:"
        .init(kind: .value(.shipName), dx: -185, baselineDY: 298),
        .init(kind: .label(256), dx: -190, baselineDY: 322),       // "Ship Class:"
        .init(kind: .value(.shipClass), dx: -185, baselineDY: 334),
        .init(kind: .value(.shipSubtitle), dx: -185, baselineDY: 346),
        .init(kind: .label(278), dx: 120, baselineDY: 250),        // "Legal status in"
        .init(kind: .label(279), dx: 125, baselineDY: 262),        // "current system:"
        .init(kind: .value(.legalStatus), dx: 125, baselineDY: 274),
        .init(kind: .label(254), dx: 120, baselineDY: 298),        // "Combat Rating:"
        .init(kind: .value(.combatRating), dx: 125, baselineDY: 310),
        .init(kind: .label(252), dx: 120, baselineDY: 334),        // "Current Date:"
        .init(kind: .value(.date), dx: 125, baselineDY: 346),
    ]

    /// The ship's targeting PICT is centred horizontally on the menu centre
    /// with its top at centre + 0x118, composited additively (transfer mode
    /// 0x22, addOver).
    public static let shipPictTopDY = 0x118

    /// Single centred lines (dead pilot, no pilot, creating pilot) are centred
    /// between centre ∓ 150 at baseline centre + 0x136.
    public static let centredLineHalfWidth = 150
    public static let centredLineBaselineDY = 0x136

    /// STR# 2002 entries for the single-line states.
    public static let creatingPilotString = 275   // "Creating Pilot..."
    public static let noPilotString = 276         // "No Pilot File Loaded"
    public static let killedString = 277          // "has been killed"
    public static let notApplicableString = 396   // "N/A"
    /// The easter egg the original prints instead of "<name> has been killed"
    /// when the pilot is named exactly "Kenny".
    public static let kennyLine = "Oh my God! They killed Kenny!"

    /// The dead-pilot line: the Kenny easter egg (the name must start with
    /// "Kenny" — the original compares only those five bytes), otherwise the
    /// name, a space and STR# 2002 #277.
    public static func killedLine(pilotName: String, killedText: String) -> String {
        pilotName.hasPrefix("Kenny") ? kennyLine : pilotName + " " + killedText
    }

    /// Menu buttons (spïn 600-605) are drawn only once the shutter strip their
    /// row belongs to has finished sliding: buttons 0 and 3 follow strip 1,
    /// 1 and 4 strip 2, 2 and 5 strip 3.
    public static func slideIndex(forButton i: Int) -> Int { i % 3 }

    // MARK: Legal status (NovaUi_DrawSystemFactionConflictStatus 0x00468d90)

    /// The STR# 134 entry (1-based) naming a legal record `record` against a
    /// government whose crime tolerance is `tolerance` (gövt CrimeTol).
    /// Entry 1 is never produced here (0 means "N/A" — see `legalStatusEntry`).
    public static func legalRecordEntry(record: Int, tolerance t: Int) -> Int {
        var idx = 0
        if record < 0 { idx = 2 }
        if record < -t { idx = 3 }
        if record < -4 * t { idx = 4 }
        if record < -16 * t { idx = 5 }
        if record < -64 * t { idx = 6 }
        if record < -256 * t { idx = 7 }
        if record < -1024 * t { idx = 8 }
        if record < -4096 * t { idx = 9 }
        if record == 0 { idx = 1 }
        if record > 0 { idx = 10 }
        if record > 4 * t { idx = 11 }
        if record > 16 * t { idx = 12 }
        if record > 64 * t { idx = 13 }
        if record > 256 * t { idx = 14 }
        if record > 1024 * t { idx = 15 }
        return idx + 1
    }

    /// The full rule: dominated stellars among the system's first three
    /// override the record (all of them → "Military Governor" #18, some →
    /// "Military Dictator" #17), and a xenophobic system government gives
    /// nil, which the caller draws as STR# 2002 #396 ("N/A").
    public static func legalStatusEntry(record: Int, tolerance: Int,
                                        dominatedStellars: Int, otherStellars: Int,
                                        governmentIsXenophobic: Bool) -> Int? {
        if governmentIsXenophobic { return nil }
        if dominatedStellars > 0 { return otherStellars < 1 ? 18 : 17 }
        return legalRecordEntry(record: record, tolerance: tolerance)
    }

    // MARK: Date (NovaText_FormatDateString 0x00468450)

    /// "<prefix><month> <day><ordinal>, <year><suffix>" with the month name
    /// from STR# 137 #(month+12) and the ordinal from STR# 137 #25-28.
    public static func date(day: Int, month: Int, year: Int, prefix: String, suffix: String,
                            str137: (Int) -> String?) -> String {
        let monthName = str137(month + 12) ?? "\(month)"
        var ord = str137(28) ?? "th"
        switch day % 10 {
        case 1: ord = str137(25) ?? "st"
        case 2: ord = str137(26) ?? "nd"
        case 3: ord = str137(27) ?? "rd"
        default: break
        }
        if day > 10 && day < 14 { ord = str137(28) ?? "th" }
        return prefix + monthName + " " + "\(day)" + ord + ", " + "\(year)" + suffix
    }
}
