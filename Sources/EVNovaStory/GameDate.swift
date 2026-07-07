import Foundation

/// The EV Nova galaxy clock: a day / month / year calendar date.
///
/// EV Nova tracks time in whole days on a Gregorian-style calendar (the default
/// campaign begins in the year 1177 of the "New Calendar"). Missions have day
/// deadlines and `crön` events fire inside day/month/year windows, so we need
/// both ordered comparison and "N days later" arithmetic. Both are provided by
/// converting to a linear **Julian Day Number** (JDN).
public struct GameDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var day: Int      // 1…31
    public var month: Int    // 1…12
    public var year: Int

    public init(day: Int, month: Int, year: Int) {
        self.day = day
        self.month = month
        self.year = year
    }

    /// EV Nova's default campaign start date (1 Jan 1177 NC).
    public static let defaultStart = GameDate(day: 1, month: 1, year: 1177)

    // MARK: Julian Day Number (proleptic Gregorian)

    /// Linear day index; lets us compare dates and add/subtract day counts.
    public var julianDay: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    public init(julianDay jdn: Int) {
        let a = jdn + 32044
        let b = (4 * a + 3) / 146097
        let c = a - (146097 * b) / 4
        let d = (4 * c + 3) / 1461
        let e = c - (1461 * d) / 4
        let m = (5 * e + 2) / 153
        day = e - (153 * m + 2) / 5 + 1
        month = m + 3 - 12 * (m / 10)
        year = 100 * b + d - 4800 + m / 10
    }

    /// The date `days` days after this one (negative moves backward).
    public func adding(days: Int) -> GameDate {
        GameDate(julianDay: julianDay + days)
    }

    /// Whole days from this date to `other` (positive if `other` is later).
    public func days(until other: GameDate) -> Int {
        other.julianDay - julianDay
    }

    public static func < (lhs: GameDate, rhs: GameDate) -> Bool {
        lhs.julianDay < rhs.julianDay
    }

    public var description: String {
        String(format: "%d/%02d/%04d", day, month, year)
    }
}
