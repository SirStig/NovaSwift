import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The debug suite's **diagnostics** panel: an in-app self-test battery that
/// exercises the loaded data set, the current pilot, and the live world and
/// reports pass / warn / fail for each check. It's the "automated tests you can
/// run on the device" surface — a fast integrity sweep for catching a broken
/// plug-in merge, a dangling nav link, a hull with no sprite, or a player ship
/// that can't move, without attaching a debugger or reading the console.
///
/// Every check is a pure function over `NovaGame` + `PlayerState` + an optional
/// live `Ship`, collected in `DebugDiagnostics.run`. Adding a check is one entry
/// there; the view just renders whatever comes back, grouped by section.
struct DebugDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @ObservedObject var debug: DebugController
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [DiagnosticSection] = []
    @State private var hasRun = false

    private let green = Color(red: 0.35, green: 0.95, blue: 0.5)

    var body: some View {
        NavigationStack {
            List {
                if hasRun {
                    summaryRow
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.results) { result in
                                resultRow(result)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Runs a battery of integrity and sanity checks over the loaded data set, the current pilot, and the live flight session. Nothing here changes game state.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasRun ? "Re-run" : "Run") { run() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !hasRun { run() } }
    }

    private func run() {
        model.audio.play(.uiSelect)
        sections = DebugDiagnostics.run(game: model.data.game,
                                        pilot: pilot.state,
                                        liveShip: debug.scene?.playerShip,
                                        liveHostiles: debug.scene?.liveHostileCount)
        hasRun = true
    }

    // MARK: Rows

    private var summaryRow: some View {
        let all = sections.flatMap(\.results)
        let fails = all.filter { $0.status == .fail }.count
        let warns = all.filter { $0.status == .warn }.count
        let passes = all.filter { $0.status == .pass }.count
        return Section {
            HStack(spacing: 14) {
                summaryTile("\(passes)", "PASS", .green)
                summaryTile("\(warns)", "WARN", Color(red: 1.0, green: 0.75, blue: 0.3))
                summaryTile("\(fails)", "FAIL", Color(red: 0.95, green: 0.35, blue: 0.3))
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text(fails == 0 ? (warns == 0 ? "All checks passed" : "Passed with warnings")
                            : "\(fails) check\(fails == 1 ? "" : "s") failing")
        }
    }

    private func summaryTile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ result: DiagnosticResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.status.symbol)
                .foregroundStyle(result.status.color)
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                if let detail = result.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Result model

enum DiagnosticStatus {
    case pass, warn, fail

    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .pass: return Color(red: 0.35, green: 0.95, blue: 0.5)
        case .warn: return Color(red: 1.0, green: 0.75, blue: 0.3)
        case .fail: return Color(red: 0.95, green: 0.35, blue: 0.3)
        }
    }
}

struct DiagnosticResult: Identifiable {
    let id = UUID()
    let name: String
    let status: DiagnosticStatus
    let detail: String?
}

struct DiagnosticSection: Identifiable {
    let id = UUID()
    let title: String
    let results: [DiagnosticResult]
}

// MARK: - The check battery

/// The pure test battery behind `DebugDiagnosticsView`. Every check reads state
/// and reports; none of them mutate anything, so running diagnostics is always
/// safe mid-session. New checks slot into the relevant section builder.
enum DebugDiagnostics {

    static func run(game: NovaGame?, pilot: PlayerState,
                    liveShip: Ship?, liveHostiles: Int?) -> [DiagnosticSection] {
        guard let game else {
            return [DiagnosticSection(title: "Data Set", results: [
                DiagnosticResult(name: "Data set loaded", status: .fail,
                                 detail: "No NovaGame — the base data hasn't loaded. Import a data set first.")
            ])]
        }
        return [
            dataSetSection(game),
            pilotSection(game, pilot),
            liveWorldSection(liveShip, hostiles: liveHostiles),
        ]
    }

    // MARK: Data set integrity

    private static func dataSetSection(_ game: NovaGame) -> DiagnosticSection {
        var out: [DiagnosticResult] = []

        let ships = game.ships()
        let outfits = game.outfits()
        let weapons = game.weapons()
        let systems = game.systems()
        let spobs = game.spobs()
        let missions = game.missions()

        out.append(countCheck("Ships defined", ships.count))
        out.append(countCheck("Outfits defined", outfits.count))
        out.append(countCheck("Weapons defined", weapons.count))
        out.append(countCheck("Systems defined", systems.count))
        out.append(countCheck("Stellar objects defined", spobs.count))
        out.append(missions.isEmpty
            ? DiagnosticResult(name: "Missions defined", status: .warn,
                               detail: "No mïsn resources — story content won't run.")
            : countCheck("Missions defined", missions.count))

        // Nav-link integrity: every syst→syst link must resolve.
        let systemIDs = Set(systems.map(\.id))
        let dangling = systems.flatMap { sys in
            sys.links.filter { !systemIDs.contains($0) }.map { (sys.id, $0) }
        }
        out.append(dangling.isEmpty
            ? DiagnosticResult(name: "Hyperspace links resolve", status: .pass,
                               detail: "All nav links point at real systems.")
            : DiagnosticResult(name: "Hyperspace links resolve", status: .fail,
                               detail: "\(dangling.count) link(s) point at missing systems, e.g. system #\(dangling[0].0) → #\(dangling[0].1)."))

        // Every system's stellar objects must resolve.
        let spobIDs = Set(spobs.map(\.id))
        let danglingSpobs = systems.flatMap { sys in
            sys.spobs.filter { !spobIDs.contains($0) }.map { (sys.id, $0) }
        }
        out.append(danglingSpobs.isEmpty
            ? DiagnosticResult(name: "System stellar objects resolve", status: .pass, detail: nil)
            : DiagnosticResult(name: "System stellar objects resolve", status: .fail,
                               detail: "\(danglingSpobs.count) reference(s) to missing spöbs, e.g. system #\(danglingSpobs[0].0) → #\(danglingSpobs[0].1)."))

        // Every hull needs a matching shän sprite (same id) to draw.
        let missingSprites = ships.filter { game.shan($0.id) == nil }
        out.append(missingSprites.isEmpty
            ? DiagnosticResult(name: "Ship sprites present", status: .pass,
                               detail: "Every hull has a shän sprite.")
            : DiagnosticResult(name: "Ship sprites present", status: .warn,
                               detail: "\(missingSprites.count) hull(s) have no shän, e.g. \"\(missingSprites[0].displayName)\" (#\(missingSprites[0].id)) — they'd render blank."))

        // Orphan systems (no links in or out) are usually a data mistake.
        let orphaned = systems.filter { $0.links.isEmpty }
        out.append(orphaned.isEmpty
            ? DiagnosticResult(name: "Systems reachable", status: .pass, detail: nil)
            : DiagnosticResult(name: "Systems reachable", status: .warn,
                               detail: "\(orphaned.count) system(s) have no hyperspace links, e.g. \"\(orphaned[0].name)\" (#\(orphaned[0].id))."))

        return DiagnosticSection(title: "Data Set", results: out)
    }

