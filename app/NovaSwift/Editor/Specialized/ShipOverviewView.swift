#if os(macOS)
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// Animated, layer-composited hull view with a rotation dial and layer toggles.
/// Shared by the ship overview, the weapon range preview and the outfit before/after.
struct ShipStageView: View {
    let layers: ShipLayerSet?
    @Binding var heading: Int
    var autoSpin: Bool
    var toggles: ShipLayerToggles
    var zoom: CGFloat = 2
    /// Layer decode still running: show a spinner instead of "No hull sprite".
    var loading = false

    var body: some View {
        let animated = autoSpin || (layers?.shan.hasAltLayer ?? false)
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animated)) { tl in
            Canvas { ctx, size in
                guard let layers else { return }
                let h = autoSpin ? ShipCompositor.spinHeading(tl.date, headings: layers.headings) : heading % layers.headings
                ShipCompositor.draw(ctx, center: CGPoint(x: size.width / 2, y: size.height / 2), zoom: zoom,
                                    layers: layers, heading: h,
                                    altStep: ShipCompositor.altStep(tl.date, shan: layers.shan), toggles: toggles)
            }
        }
        .background { CheckerboardBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
        .overlay {
            if layers == nil && loading {
                ProgressView().controlSize(.regular).tint(novaAmber)
            } else if layers?.base == nil {
                Text("No hull sprite").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Layer toggles + rotation controls for a `ShipStageView`.
struct ShipStageControls: View {
    let layers: ShipLayerSet?
    @Binding var toggles: ShipLayerToggles
    @Binding var heading: Int
    @Binding var autoSpin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RotationDial(frames: layers?.headings ?? 36, frame: Binding(get: { heading }, set: { heading = $0; autoSpin = false }))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-spin", isOn: $autoSpin).toggleStyle(.switch).controlSize(.mini)
                    Text("\(Int(Double(heading) * 360 / Double(max(1, layers?.headings ?? 36))))° · frame \(heading)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let l = layers {
                VStack(alignment: .leading, spacing: 2) {
                    layerToggle("Base", $toggles.base, present: l.base != nil)
                    layerToggle("Alt (\(l.shan.altSetCount) sets)", $toggles.alt, present: l.alt != nil)
                    layerToggle("Engine glow", $toggles.engine, present: l.engine != nil)
                    layerToggle("Running lights", $toggles.lights, present: l.lights != nil)
                    layerToggle("Weapon glow", $toggles.weaponGlow, present: l.weaponGlow != nil)
                    layerToggle("Shield bubble", $toggles.shield, present: l.shield != nil)
                }
            }
        }
    }

    @ViewBuilder private func layerToggle(_ title: String, _ on: Binding<Bool>, present: Bool) -> some View {
        Toggle(isOn: on) {
            Text(present ? title : "\(title) (none)").font(.system(size: 11)).foregroundStyle(present ? Color.primary : Color.secondary)
        }
        .toggleStyle(.checkbox).controlSize(.small).disabled(!present)
    }
}

/// Loads the layer set for a `shän`/ship id, reloading when the edited data changes.
@MainActor
final class ShipLayersLoader: ObservableObject {
    @Published private(set) var layers: ShipLayerSet?
    /// True while a decode is in flight (the previous `layers`, if any, stay visible).
    @Published private(set) var isLoading = false
    private var token = 0

    func load(model: EditorModel, id: Int) async {
        token += 1
        let mine = token
        isLoading = true
        let data = SpecCache.data(model)
        let result = await ShipLayerCache.shared.load(data, id: id)
        if mine == token { layers = result; isLoading = false }
    }
}

// MARK: - Ship overview

struct ShipOverviewView: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey

    @StateObject private var loader = ShipLayersLoader()
    @State private var toggles = ShipLayerToggles()
    @State private var heading = 0
    @State private var autoSpin = true
    @State private var stats: ShipStatSheet?
    @State private var hull: ShipRes?
    @State private var sellers: [SpobRes] = []
    /// First result has landed (until then: skeleton, not "couldn't compute").
    @State private var loaded = false
    /// A newer result is being computed; the old numbers stay on screen.
    @State private var refreshing = false

    private struct TaskKey: Hashable { let key: ResourceKey; let revision: Int }
    private struct Computed { let stats: ShipStatSheet?; let hull: ShipRes?; let sellers: [SpobRes] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            if let s = stats, let h = hull {
                flightAndDefense(s, h)
                capacity(s, h)
                armament(s)
                defaultItems(s, h)
                identity(h)
                description
                availability
                usedBy
            } else if !loaded {
                SkeletonForm(groups: 3)
            } else {
                EditorEmptyState(icon: "airplane", title: "Couldn't compute this ship",
                                 subtitle: "The record is too short or malformed. Use Form or Raw.")
            }
        }
        .overlay(alignment: .top) { EditorRefreshStrip(active: refreshing) }
        .task(id: TaskKey(key: key, revision: model.dataRevision)) {
            // Stat recompute runs off-main; after inline edits wait ~200 ms so typing
            // bursts coalesce into one recompute and the old numbers stay put meanwhile.
            if loaded {
                refreshing = true
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            let id = key.id
            let r = await SpecCache.compute(model) { d -> Computed in
                let hull = d.game.ship(id)
                return Computed(stats: ShipStatSheet.compute(d, shipID: id), hull: hull,
                                sellers: hull.map { SpecAvailability.spobs(sellingShip: $0, game: d.game) } ?? [])
            }
            if Task.isCancelled { return }
            stats = r.stats; hull = r.hull; sellers = r.sellers
            loaded = true; refreshing = false
            await loader.load(model: model, id: key.id)
        }
    }

    // MARK: Sections

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ShipStageView(layers: loader.layers, heading: $heading, autoSpin: autoSpin, toggles: toggles, zoom: 2.5,
                          loading: loader.isLoading)
                .frame(width: 280, height: 280)
            VStack(alignment: .leading, spacing: 10) {
                ShipStageControls(layers: loader.layers, toggles: $toggles, heading: $heading, autoSpin: $autoSpin)
                Spacer(minLength: 0)
                Button {
                    model.testRunRequest = EditorTestRunRequest(ship: key.id)
                } label: { Label("Test fly", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(novaAmber).controlSize(.large)
                    .help("Open a test run flying this ship (⌘R runs the current selection too)")
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func flightAndDefense(_ s: ShipStatSheet, _ h: ShipRes) -> some View {
        SpecSection(title: "Flight & defense", trailing: "effective = hull + stock outfits") {
            VStack(spacing: 5) {
                InlineStat(model: model, key: key, field: "speed", label: "Top speed",
                           note: "\(SpecFormat.num(s.maxSpeed)) px/s")
                InlineStat(model: model, key: key, field: "acceleration", label: "Acceleration",
                           note: "\(SpecFormat.num(s.acceleration)) px/s²")
                InlineStat(model: model, key: key, field: "turnRate", label: "Turn rate",
                           note: "\(SpecFormat.num(s.turnDegPerSec)) °/s")
                Divider().opacity(0.4)
                InlineStat(model: model, key: key, field: "shield", label: "Shield",
                           note: "eff. \(SpecFormat.num(s.shield, 0))")
                InlineStat(model: model, key: key, field: "shieldRecharge", label: "Shield recharge",
                           note: "\(SpecFormat.num(s.shieldRecharge, 2))/s")
                InlineStat(model: model, key: key, field: "armor", label: "Armor",
                           note: "eff. \(SpecFormat.num(s.armor, 0))")
                InlineStat(model: model, key: key, field: "armorRecharge", label: "Armor recharge",
                           note: "\(SpecFormat.num(s.armorRecharge, 2))/s")
                StatRow(label: "Player turn step", value: "\(SpecFormat.num(s.playerTurnDegPerSec)) °/s",
                        note: "whole degrees per 1/30 s tick")
            }
        }
    }

    private func capacity(_ s: ShipStatSheet, _ h: ShipRes) -> some View {
        SpecSection(title: "Capacity & economy") {
            VStack(spacing: 5) {
                InlineStat(model: model, key: key, field: "freeMass", label: "Free mass",
                           note: "\(s.usedMass) t used by stock · \(s.freeMass) t free")
                InlineStat(model: model, key: key, field: "cargoSpace", label: "Cargo", note: "eff. \(s.cargo) t")
                InlineStat(model: model, key: key, field: "fuel", label: "Fuel",
                           note: "\(s.jumps) jump\(s.jumps == 1 ? "" : "s") (100 = 1)")
                InlineStat(model: model, key: key, field: "maxGuns", label: "Gun mounts",
                           note: "eff. \(s.maxGuns) · \(s.usedGuns) used")
                InlineStat(model: model, key: key, field: "maxTurrets", label: "Turret mounts",
                           note: "eff. \(s.maxTurrets) · \(s.usedTurrets) used")
                InlineStat(model: model, key: key, field: "crew", label: "Crew")
                InlineStat(model: model, key: key, field: "cost", label: "Cost", note: SpecFormat.credits(h.cost))
                InlineStat(model: model, key: key, field: "techLevel", label: "Tech level")
                if let ab = s.afterburnerFuelPerSec {
                    StatRow(label: "Afterburner", value: "\(SpecFormat.num(ab, 1)) fuel/s")
                }
                if s.fuelRegenPerSec > 0 {
                    StatRow(label: "Fuel regeneration", value: "\(SpecFormat.num(s.fuelRegenPerSec, 2))/s")
                }
            }
        }
    }

    private func armament(_ s: ShipStatSheet) -> some View {
        SpecSection(title: "Armament", trailing: "DPS = damage ÷ reload × mounts") {
            if s.weapons.isEmpty {
                Text("No stock weapons.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(s.weapons) { w in
                        HStack(spacing: 8) {
                            ResourceChip(env: env, type: NovaType.weapon, id: w.id, suffix: w.count > 1 ? " ×\(w.count)" : "")
                            Text(w.ammo > 0 ? "\(w.ammo) ammo" : (w.isBeam ? "beam" : "∞"))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(SpecFormat.num(w.dpsShield)) / \(SpecFormat.num(w.dpsArmor))")
                                .font(.system(size: 11, design: .monospaced))
                            Text("rng \(Int(w.range))").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.4)
                    StatRow(label: "Total DPS vs shields / armor",
                            value: "\(SpecFormat.num(s.dpsShield)) / \(SpecFormat.num(s.dpsArmor))")
                    let tts = s.dpsShield > 0 ? s.shield / s.dpsShield : 0
                    if tts > 0 {
                        StatRow(label: "Time to strip own shield", value: "\(SpecFormat.num(tts, 1)) s",
                                note: "if it faced itself")
                    }
                }
            }
        }
    }

    private func defaultItems(_ s: ShipStatSheet, _ h: ShipRes) -> some View {
        SpecSection(title: "Default items", trailing: "\(h.outfits.count) outfit\(h.outfits.count == 1 ? "" : "s")") {
            if h.outfits.isEmpty {
                Text("None.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ChipFlow {
                    ForEach(Array(h.outfits.enumerated()), id: \.offset) { _, o in
                        ResourceChip(env: env, type: NovaType.outfit, id: o.id, suffix: o.count > 1 ? " ×\(o.count)" : "")
                    }
                }
            }
        }
    }

    private func identity(_ h: ShipRes) -> some View {
        SpecSection(title: "Government & escort") {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Inherent govt").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if h.inherentCombatGovt >= 128 { ResourceChip(env: env, type: NovaType.govt, id: h.inherentCombatGovt) }
                    else { Text(h.inherentGovt < 0 ? "None" : "attributes only (\(h.inherentAttributesGovt))").font(.system(size: 12)).foregroundStyle(.tertiary) }
                }
                StatRow(label: "Escort category", value: ["Automatic", "Fighter", "Medium ship", "Warship", "Freighter"][max(0, min(4, h.escortCategory + 1))])
                InlineStat(model: model, key: key, field: "upgradeCost", label: "Escort upgrade cost")
                InlineStat(model: model, key: key, field: "sellValue", label: "Escort sell value")
            }
        }
    }

    private var descKey: ResourceKey { ResourceKey(NovaType.desc, key.id + 12872) }

    private var description: some View {
        SpecSection(title: "Shipyard description") {
            if let r = model.effective.resource(descKey.type, descKey.id) {
                let text = DescRes(r).text
                Text(text.isEmpty ? "(empty)" : text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit description") { env.jump(descKey.type, descKey.id) }.controlSize(.small)
            } else {
                HStack {
                    Text("No dësc #\(descKey.id).").font(.system(size: 12)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Create") {
                        _ = try? model.document.create(NovaType.desc, id: descKey.id, name: "")
                    }.controlSize(.small)
                }
            }
        }
    }

    private var availability: some View {
        SpecSection(title: "Shipyard availability",
                    trailing: "tech ≤ planet tech, or special tech · \(sellers.count) stellar\(sellers.count == 1 ? "" : "s")") {
            if sellers.isEmpty {
                Text("No shipyard offers this hull (tech \(hull?.techLevel ?? 0)).").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ChipFlow {
                    ForEach(sellers.prefix(30), id: \.id) { sp in
                        ResourceChip(env: env, type: NovaType.spob, id: sp.id)
                    }
                    if sellers.count > 30 { Text("+\(sellers.count - 30) more").font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private var usedBy: some View {
        let kinds: [NovaSwiftKit.FourCharCode] = [NovaType.fleet, NovaType.dude, NovaType.char, NovaType.pers]
        // Reference graph is built in the background once per document; a lookup afterwards.
        let refs = model.referencesReady ? model.document.references.usedBy(key).filter { kinds.contains($0.source.type) } : []
        var seen = Set<ResourceKey>()
        let uniq = refs.filter { seen.insert($0.source).inserted }
        return SpecSection(title: "Used by", trailing: "flët · düde · chär · përs") {
            if !model.referencesReady {
                SkeletonBar(width: 200, height: 10)
            } else if uniq.isEmpty {
                Text("Nothing references this hull.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ChipFlow {
                    ForEach(uniq.prefix(40), id: \.source) { r in
                        ResourceChip(env: env, type: r.source.type, id: r.source.id)
                    }
                    if uniq.count > 40 { Text("+\(uniq.count - 40) more").font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}
#endif
