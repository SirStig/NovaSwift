import Foundation

extension Int {
    /// The credit balance in EV Nova's compact, abbreviated form — millions as
    /// "1.10M cr", large thousands as "12.4k cr", smaller amounts spelled out
    /// in full with grouping ("850 cr"). Used everywhere the UI shows a credit
    /// amount (HUD, Pilot Info, Shipyard/Outfitter/Trade Center, missions,
    /// gambling) so every screen agrees on one format instead of each re-deriving
    /// its own — and so a long full number never overflows a fixed-width field.
    var creditsAbbreviated: String {
        let n = self, a = abs(n)
        if a >= 1_000_000 { return String(format: "%.2fM cr", Double(n) / 1_000_000) }
        if a >= 10_000 { return String(format: "%.1fk cr", Double(n) / 1_000) }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}
