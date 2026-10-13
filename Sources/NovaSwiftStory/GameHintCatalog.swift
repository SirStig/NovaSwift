import Foundation

/// A one-time, contextual in-game hint — an inline, dismissible tip shown the
/// first time the player reaches a moment that benefits from a nudge (their first
/// landing, first look at the Mission BBS, and so on). Shared by the Apple app
/// (`GameHints.swift`) and the Godot frontend.
public struct NovaHint: Identifiable, Equatable, Sendable {
    /// Stable id — also the persistence key suffix, so it must never change once
    /// shipped or the hint would re-appear for players who've already seen it.
    public let id: String
    public let title: String
    public let systemImage: String
    public let message: String

    public init(id: String, title: String, systemImage: String, message: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }
}

/// The catalog of contextual hints, and the rule for when one shows.
public enum NovaHints {
    public static let spaceportServices = NovaHint(
        id: "spaceport.services", title: "Welcome to the spaceport",
        systemImage: "building.2.fill",
        message: "Visit the Mission BBS and the Bar to find jobs and meet people, the Trade Center to buy and sell cargo, and the Outfitter or Shipyard to upgrade your ship. Tap Leave to take off again.")

    public static let missionBBS = NovaHint(
        id: "missionBBS.howto", title: "Taking a job",
        systemImage: "list.bullet.rectangle.fill",
        message: "Select a listing to read its briefing, then Accept to take the job. Cargo and courier missions pay when you deliver — watch for any deadline.")

    public static let outfitter = NovaHint(
        id: "outfitter.howto", title: "Upgrading your ship",
        systemImage: "wrench.and.screwdriver.fill",
        message: "Outfits install permanently — afterburners, shields, weapons and cargo space. Some need free mass or a specific hull, so check the description before you buy.")

    public static let all: [NovaHint] = [spaceportServices, missionBBS, outfitter]

    /// The persistence key for hint `id` (UserDefaults on Apple, the prefs file on Godot).
    public static func storageKey(_ id: String) -> String { "novaswift.hint.\(id)" }

    /// Whether a hint banner is up: its context gate (`active`, which already folds
    /// in the "Tutorial hints" setting) is open, it hasn't been dismissed this
    /// visit, and it has never been seen before.
    public static func shouldShow(active: Bool, dismissed: Bool, seen: Bool) -> Bool {
        active && !dismissed && !seen
    }

    /// The hint to show for the docked screen `screen` ("hub", "bbs", "outfitter"), if any.
    public static func hint(forSpaceportScreen screen: String) -> NovaHint? {
        switch screen {
        case "hub": return spaceportServices
        case "bbs": return missionBBS
        case "outfitter": return outfitter
        default: return nil
        }
    }
}