    // MARK: Pilot state

    private static func pilotSection(_ game: NovaGame, _ pilot: PlayerState) -> DiagnosticSection {
        var out: [DiagnosticResult] = []

        // Current hull must be a real ship.
        if let ship = game.ship(pilot.shipType) {
            out.append(DiagnosticResult(name: "Current hull valid", status: .pass,
                                        detail: "\(ship.displayName) (#\(ship.id))."))
        } else {
            out.append(DiagnosticResult(name: "Current hull valid", status: .fail,
                                        detail: "Pilot's shipType #\(pilot.shipType) has no matching shïp."))
        }

        // Owned outfits must all resolve.
        let badOutfits = pilot.outfits.keys.filter { game.outfit($0) == nil }
        out.append(badOutfits.isEmpty
            ? DiagnosticResult(name: "Owned outfits valid", status: .pass,
                               detail: "\(pilot.outfits.values.reduce(0, +)) item(s), all resolving.")
            : DiagnosticResult(name: "Owned outfits valid", status: .fail,
                               detail: "\(badOutfits.count) owned outfit id(s) have no oütf, e.g. #\(badOutfits.first!)."))

        // Credits sanity.
        out.append(pilot.credits >= 0
            ? DiagnosticResult(name: "Credits non-negative", status: .pass,
                               detail: "\(pilot.credits) cr.")
            : DiagnosticResult(name: "Credits non-negative", status: .fail,
                               detail: "Credits are negative (\(pilot.credits))."))

        // Date sanity.
        let d = pilot.date
        let dateOK = (1...31).contains(d.day) && (1...12).contains(d.month) && d.year >= 0
        out.append(dateOK
            ? DiagnosticResult(name: "Galaxy date valid", status: .pass, detail: d.description)
            : DiagnosticResult(name: "Galaxy date valid", status: .warn,
                               detail: "Out-of-range date components: \(d.description)."))

        return DiagnosticSection(title: "Pilot", results: out)
    }

    // MARK: Live world

    private static func liveWorldSection(_ ship: Ship?, hostiles: Int?) -> DiagnosticSection {
        guard let ship else {
            return DiagnosticSection(title: "Live World", results: [
                DiagnosticResult(name: "Flight session active", status: .warn,
                                 detail: "No live scene — enter the game to run live-world checks.")
            ])
        }
        var out: [DiagnosticResult] = []

        out.append(DiagnosticResult(name: "Flight session active", status: .pass,
                                    detail: "Player ship built and flying."))

        out.append(ship.isAlive
            ? DiagnosticResult(name: "Player ship alive", status: .pass, detail: nil)
            : DiagnosticResult(name: "Player ship alive", status: .warn,
                               detail: "Player armor is at 0 — destroyed or mid-respawn."))

        out.append(ship.stats.maxSpeed > 0
            ? DiagnosticResult(name: "Player can move", status: .pass,
                               detail: "Max speed \(Int(ship.stats.maxSpeed)), accel \(Int(ship.stats.acceleration)).")
            : DiagnosticResult(name: "Player can move", status: .fail,
                               detail: "Max speed is 0 — the ship can't fly (bad hull stats?)."))

        out.append(ship.maxShield + ship.maxArmor > 0
            ? DiagnosticResult(name: "Player has health", status: .pass,
                               detail: "Shield \(Int(ship.maxShield)) / armor \(Int(ship.maxArmor)).")
            : DiagnosticResult(name: "Player has health", status: .fail,
                               detail: "Both max shield and max armor are 0."))

        out.append(!ship.weapons.isEmpty
            ? DiagnosticResult(name: "Player armed", status: .pass,
                               detail: "\(ship.weapons.count) weapon mount(s) fitted.")
            : DiagnosticResult(name: "Player armed", status: .warn,
                               detail: "No weapons fitted — combat checks can't fire."))

        if let hostiles {
            out.append(DiagnosticResult(name: "Live hostiles", status: .pass,
                                        detail: "\(hostiles) hostile ship(s) in system."))
        }

        return DiagnosticSection(title: "Live World", results: out)
    }

    // MARK: Helpers

    private static func countCheck(_ name: String, _ count: Int) -> DiagnosticResult {
        count > 0
            ? DiagnosticResult(name: name, status: .pass, detail: "\(count) defined.")
            : DiagnosticResult(name: name, status: .fail, detail: "None found.")
    }
}
