import Foundation
import NovaSwiftKit

/// The currency word the original appends after a grouped amount: STR# 2002
/// #34 ("cr" in the stock data), drawn after a space. Refreshed from the
/// loaded data set so a TC's own word shows up (see `GameDataController`).
enum CreditsFormatting {
    nonisolated(unsafe) static var suffix = "cr"

    static func refresh(from game: NovaGame) {
        if let s = game.stringList(2002)?.string(at: 34), !s.isEmpty { suffix = s }
        else { suffix = "cr" }
    }
}

extension Int {
    /// A credit amount the way the original draws it: the grouped number of
    /// `DrawContext_DrawGroupedUInt` 0x00465af0 ("850", "12,345", "1.23M" —
    /// the millions truncated, not rounded), then " " and STR# 2002 #34.
    /// Used everywhere the UI shows a credit amount so every screen agrees.
    var creditsAbbreviated: String {
        NovaNumberFormat.grouped(self) + " " + CreditsFormatting.suffix
    }
}
