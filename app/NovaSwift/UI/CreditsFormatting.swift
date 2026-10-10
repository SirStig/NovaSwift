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
    /// The status bar's credits figure (FUN_00465af0): below 1,000 plain;
    /// below a million "N,NNN"; else "N.NNM" with the hundredths truncated.
    var creditsHUD: String {
        let n = self
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(n / 1000)," + String(format: "%03d", n % 1000) }
        return "\(n / 1_000_000)." + String(format: "%02d", (n % 1_000_000) / 10_000) + "M"
    }

    /// A credit amount the way the original draws it: the grouped number of
    /// `DrawContext_DrawGroupedUInt` 0x00465af0 ("850", "12,345", "1.23M" —
    /// the millions truncated, not rounded), then " " and STR# 2002 #34.
    /// Used everywhere the UI shows a credit amount so every screen agrees.
    var creditsAbbreviated: String {
        NovaNumberFormat.grouped(self) + " " + CreditsFormatting.suffix
    }
}
