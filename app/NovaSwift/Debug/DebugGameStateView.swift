import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// The debug suite's **game-state editor**: a form for poking the live pilot and
/// world directly — credits, fuel, ship health, the galaxy date, government
/// relations, mission control bits, the current hull, installed outfits, and
/// spawning enemies. Presented as a sheet from `DebugSuiteView`.
///
/// Two kinds of edit live here. Persistent pilot state (credits, outfits, hull,
/// date, relations, bits) is written straight to `PlayerState` and saved, so it
/// sticks. Live-world state (ship shield/armor/fuel, spawned enemies, the
/// on-the-spot hostility flip) is pushed into the running `GameScene` so it
/// takes effect this instant. Where a persistent edit only re-reads on the next
/// ship rebuild (hull swap, outfit changes), the form says so.
struct DebugGameStateView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @ObservedObject var debug: DebugController
    @Environment(\.dismiss) private var dismiss

    /// The live player ship, when a scene is up (for health/fuel edits).
    private var liveShip: Ship? { debug.scene?.playerShip }
    private var game: NovaGame? { model.data.game }

    var body: some View {
        NavigationStack {
            Form {
                pilotSection
                cheatsSection
                shipSection
                healthSection
                fleetSection
                timeSection
                relationsSection
                missionBitsSection
                outfitsSection
                spawnSection
            }
            .formStyle(.grouped)
            .navigationTitle("Game State")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Pilot — credits / combat rating

    private var pilotSection: some View {
        Section("Pilot") {
            LabeledContent("Credits") {
                TextField("Credits", value: pilotBinding(\.credits), format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            HStack {
                quickButton("+10k")  { addCredits(10_000) }
                quickButton("+100k") { addCredits(100_000) }
                quickButton("+1M")   { addCredits(1_000_000) }
                quickButton("Zero", role: .destructive) { pilot.state.credits = 0; pilot.save() }
            }
            Stepper("Combat rating: \(pilot.state.combatRating)",
                    value: pilotBinding(\.combatRating), in: 0...1_000_000, step: 100)
        }
    }

    // MARK: Ship — current hull

    private var shipSection: some View {
        Section {
            NavigationLink {
                DebugShipPicker()
            } label: {
                LabeledContent("Current ship") {
                    Text(shipName(pilot.state.shipType)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Ship")
        } footer: {
            Text("Hull and outfit changes apply the next time the ship is rebuilt (takeoff, jump, or landing/departure).")
        }
    }

    // MARK: Health — shield / armor / fuel (live)

    @ViewBuilder
    private var healthSection: some View {
        Section {
            if let ship = liveShip {
                fractionSlider("Shield", current: ship.maxShield > 0 ? ship.shield / ship.maxShield : 0) { frac in
                    ship.shield = frac * ship.maxShield
                }
                fractionSlider("Armor (hull)", current: ship.maxArmor > 0 ? ship.armor / ship.maxArmor : 0) { frac in
                    ship.armor = frac * ship.maxArmor
                }
                fractionSlider("Fuel", current: ship.maxFuel > 0 ? ship.fuel / ship.maxFuel : 0) { frac in
                    ship.fuel = frac * ship.maxFuel
                    pilot.state.fuel = ship.fuel     // persist so it survives a rebuild
                    pilot.save()
                }
                HStack {
                    quickButton("Full heal") {
                        ship.shield = ship.maxShield; ship.armor = ship.maxArmor
                    }
                    quickButton("Refuel") {
                        ship.fuel = ship.maxFuel
                        pilot.state.fuel = ship.maxFuel; pilot.save()
                    }
                    quickButton("Damage", role: .destructive) {
                        ship.shield = 0; ship.armor = max(1, ship.maxArmor * 0.1)
                    }
                }
            } else {
                Text("No live ship — enter the game to edit shield / armor / fuel.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ship Health")
        } footer: {
            Text("Shield, armor and fuel act on the ship you're flying right now.")
        }
    }

    // MARK: Cheats — live player toggles

    private var cheatsSection: some View {
        Section {
            Toggle(isOn: $debug.godMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("God mode")
                    Text("Player takes no damage; shields & armor stay full.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $debug.infiniteFuel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Infinite fuel")
                    Text("Fuel tank stays full — afterburner and jumps never drain it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Cheats")
        } footer: {
            Text(liveShip == nil
                 ? "Toggles take effect the moment you're flying."
                 : "Enforced every frame on the ship you're flying now.")
        }
    }

    // MARK: Fleet & escorts (live)

    @ViewBuilder
    private var fleetSection: some View {
        Section {
            if debug.scene?.playerShip != nil {
                LabeledContent("In system") {
                    Text("\(debug.scene?.liveEscortCount ?? 0) escorts · \(debug.scene?.liveHostileCount ?? 0) hostile")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Stepper("Escorts to add: \(escortCount)", value: $escortCount, in: 1...12)
                Button {
                    let n = debug.scene?.debugSpawnEscorts(count: escortCount) ?? 0
                    model.audio.play(.uiSelect)
                    fleetResult = "Recruited \(n) escort\(n == 1 ? "" : "s")."
                } label: {
                    Label("Add \(escortCount) Escorts", systemImage: "person.2.fill")
                }
                NavigationLink {
                    DebugFleetSpawnPicker(debug: debug)
                } label: {
                    Label("Spawn specific ship…", systemImage: "plus.viewfinder")
                }
                HStack {
                    quickButton("Disable hostiles") {
                        let n = debug.scene?.debugDisableAllHostiles() ?? 0
                        fleetResult = "Disabled \(n) ship\(n == 1 ? "" : "s")."
                    }
                    quickButton("Destroy hostiles", role: .destructive) {
                        let n = debug.scene?.debugDestroyAllHostiles() ?? 0
                        fleetResult = "Destroyed \(n) ship\(n == 1 ? "" : "s")."
                    }
                }
                quickButton("Clear all NPCs", role: .destructive) {
                    let n = debug.scene?.debugClearAllNPCs() ?? 0
                    fleetResult = "Cleared \(n) ship\(n == 1 ? "" : "s")."
                }
                if let fleetResult {
                    Text(fleetResult).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No live scene — enter the game to manage the fleet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Fleet & Escorts")
        } footer: {
            Text("Escorts join your wing and defend you. Disable leaves boardable hulks; destroy and clear remove ships outright.")
        }
    }

    // MARK: Time — galaxy date

    private var timeSection: some View {
        Section {
            Stepper("Day: \(pilot.state.date.day)",     value: dateComponent(\.day),   in: 1...31)
            Stepper("Month: \(pilot.state.date.month)", value: dateComponent(\.month), in: 1...12)
            Stepper("Year: \(pilot.state.date.year)",   value: dateComponent(\.year),  in: 0...9999)
            HStack {
                quickButton("+1 day")   { advanceDate(days: 1) }
                quickButton("+30 days") { advanceDate(days: 30) }
                quickButton("+1 year")  { advanceDate(days: 365) }
            }
            LabeledContent("Date", value: pilot.state.date.description)
        } header: {
            Text("Galaxy Date")
        } footer: {
            Text("EV Nova tracks whole days only — there is no time-of-day clock.")
        }
    }

    // MARK: Relations

    private var relationsSection: some View {
        Section {
            NavigationLink {
                DebugRelationsView(debug: debug)
            } label: {
                LabeledContent("Government relations") {
                    Text("\(pilot.state.legalRecord.count) set").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Relations")
        }
    }

    // MARK: Mission control bits (NCB)

    private var missionBitsSection: some View {
        Section {
            HStack {
                Text("Bit #")
                TextField("bit", value: $bitInput, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            HStack {
                quickButton("Set")    { pilot.state.setBit(bitInput); pilot.save() }
                quickButton("Clear")  { pilot.state.clearBit(bitInput); pilot.save() }
                quickButton("Toggle") { pilot.state.toggleBit(bitInput); pilot.save() }
            }
            if pilot.state.setBits.isEmpty {
                Text("No control bits set.").foregroundStyle(.secondary)
            } else {
                ForEach(pilot.state.setBits.sorted(), id: \.self) { bit in
                    HStack {
                        Text("Bit \(bit)").monospacedDigit()
                        Spacer()
                        Button(role: .destructive) {
                            pilot.state.clearBit(bit); pilot.save()
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Mission Control Bits")
        } footer: {
            Text("The NCB bit vector missions and crons test against. Setting a bit can unlock or complete story steps.")
        }
    }

    // MARK: Outfits

    private var outfitsSection: some View {
        Section {
            NavigationLink {
                DebugOutfitsView()
            } label: {
                LabeledContent("Installed outfits") {
                    Text("\(pilot.state.outfits.values.reduce(0, +)) items")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Outfits")
        }
    }

    // MARK: Spawn enemies

    private var spawnSection: some View {
        Section {
            Stepper("Count: \(spawnCount)", value: $spawnCount, in: 1...50)
            Button {
                let n = debug.scene?.debugSpawnHostiles(count: spawnCount) ?? 0
                model.audio.play(.uiSelect)
                spawnResult = n > 0 ? "Spawned \(n) attackers." : "No live scene / no ship data."
            } label: {
                Label("Spawn \(spawnCount) Attackers", systemImage: "exclamationmark.triangle.fill")
            }
            if let spawnResult {
                Text(spawnResult).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Spawn Enemies")
        } footer: {
            Text("Drops armed ships around you, already locked on and hostile. Needs an active flight session.")
        }
    }

    // MARK: Local editor state

    @State private var bitInput: Int = 1000
    @State private var spawnCount: Int = 5
    @State private var spawnResult: String?
    @State private var escortCount: Int = 2
    @State private var fleetResult: String?

    // MARK: Helpers

    /// A binding into the live `PlayerState` that saves on every write.
    private func pilotBinding<T>(_ kp: WritableKeyPath<PlayerState, T>) -> Binding<T> {
        Binding(
            get: { pilot.state[keyPath: kp] },
            set: { pilot.state[keyPath: kp] = $0; pilot.save() }
        )
    }

    /// A stepper binding for one component of the galaxy date.
    private func dateComponent(_ kp: WritableKeyPath<GameDate, Int>) -> Binding<Int> {
        Binding(
            get: { pilot.state.date[keyPath: kp] },
            set: { pilot.state.date[keyPath: kp] = $0; pilot.save() }
        )
    }

    private func advanceDate(days: Int) {
        pilot.state.date = pilot.state.date.adding(days: days)
        pilot.save()
    }

    private func addCredits(_ n: Int) {
        pilot.state.credits = max(0, pilot.state.credits + n)
        pilot.save()
    }

    private func shipName(_ id: Int) -> String {
        game?.ship(id)?.displayName ?? "Ship #\(id)"
    }

    /// A 0–100% slider that reports its fraction back on change. Seeds itself
    /// from `current` when the row appears.
    private func fractionSlider(_ label: String, current: Double,
                                _ apply: @escaping (Double) -> Void) -> some View {
        FractionSlider(label: label, initial: current, apply: apply)
    }

    private func quickButton(_ title: String, role: ButtonRole? = nil,
                             _ action: @escaping () -> Void) -> some View {
        Button(role: role) { action() } label: {
            Text(title).font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

/// A self-contained 0–100% slider with a live percentage read-out, seeded once
/// from the value it's editing. Used for the ship health/fuel rows so dragging
/// pushes the fraction straight into the live ship.
private struct FractionSlider: View {
    let label: String
    let initial: Double
    let apply: (Double) -> Void
    @State private var value: Double = 0
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value * 100))%").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: 0...1) { editing in
                if !editing { apply(value) }
            }
            .onChange(of: value) { _, v in apply(v) }
        }
        .onAppear {
            if !seeded { value = min(1, max(0, initial)); seeded = true }
        }
    }
}

// MARK: - Current-ship picker

/// Pick the pilot's current hull from every `shïp` in the data.
private struct DebugShipPicker: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @State private var query = ""

    private var ships: [ShipRes] {
        let all = (model.data.game?.ships() ?? []).sorted { $0.displayName < $1.displayName }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(ships, id: \.id) { ship in
            Button {
                pilot.state.shipType = ship.id
                pilot.state.shipName = ship.displayName
                pilot.save()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(ship.displayName)
                        Text("#\(ship.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ship.id == pilot.state.shipType {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Set Ship")
    }
}

// MARK: - Fleet spawn picker

/// Pick any hull and drop it into the live world with a chosen disposition —
/// hostile (attacks you), escort (joins your wing), or neutral traffic.
private struct DebugFleetSpawnPicker: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var debug: DebugController
    @State private var query = ""
    @State private var note: String?

    private var ships: [ShipRes] {
        let all = (model.data.game?.ships() ?? []).sorted { $0.displayName < $1.displayName }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let note {
                Section { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(ships, id: \.id) { ship in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(ship.displayName)
                        Spacer()
                        Text("#\(ship.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        spawnButton("Hostile", ship.id, .hostile, role: .destructive)
                        spawnButton("Escort", ship.id, .escort)
                        spawnButton("Neutral", ship.id, .neutral)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .searchable(text: $query)
        .navigationTitle("Spawn Ship")
    }

    private func spawnButton(_ title: String, _ hull: Int,
                             _ disposition: GameScene.DebugDisposition,
                             role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            let ok = debug.scene?.debugSpawnShip(hull: hull, as: disposition) ?? false
            model.audio.play(.uiSelect)
            note = ok ? "Spawned \(title.lowercased()) ship #\(hull)."
                      : "Couldn't spawn #\(hull) (no live scene?)."
        } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Outfit add/remove

/// Add or remove any `oütf` from the pilot's inventory, plus bulk grant/strip.
private struct DebugOutfitsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @State private var query = ""

    private var outfits: [OutfRes] {
        let all = (model.data.game?.outfits() ?? []).sorted { $0.displayName < $1.displayName }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        for o in (model.data.game?.outfits() ?? []) where (pilot.state.outfits[o.id] ?? 0) == 0 {
                            pilot.state.grantOutfit(o.id)
                        }
                        pilot.save()
                    } label: {
                        Label("Grant one of each", systemImage: "square.stack.3d.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        pilot.state.outfits = [:]; pilot.save()
                    } label: {
                        Label("Strip all", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                Text("Bulk changes apply on the next ship rebuild (takeoff, jump, or departure).")
            }
            Section {
                ForEach(outfits, id: \.id) { outfit in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(outfit.displayName)
                            Text("#\(outfit.id)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("\(pilot.state.outfits[outfit.id] ?? 0)",
                                onIncrement: { pilot.state.grantOutfit(outfit.id); pilot.save() },
                                onDecrement: { pilot.state.removeOutfit(outfit.id); pilot.save() })
                            .labelsHidden()
                        Text("×\(pilot.state.outfits[outfit.id] ?? 0)")
                            .monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Outfits")
    }
}

// MARK: - Relations editor

/// Set the player's standing with each government — persisted to `legalRecord`
/// and pushed live so ships react at once.
private struct DebugRelationsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pilot: PilotStore
    @ObservedObject var debug: DebugController
    @State private var query = ""

    private var govts: [GovtRes] {
        let all = (model.data.game?.govts() ?? []).sorted { $0.name < $1.name }
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(govts, id: \.id) { govt in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(govt.name.isEmpty ? "Govt #\(govt.id)" : govt.name)
                    Spacer()
                    Text("\(pilot.state.legalRecord[govt.id] ?? 0)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    presetButton("Hostile", -30_000, for: govt.id, role: .destructive)
                    presetButton("Neutral", 0, for: govt.id)
                    presetButton("Friendly", 30_000, for: govt.id)
                }
            }
            .padding(.vertical, 2)
        }
        .searchable(text: $query)
        .navigationTitle("Relations")
    }

    private func presetButton(_ title: String, _ value: Int, for govt: Int,
                              role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            pilot.state.legalRecord[govt] = value
            pilot.save()
            debug.scene?.debugSetLiveRelation(govt: govt, record: value)
        } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
