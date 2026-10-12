#if os(macOS)
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// oütf overview: modifiers in plain language, economy/availability, who sells it,
/// and a before/after stat comparison on a chosen ship.
struct OutfitOverviewView: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey

    @State private var outfit: OutfRes?
    @State private var sellers: [SpobRes] = []
    @State private var shipID = 128
    @State private var count = 1
    @State private var ships: [PluginDocument.BrowserEntry] = []
    @State private var before: ShipStatSheet?
    @State private var after: ShipStatSheet?
    @State private var iconID: Int?

    private struct TaskKey: Hashable { let key: ResourceKey; let revision: Int; let ship: Int; let count: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = outfit {
                modifiers(o)
                economy(o)
                availability(o)
                compare(o)
            } else {
                EditorEmptyState(icon: "puzzlepiece", title: "Couldn't decode this outfit", subtitle: "Use Form or Raw.")
            }
        }
        .task(id: TaskKey(key: key, revision: model.revision, ship: shipID, count: count)) {
            let d = SpecCache.data(model)
            outfit = d.game.outfit(key.id)
            sellers = outfit.map { SpecAvailability.spobs(sellingOutfit: $0, game: d.game) } ?? []
            ships = env.cache.entries(NovaType.ship, model)
            if !ships.contains(where: { $0.key.id == shipID }), let f = ships.first { shipID = f.key.id }
            before = ShipStatSheet.compute(d, shipID: shipID)
            after = ShipStatSheet.compute(d, shipID: shipID, extraOutfits: [key.id: count])
        }
    }

    // MARK: Modifiers in plain language

    private struct Slot: Identifiable { let id: Int; let type: Int; let value: Int; let typeField: String; let valueField: String }

    private var slots: [Slot] {
        let t0 = model.readValue("modType", of: key)?.intValue ?? 0
        let v0 = model.readValue("modValue", of: key)?.intValue ?? 0
        var out = [Slot(id: 0, type: t0, value: v0, typeField: "modType", valueField: "modValue")]
        if case let .array(ts)? = model.readValue("modTypes2", of: key), case let .array(vs)? = model.readValue("modValues2", of: key) {
            for i in 0..<min(ts.count, vs.count) {
                out.append(Slot(id: i + 1, type: ts[i].intValue ?? 0, value: vs[i].intValue ?? 0, typeField: "modTypes2", valueField: "modValues2"))
            }
        }
        return out
    }

    private func modifiers(_ o: OutfRes) -> some View {
        let schema = ResourceSchemas.schema(for: key.type)
        let typeField = schema?.field("modType")
        let valueField = schema?.field("modValue")
        let used = slots.filter { $0.type != 0 }
        return SpecSection(title: "What it does", trailing: "ModType / ModVal") {
            if used.isEmpty {
                Text("No modifiers: this outfit is purely a flag or requirement holder.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(used) { s in
                        let name = typeField?.option(for: s.type)?.label ?? "ModType \(s.type)"
                        let meaning = valueField?.contextual?.meaning(for: s.type)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(name).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                valueView(s, meaning)
                            }
                            if let h = meaning?.help, !h.isEmpty { Text(h).font(.system(size: 10)).foregroundStyle(.tertiary) }
                            if let m = meaning, !m.flagBits.isEmpty {
                                let on = m.flagBits.filter { s.value & $0.mask != 0 }.map(\.label)
                                Text(on.isEmpty ? "No flags set" : on.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func valueView(_ s: Slot, _ meaning: ContextualValue.Meaning?) -> some View {
        if let m = meaning, let t = m.refType, s.value >= m.minValue {
            ResourceChip(env: env, type: t, id: s.value + m.idBase)
        } else if let m = meaning, !m.flagBits.isEmpty {
            Text("0x" + String(s.value, radix: 16, uppercase: true)).font(.system(size: 12, design: .monospaced))
        } else {
            HStack(spacing: 5) {
                Text(s.value > 0 ? "+\(s.value)" : "\(s.value)").font(.system(size: 12, design: .monospaced))
                Text(meaning?.label ?? "").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    // MARK: Economy & availability

    private func economy(_ o: OutfRes) -> some View {
        SpecSection(title: "Economy") {
            VStack(spacing: 5) {
                InlineStat(model: model, key: key, field: "mass", label: "Mass", note: "tons of free mass")
                InlineStat(model: model, key: key, field: "cost", label: "Cost", note: SpecFormat.credits(o.cost))
                InlineStat(model: model, key: key, field: "techLevel", label: "Tech level",
                           note: o.techLevel >= 0x7fff ? "never sold" : "")
                InlineStat(model: model, key: key, field: "maximum", label: "Max installed", note: o.maxInstallable == 0 ? "unlimited" : "")
                InlineStat(model: model, key: key, field: "dispWeight", label: "Display weight")
                if o.isFixedGunOutfit { StatRow(label: "Mount", value: "uses a gun mount") }
                if o.isTurretOutfit { StatRow(label: "Mount", value: "uses a turret mount") }
                if o.priceIsShipMassProportional { StatRow(label: "Price", value: "× ship mass") }
                if o.massIsShipMassProportional { StatRow(label: "Mass", value: "scales with ship mass") }
            }
        }
    }

    private func availability(_ o: OutfRes) -> some View {
        SpecSection(title: "Requirements & availability",
                    trailing: "\(sellers.count) outfitter\(sellers.count == 1 ? "" : "s")") {
            VStack(alignment: .leading, spacing: 6) {
                StatRow(label: "Availability (NCB)", value: o.availBits.isEmpty ? "always" : o.availBits)
                StatRow(label: "Requires bits", value: o.require == 0 ? "none" : String(format: "0x%llX", o.require))
                StatRow(label: "Contributes bits", value: o.contribute == 0 ? "none" : String(format: "0x%llX", o.contribute))
                if !o.onPurchase.isEmpty { StatRow(label: "OnPurchase", value: o.onPurchase) }
                if !o.onSell.isEmpty { StatRow(label: "OnSell", value: o.onSell) }
                if sellers.isEmpty {
                    Text(o.techLevel >= 0x7fff ? "Tech level 32767: never in an outfitter (grants/rewards only)."
                         : "No outfitter is high-tech enough to stock this.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ChipFlow {
                        ForEach(sellers.prefix(30), id: \.id) { sp in ResourceChip(env: env, type: NovaType.spob, id: sp.id) }
                        if sellers.count > 30 { Text("+\(sellers.count - 30) more").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }

    // MARK: Before / after

    private func compare(_ o: OutfRes) -> some View {
        SpecSection(title: "Effect on a ship", trailing: "stock loadout vs. + this outfit") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Ship", selection: $shipID) {
                        ForEach(ships.prefix(400), id: \.key) { e in Text("#\(e.key.id) \(e.name)").tag(e.key.id) }
                    }.frame(maxWidth: 280)
                    Stepper("×\(count)", value: $count, in: 1...20).fixedSize()
                }
                if let b = before, let a = after {
                    let rows: [(String, Double, Double, Int)] = [
                        ("Top speed (px/s)", b.maxSpeed, a.maxSpeed, 1), ("Acceleration (px/s²)", b.acceleration, a.acceleration, 1),
                        ("Turn rate (°/s)", b.turnDegPerSec, a.turnDegPerSec, 1),
                        ("Shield", b.shield, a.shield, 0), ("Armor", b.armor, a.armor, 0),
                        ("Shield recharge (/s)", b.shieldRecharge, a.shieldRecharge, 2), ("Armor recharge (/s)", b.armorRecharge, a.armorRecharge, 2),
                        ("Cargo (t)", Double(b.cargo), Double(a.cargo), 0), ("Fuel", b.maxFuel, a.maxFuel, 0),
                        ("Jumps", Double(b.jumps), Double(a.jumps), 0),
                        ("Free mass (t)", Double(b.freeMass), Double(a.freeMass), 0),
                        ("Gun mounts free", Double(b.maxGuns - b.usedGuns), Double(a.maxGuns - a.usedGuns), 0),
                        ("Turret mounts free", Double(b.maxTurrets - b.usedTurrets), Double(a.maxTurrets - a.usedTurrets), 0),
                        ("DPS vs shields", b.dpsShield, a.dpsShield, 1), ("DPS vs armor", b.dpsArmor, a.dpsArmor, 1),
                    ]
                    VStack(spacing: 3) {
                        ForEach(rows.indices, id: \.self) { i in
                            let r = rows[i]
                            let changed = abs(r.1 - r.2) > 0.0001
                            HStack {
                                Text(r.0).font(.system(size: 12)).foregroundStyle(changed ? Color.primary : Color.secondary)
                                Spacer()
                                Text(SpecFormat.num(r.1, r.3)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(SpecFormat.num(r.2, r.3)).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(changed ? (r.2 > r.1 ? Color.green : Color.orange) : Color.secondary)
                            }
                        }
                    }
                    if a.freeMass < b.freeMass, a.massCapacity - a.usedMass < 0 {
                        Label("Over the mass limit by \(a.usedMass - a.massCapacity) t.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                } else {
                    Text("Pick a ship.").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
#endif
