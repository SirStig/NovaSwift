import Foundation
import NovaSwiftKit

/// The pilot-state half of the dev console's cheat commands (`credits`, `ship`, `outfit`,
/// `relation`, `bit`, `date`), as pure functions over `PlayerState` + `NovaGame`. The Godot dev
/// console registers these (the Apple app's equivalents are inline closures in
/// `GameContainerView.registerConsoleCommands`, which this mirrors line for line); a frontend
/// still owns persisting the pilot and syncing any live HUD afterwards.
public enum DebugPilotOps {
    public typealias CommandError = DebugConsole.CommandError

    /// `credits <add|set> <amount>`.
    public static func credits(_ args: [String], state: inout PlayerState) throws -> String {
        guard args.count == 2, let amount = Int(args[1]) else {
            throw CommandError(message: "Usage: credits <add|set> <amount>")
        }
        switch args[0].lowercased() {
        case "add": state.credits = max(0, state.credits + amount)
        case "set": state.credits = max(0, amount)
        default: throw CommandError(message: "Expected add/set, got '\(args[0])'")
        }
        return "Credits: \(state.credits)"
    }

    /// Resolves `ship <id|name…>` to a hull; ambiguity / no match throw with the Apple wording.
    public static func resolveShip(_ args: [String], game: NovaGame) throws -> ShipRes {
        guard !args.isEmpty else { throw CommandError(message: "Usage: ship <id|name…>") }
        let resolved: ShipRes?
        if args.count == 1, let id = Int(args[0]) {
            resolved = game.ship(id)
        } else {
            let query = args.joined(separator: " ")
            let matches = game.ships().filter { $0.displayName.localizedCaseInsensitiveContains(query) }
            if matches.count > 1 {
                let names = matches.prefix(8).map { "#\($0.id) \($0.displayName)" }.joined(separator: ", ")
                throw CommandError(message: "Ambiguous — matches: \(names)")
            }
            resolved = matches.first
        }
        guard let ship = resolved else {
            throw CommandError(message: "No ship matching '\(args.joined(separator: " "))'.")
        }
        return ship
    }

    /// `outfit <add|remove> <outfitID> [count]`.
    public static func outfit(_ args: [String], state: inout PlayerState, game: NovaGame) throws -> String {
        guard args.count >= 2, let id = Int(args[1]) else {
            throw CommandError(message: "Usage: outfit <add|remove> <outfitID> [count]")
        }
        let count = max(1, args.dropFirst(2).first.flatMap(Int.init) ?? 1)
        guard let outfit = game.outfit(id) else { throw CommandError(message: "No outfit #\(id).") }
        switch args[0].lowercased() {
        case "add": state.grantOutfit(id, count: count)
        case "remove": state.removeOutfit(id, count: count)
        default: throw CommandError(message: "Expected add/remove, got '\(args[0])'")
        }
        let owned = state.outfits[id] ?? 0
        return "\(outfit.outfitterDisplayName): now ×\(owned) — applies on next ship rebuild."
    }

    /// `relation <value>`: returns the clamped value written to the current system.
    public static func relation(_ args: [String], state: inout PlayerState) throws -> (value: Int, system: Int) {
        guard args.count == 1, let value = Int(args[0]) else {
            throw CommandError(message: "Usage: relation <value>")
        }
        let system = state.currentSystem
        let clamped = SystemReputation.clamp(value)
        state.systemReputation = (state.systemReputation ?? [:]).merging([system: clamped]) { _, new in new }
        return (clamped, system)
    }

    /// `bit <set|clear|toggle|info> <n>`; `info` needs the NCB cross-reference index.
    public static func bit(_ args: [String], state: inout PlayerState, index: NCBIndex) throws -> String {
        guard args.count == 2, let n = Int(args[1]) else {
            throw CommandError(message: "Usage: bit <set|clear|toggle|info> <n>")
        }
        switch args[0].lowercased() {
        case "set": state.setBit(n)
        case "clear": state.clearBit(n)
        case "toggle": state.toggleBit(n)
        case "info": return index.explain(bit: n, isSet: state.setBits.contains(n))
        default: throw CommandError(message: "Expected set/clear/toggle/info, got '\(args[0])'")
        }
        return "Bit \(n): \(state.setBits.contains(n) ? "set" : "clear")"
    }

    /// `date +<days>`.
    public static func date(_ args: [String], state: inout PlayerState) throws -> String {
        guard let arg = args.first, arg.hasPrefix("+"), let days = Int(arg.dropFirst()) else {
            throw CommandError(message: "Usage: date +<days>")
        }
        state.date = state.date.adding(days: days)
        return "Date: \(state.date.description)"
    }
}
