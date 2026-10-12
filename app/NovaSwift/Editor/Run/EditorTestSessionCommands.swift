#if os(macOS)
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The test run's console: the same command names the in-game dev console uses
/// (`god`, `fuel`, `spawn`, `ship`, `outfit`, `bit`, `date`, `select`, `destroy`,
/// `disable`, `capture`, `clearnpcs`, `killhostiles`, `heal`, `refuel`, `credits`,
/// `relation`, `fps`, `ai`), re-bound to the sandbox session instead of the
/// player's pilot — plus `jump`, `fleet`, `mission`, `timescale`, `pause`,
/// `freeze`, `eval`. Every closure goes through the same `EditorTestSession`
/// methods the panel buttons call, so there is one execution path.
extension EditorTestSession {

    func registerCommands() {
        typealias Err = ConsoleController.CommandError
        func onOff(_ args: [String], current: Bool) throws -> Bool {
            guard let raw = args.first else { return !current }
            switch raw.lowercased() {
            case "on", "true", "1": return true
            case "off", "false", "0": return false
            default: throw Err(message: "Expected on/off, got '\(raw)'")
            }
        }
        func resolve(_ picks: [EditorPick], _ words: [String], what: String) throws -> Int {
            guard !words.isEmpty else { throw Err(message: "Missing \(what) id or name.") }
            if words.count == 1, let id = Int(words[0]) { return id }
            let q = words.joined(separator: " ").lowercased()
            let hits = picks.filter { $0.title.lowercased().contains(q) }
            if hits.count == 1 { return hits[0].id }
            if hits.isEmpty { throw Err(message: "No \(what) matching '\(q)'.") }
            throw Err(message: "Ambiguous — " + hits.prefix(8).map { "#\($0.id) \($0.title)" }.joined(separator: ", "))
        }
        func stance(_ s: String) throws -> Stance {
            switch s.lowercased() {
            case "hostile": return .hostile
            case "neutral": return .neutral
            case "friendly", "escort": return .friendly
            default: throw Err(message: "Expected hostile/neutral/friendly, got '\(s)'")
            }
        }
        let c = console

        c.register(.init(name: "god", summary: "Toggle god mode.", usage: "god [on|off]") { [unowned self] a in
            setGod(try onOff(a, current: debug.godMode)); return "God mode: \(debug.godMode ? "on" : "off")"
        })
        c.register(.init(name: "fuel", summary: "Toggle infinite fuel.", usage: "fuel [on|off]") { [unowned self] a in
            setInfiniteFuel(try onOff(a, current: debug.infiniteFuel)); return "Infinite fuel: \(debug.infiniteFuel ? "on" : "off")"
        })
        c.register(.init(name: "ai", summary: "Toggle the AI state/paths overlay.", usage: "ai [on|off]") { [unowned self] a in
            debug.aiDebugEnabled = try onOff(a, current: debug.aiDebugEnabled); return "AI overlay: \(debug.aiDebugEnabled ? "on" : "off")"
        })
        c.register(.init(name: "freeze", summary: "Freeze/unfreeze all NPC AI and ambient spawning.", usage: "freeze [on|off]") { [unowned self] a in
            setAIFrozen(try onOff(a, current: aiFrozen)); return "AI frozen: \(aiFrozen ? "on" : "off")"
        })
        c.register(.init(name: "heal", summary: "Full shield + armor.", usage: "heal") { [unowned self] _ in heal(); return "Healed." })
        c.register(.init(name: "refuel", summary: "Fill the fuel tank.", usage: "refuel") { [unowned self] _ in refuel(); return "Refueled." })
        c.register(.init(name: "credits", summary: "Add or set sandbox credits.", usage: "credits <add|set> <amount>") { [unowned self] a in
            guard a.count == 2, let n = Int(a[1]) else { throw Err(message: "Usage: credits <add|set> <amount>") }
            switch a[0].lowercased() {
            case "add": setCredits(n, add: true)
            case "set": setCredits(n, add: false)
            default: throw Err(message: "Expected add/set")
            }
            return "Credits: \(pilot.state.credits)"
        })
        c.register(.init(name: "spawn", summary: "Spawn ships (id or name) near the player.",
                         usage: "spawn <hostile|neutral|friendly> <shipID|name…> [count]") { [unowned self] a in
            guard a.count >= 2 else { throw Err(message: "Usage: spawn <hostile|neutral|friendly> <shipID|name…> [count]") }
            let st = try stance(a[0])
            var rest = Array(a.dropFirst())
            var count = 1
            if rest.count >= 2, let n = Int(rest.last!), Int(rest[0]) != nil || rest.count > 2 { count = n; rest.removeLast() }
            let hull = try resolve(shipPicks, rest, what: "ship")
            let n = spawnShips(hull: hull, count: count, stance: st, govt: nil, placement: .nearPlayer)
            return n > 0 ? "Spawned \(n) × #\(hull) \(shipName(hull)) (\(a[0]))." : "Couldn't spawn #\(hull)."
        })
        c.register(.init(name: "fleet", summary: "Spawn a flët.", usage: "fleet <hostile|neutral|friendly> <fleetID|name…>") { [unowned self] a in
            guard a.count >= 2 else { throw Err(message: "Usage: fleet <hostile|neutral|friendly> <fleetID|name…>") }
            let id = try resolve(fleetPicks, Array(a.dropFirst()), what: "fleet")
            let n = spawnFleet(id, stance: try stance(a[0]), placement: .nearPlayer)
            return n > 0 ? "Spawned fleet #\(id) (\(n) ships)." : "Couldn't spawn fleet #\(id)."
        })
        c.register(.init(name: "ship", summary: "Swap the player's hull (rebuilds the ship).", usage: "ship <id|name…>") { [unowned self] a in
            let id = try resolve(shipPicks, a, what: "ship")
            guard game?.ship(id) != nil else { throw Err(message: "No ship #\(id).") }
            setShip(id); return "Hull set to #\(id) \(shipName(id))."
        })
        c.register(.init(name: "outfit", summary: "Give or remove an outfit.", usage: "outfit <add|remove> <outfitID> [count]") { [unowned self] a in
            guard a.count >= 2, let id = Int(a[1]) else { throw Err(message: "Usage: outfit <add|remove> <outfitID> [count]") }
            let n = max(1, a.dropFirst(2).first.flatMap(Int.init) ?? 1)
            guard game?.outfit(id) != nil else { throw Err(message: "No outfit #\(id).") }
            switch a[0].lowercased() {
            case "add": giveOutfit(id, count: n)
            case "remove": removeOutfit(id, count: n)
            default: throw Err(message: "Expected add/remove")
            }
            return "Outfit #\(id): now ×\(pilot.state.outfits[id] ?? 0) (ship rebuilding)."
        })
        c.register(.init(name: "bit", summary: "Set/clear/toggle a control bit.", usage: "bit <set|clear|toggle> <n>") { [unowned self] a in
            guard a.count == 2, let n = Int(a[1]), ["set", "clear", "toggle"].contains(a[0].lowercased()) else {
                throw Err(message: "Usage: bit <set|clear|toggle> <n>")
            }
            setBit(n, a[0].lowercased())
            return "Bit \(n): \(pilot.state.setBits.contains(n) ? "set" : "clear")"
        })
        c.register(.init(name: "eval", summary: "Evaluate an NCB test expression.", usage: "eval <expr>") { [unowned self] a in
            let expr = a.joined(separator: " ")
            return "\(expr) → \(evaluate(test: expr))"
        })
        c.register(.init(name: "date", summary: "Advance the date.", usage: "date +<days>") { [unowned self] a in
            guard let s = a.first, s.hasPrefix("+"), let d = Int(s.dropFirst()) else { throw Err(message: "Usage: date +<days>") }
            addDays(d); return "Date: \(pilot.state.date.description)"
        })
        c.register(.init(name: "jump", summary: "Jump to any system (instant, in place).", usage: "jump <sysID|name…>") { [unowned self] a in
            let id = try resolve(systemPicks, a, what: "system")
            guard jump(to: id) else { throw Err(message: "Can't jump to #\(id) right now.") }
            return "Arrived in \(systemName(id))."
        })
        c.register(.init(name: "mission", summary: "Start a mission by id or name.", usage: "mission <id|name…>") { [unowned self] a in
            let id = try resolve(missionPicks, a, what: "mission")
            guard startMission(id) else { throw Err(message: "Mission #\(id) didn't start (unknown, or no free slot/cargo room).") }
            return "Started mission #\(id)."
        })
        c.register(.init(name: "timescale", summary: "Simulation speed (0.25–16).", usage: "timescale <x>") { [unowned self] a in
            guard let x = a.first.flatMap(Double.init), x >= 0.25, x <= 16 else { throw Err(message: "Usage: timescale <0.25…16>") }
            setTimeScale(x); return "Time scale: \(x)×"
        })
        c.register(.init(name: "pause", summary: "Pause/resume the simulation.", usage: "pause [on|off]") { [unowned self] a in
            setPaused(try onOff(a, current: paused)); return "Paused: \(paused ? "on" : "off")"
        })
        c.register(.init(name: "select", summary: "Select a live ship or stellar by id.", usage: "select <ship|spob> <id>") { [unowned self] a in
            guard a.count == 2, let id = Int(a[1]), let scene = host?.scene else { throw Err(message: "Usage: select <ship|spob> <id>") }
            switch a[0].lowercased() {
            case "ship":
                guard let s = scene.npc(id: id) else { throw Err(message: "No live ship #\(id).") }
                scene.debugSelect(.ship(id: id, name: s.name)); return "Selected ship #\(id) \(s.name)."
            case "spob":
                let name = game?.spob(id)?.name ?? ""
                scene.debugSelect(.spob(id: id, name: name)); return "Selected stellar #\(id) \(name)."
            default: throw Err(message: "Expected ship/spob")
            }
        })
        func shipTarget(_ a: [String]) throws -> Int {
            if let raw = a.first, raw.lowercased() != "selected", let id = Int(raw) { return id }
            if case let .ship(id, _)? = debug.selection { return id }
            throw Err(message: "No ship selected — pass an id or select one first.")
        }
        c.register(.init(name: "destroy", summary: "Kill a ship.", usage: "destroy <id|selected>") { [unowned self] a in
            let id = try shipTarget(a)
            guard host?.scene.debugDestroyShip(entityID: id) == true else { throw Err(message: "No live ship #\(id).") }
            return "Destroyed ship #\(id)."
        })
        c.register(.init(name: "disable", summary: "Disable a ship.", usage: "disable <id|selected>") { [unowned self] a in
            let id = try shipTarget(a)
            guard host?.scene.debugDisableShip(entityID: id) == true else { throw Err(message: "No live ship #\(id).") }
            return "Disabled ship #\(id)."
        })
        c.register(.init(name: "capture", summary: "Cheat-capture a ship as an escort.", usage: "capture <id|selected>") { [unowned self] a in
            let id = try shipTarget(a)
            host?.scene.debugSelect(.ship(id: id, name: ""))
            guard captureSelected() else { throw Err(message: "No live ship #\(id).") }
            return "Captured ship #\(id)."
        })
        c.register(.init(name: "conquer", summary: "Dominate a stellar (skips the defence fight).", usage: "conquer <spobID>") { [unowned self] a in
            guard let id = a.first.flatMap(Int.init), host?.scene.debugConquerStellar(spobID: id) == true else {
                throw Err(message: "Usage: conquer <spobID> (not already dominated)")
            }
            return "Dominated stellar #\(id)."
        })
        c.register(.init(name: "clearnpcs", summary: "Remove every NPC.", usage: "clearnpcs") { [unowned self] _ in "Cleared \(clearNPCs()) ship(s)." })
        c.register(.init(name: "killhostiles", summary: "Destroy every hostile.", usage: "killhostiles") { [unowned self] _ in "Destroyed \(killHostiles()) ship(s)." })
        c.register(.init(name: "relation", summary: "Set the legal record in this system.", usage: "relation <value>") { [unowned self] a in
            guard let v = a.first.flatMap(Int.init) else { throw Err(message: "Usage: relation <value>") }
            host?.scene.debugSetLiveReputation(SystemReputation.clamp(v)); return "Reputation set to \(SystemReputation.clamp(v))."
        })
        c.register(.init(name: "fps", summary: "Print the performance snapshot.", usage: "fps") { [unowned self] _ in
            String(format: "%.0f fps · frame %.1fms (worst %.1fms) · %d ships, %d shots, %d nodes · %.0f MB",
                   debug.fps, debug.frameMsAvg, debug.frameMsMax, debug.shipCount, debug.projectileCount, debug.nodeCount, debug.memoryMB)
        })
    }
}
#endif
