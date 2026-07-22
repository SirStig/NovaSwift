import Foundation

/// Random pilot-name suggestions for players who'd rather not type — the
/// dice button on the new-pilot dialog and the pad keyboard's suggestion
/// chips both draw from here. Names aim for EV Nova's register: ordinary
/// human first names against slightly space-opera surnames.
enum PilotNames {
    private static let first = [
        "Ace", "Adrian", "Alexis", "Aria", "Barnabas", "Cassia", "Cole",
        "Dana", "Dax", "Elena", "Ezra", "Farley", "Gideon", "Harper",
        "Imogen", "Jax", "Juno", "Kara", "Kestrel", "Lena", "Marcus",
        "Mira", "Nash", "Nova", "Orin", "Petra", "Quinn", "Rex",
        "Rhea", "Sable", "Silas", "Talia", "Torin", "Vega", "Wren", "Zane",
    ]

    private static let last = [
        "Archer", "Blackwood", "Calloway", "Crane", "Draven", "Falco",
        "Farrell", "Halloran", "Hawkins", "Holt", "Kane", "Kessler",
        "Locke", "Marlowe", "Mercer", "Nyx", "Oakes", "Pryor", "Quill",
        "Reyes", "Rourke", "Sterling", "Strand", "Tanner", "Thorne",
        "Vance", "Voss", "Ward", "Wilder", "Yates",
    ]

    /// A handful get a callsign instead of a plain first name — "Duke"
    /// Halloran reads more like a Bar regular than Duke Halloran does.
    private static let callsigns = [
        "Ajax", "Bishop", "Comet", "Duke", "Echo", "Flint", "Ghost",
        "Havoc", "Longshot", "Maverick", "Onyx", "Patch", "Razor",
        "Slipstream", "Spectre", "Vortex",
    ]

    static func random() -> String {
        if Int.random(in: 0..<5) == 0,
           let sign = callsigns.randomElement(), let surname = last.randomElement() {
            return "\"\(sign)\" \(surname)"
        }
        guard let given = first.randomElement(), let surname = last.randomElement() else {
            return "Captain"
        }
        return "\(given) \(surname)"
    }

    /// A batch of distinct suggestions (for the pad keyboard's chips).
    static func suggestions(_ count: Int = 4) -> [String] {
        var seen = Set<String>()
        while seen.count < count { seen.insert(random()) }
        return Array(seen)
    }
}
