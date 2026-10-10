import Foundation

/// The generic `dësc` text dialog (`Ui_RunTravelSelectionDialog` 0x004982a0,
/// drawn by `FUN_00499870`) — mission briefings, completion/failure/refusal
/// text, About (dësc 32767) and the other plain description readers.
///
/// - Text only (dësc graphic < 128): DLOG/DITL 3003 on PICT 8524 (top), 8525
///   (body, drawn below the top) and 8526 (bottom, aligned to the dialog's
///   bottom edge). The dialog shrinks to the text: when the wrapped text is
///   shorter than item 3, the dialog, item 3 and items 1/5/6 move up by
///   `(itemHeight − max(textHeight, 0x30)) − 16`.
/// - With a graphic: DLOG/DITL 3004 on backdrop PICT 8527, the dësc PICT
///   in item 2, no shrinking.
///
/// The mission-offer window (8521-8523) is a different dialog.
public enum DescDialogLayout {
    public static let textDialogID = 3003
    public static let pictDialogID = 3004
    public static let topPict = 8524, bodyPict = 8525, bottomPict = 8526
    public static let pictBackdrop = 8527
    public static let minTextHeight = 0x30

    public static func usesPicture(graphicID: Int?) -> Bool { (graphicID ?? 0) >= 128 }

    /// How far the text-only dialog shrinks (may be negative — the original
    /// applies the formula whenever the text is shorter than the item, so text
    /// within 16 px of the item's height grows the dialog slightly).
    public static func shrink(textHeight: Int, textItemHeight: Int) -> Int {
        guard textHeight < textItemHeight else { return 0 }
        return (textItemHeight - max(textHeight, minTextHeight)) - 16
    }
}
