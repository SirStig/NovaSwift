#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

// MARK: - Stellar inspector

struct StellarInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var sprites: StellarSpriteCache
    let systemID: Int
    let stellar: StellarRec
    var onRemove: (Int) -> Void
    var onDelete: (Int) -> Void
    var onDuplicate: (Int) -> Void

    var body: some View {
        let key = ResourceKey(NovaType.spob, stellar.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("STELLAR #\(stellar.id)").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
                Spacer()
                Text("NAV \(stellar.slot)").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            MapNameRow(model: model, key: key)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    preview(type: model.intField("type", key, default: -1))
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: Binding(get: { model.intField("type", key, default: -1) },
                                                      set: { model.setValue(.int($0), field: "type", of: key) })) {
                            Text("None").tag(-1)
                            ForEach(spinChoices(), id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden()
                        MapIntRow(model: model, key: key, field: "type", label: "Graphic type")
                    }
                }
            }
            .mapInspectorSection("Graphic")

            VStack(alignment: .leading, spacing: 6) {
                MapPointRow(model: model, key: key, field: "position", label: "Position (x, y)")
                MapRefPicker(model: model, key: key, field: "govt", label: "Government", refType: NovaType.govt, noneLabel: "Independent")
            }
            .mapInspectorSection("Placement")

            MapFlagToggles(model: model, key: key, field: "flags").mapInspectorSection("Services & flags")

            VStack(alignment: .leading, spacing: 6) {
                MapIntRow(model: model, key: key, field: "techLevel", label: "Tech level")
                MapIntRow(model: model, key: key, field: "tribute", label: "Daily tribute")
                MapIntRow(model: model, key: key, field: "minStatus", label: "Min legal status")
                MapIntRow(model: model, key: key, field: "fee", label: "Landing fee")
            }
            .mapInspectorSection("Economy & access")

            VStack(alignment: .leading, spacing: 6) {
                MapRefPicker(model: model, key: key, field: "defenseDude", label: "Defense fleet", refType: NovaType.dude)
                MapIntRow(model: model, key: key, field: "defCount", label: "Defense ships")
                MapIntRow(model: model, key: key, field: "strength", label: "Strength")
                MapRefPicker(model: model, key: key, field: "weapon", label: "Weapon", refType: NovaType.weapon)
            }
            .mapInspectorSection("Defense")

            VStack(alignment: .leading, spacing: 6) {
                landingPict(key)
                MapIntRow(model: model, key: key, field: "custSndID", label: "Ambient snd id")
                descRow("Spaceport description", id: stellar.id)
                descRow("Bar description", id: stellar.id + 9872)
            }
            .mapInspectorSection("Landing & text")

            DisclosureGroup("Animation & gate flags") {
                MapFlagToggles(model: model, key: key, field: "flags2")
                MapIntRow(model: model, key: key, field: "animDelay", label: "Animation delay")
            }
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { model.showInResources(key) } label: { Label("All Fields", systemImage: "list.bullet.rectangle") }
                    Button { onDuplicate(stellar.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                }
                HStack {
                    Button { onRemove(stellar.id) } label: { Label("Remove from System", systemImage: "minus.circle") }
                    Button(role: .destructive) { onDelete(stellar.id) } label: { Image(systemName: "trash") }
                        .help("Delete this stellar resource (plug-in-owned only)")
                }
            }
            .font(.system(size: 11))
        }
    }

    private func spinChoices() -> [(Int, String)] {
        model.entries(NovaType.spin).filter { (1000...1255).contains($0.id) }.map { ($0.id - 1000, "\($0.id - 1000): \($0.name)") }
    }

    private func preview(type: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black)
            RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12))
            if let e = sprites.entry(type: type, collection: model.effective) {
                let s = min(1, 76 / max(e.size.width, e.size.height))
                Image(decorative: e.image, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: e.size.width * s, height: e.size.height * s)
            } else {
                Image(systemName: "questionmark").foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .id(sprites.version)
    }

    private func landingPict(_ key: ResourceKey) -> some View {
        let id = model.intField("custPicID", key)
        let isGate = model.intField("flags2", key) & 0x3000 != 0
        return VStack(alignment: .leading, spacing: 2) {
            MapIntRow(model: model, key: key, field: "custPicID", label: isGate ? "First open frame" : "Landing PICT id")
            if !isGate, id >= 128 {
                Text(model.document.effective.resource(NovaType.pict, id) != nil ? "PICT #\(id) found" : "PICT #\(id) is missing")
                    .font(.system(size: 10)).foregroundStyle(model.document.effective.resource(NovaType.pict, id) != nil ? Color.green : Color.orange)
            }
        }
    }

    private func descRow(_ label: String, id: Int) -> some View {
        let exists = model.document.effective.resource(NovaType.desc, id) != nil
        return HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if exists {
                Button("d\u{00EB}sc #\(id)") { model.showInResources(ResourceKey(NovaType.desc, id)) }.buttonStyle(.link)
            } else {
                Button("Create #\(id)") { _ = try? model.document.create(NovaType.desc, id: id) }.buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: - System panel

struct SystemPanel: View {
    @ObservedObject var model: EditorModel
    let systemID: Int
    var onSelectStellar: (Int) -> Void

    @State private var openGeneral = true
    @State private var openTraffic = true
    @State private var openHazards = true
    @State private var openAppearance = false
    @State private var openReinf = false
    @State private var openNav = true

    var body: some View {
        let key = ResourceKey(NovaType.syst, systemID)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SYSTEM #\(systemID)").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
                Spacer()
                Text(provenanceText).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            MapNameRow(model: model, key: key)

            DisclosureGroup("General", isExpanded: $openGeneral) {
                VStack(alignment: .leading, spacing: 6) {
                    MapPointRow(model: model, key: key, field: "position", label: "Map position")
                    MapRefPicker(model: model, key: key, field: "govt", label: "Government", refType: NovaType.govt, noneLabel: "Independent")
                    MapTextRow(model: model, key: key, field: "visibility", label: "Visibility (NCB test)")
                }.padding(.top, 4)
            }

            DisclosureGroup("Traffic", isExpanded: $openTraffic) {
                VStack(alignment: .leading, spacing: 6) {
                    MapIntRow(model: model, key: key, field: "avgShips", label: "Average ships")
                    spawnTable(key)
                    persTable(key)
                }.padding(.top, 4)
            }

            DisclosureGroup("Hazards & asteroids", isExpanded: $openHazards) {
                VStack(alignment: .leading, spacing: 6) {
                    MapIntRow(model: model, key: key, field: "interference", label: "Interference %")
                    MapIntRow(model: model, key: key, field: "asteroids", label: "Asteroid count (0-16)")
                    MapIntRow(model: model, key: key, field: "message", label: "Message buoy (STR# 1000 idx)")
                    Text("Asteroid types").font(.system(size: 11)).foregroundStyle(.secondary)
                    MapFlagToggles(model: model, key: key, field: "astTypes")
                }.padding(.top, 4)
            }

            DisclosureGroup("Appearance", isExpanded: $openAppearance) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background colour").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("", selection: bgBinding(key), supportsOpacity: false).labelsHidden()
                    }
                    MapIntRow(model: model, key: key, field: "murk", label: "Murk (0-100)")
                }.padding(.top, 4)
            }

            DisclosureGroup("Reinforcements", isExpanded: $openReinf) {
                VStack(alignment: .leading, spacing: 6) {
                    MapRefPicker(model: model, key: key, field: "reinfFleet", label: "Fleet", refType: NovaType.fleet)
                    MapIntRow(model: model, key: key, field: "reinfTime", label: "Delay (frames)")
                    MapIntRow(model: model, key: key, field: "reinfInterval", label: "Regen (days)")
                }.padding(.top, 4)
            }

            DisclosureGroup("Nav order", isExpanded: $openNav) { navOrder(key).padding(.top, 4) }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var provenanceText: String {
        switch model.document.provenance(NovaType.syst, systemID) {
        case .new: return "NEW"
        case .override: return "OVERRIDE"
        case .otherPlugin: return "PLUG-IN"
        default: return "BASE"
        }
    }

    private func bgBinding(_ key: ResourceKey) -> Binding<Color> {
        Binding(get: {
            if case let .color(r, g, b)? = model.readValue("background", of: key) {
                return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
            }
            return .black
        }, set: { c in
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
            model.setValue(.color(r: UInt8(max(0, min(255, ns.redComponent * 255)).rounded()),
                                  g: UInt8(max(0, min(255, ns.greenComponent * 255)).rounded()),
                                  b: UInt8(max(0, min(255, ns.blueComponent * 255)).rounded())), field: "background", of: key)
        })
    }

    // Dude / fleet spawn table (8 rows): negative ids are flët.
    private func spawnTable(_ key: ResourceKey) -> some View {
        let types = padded(model.arrayField("dudeTypes", key), 8, -1)
        let probs = padded(model.arrayField("dudeProbs", key), 8, 0)
        let sum = zip(types, probs).filter { $0.0 != -1 && $0.0 != 0 }.map(\.1).reduce(0, +)
        let dudes = model.entries(NovaType.dude), fleets = model.entries(NovaType.fleet)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Spawn table (d\u{00FC}de / fl\u{00EB}t)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(sum)%").font(.system(size: 10, design: .monospaced)).foregroundStyle(sum > 100 ? Color.orange : .secondary)
            }
            ForEach(0..<8, id: \.self) { i in
                HStack(spacing: 4) {
                    Picker("", selection: Binding(get: { types[i] }, set: { v in set("dudeTypes", i, v, key, -1) })) {
                        Text("None").tag(-1)
                        if types[i] != -1, !dudes.contains(where: { $0.id == types[i] }), !fleets.contains(where: { -$0.id == types[i] }) {
                            Text("#\(types[i]) (missing)").tag(types[i])
                        }
                        Section("D\u{00FC}des") { ForEach(dudes, id: \.id) { Text($0.name).tag($0.id) } }
                        Section("Fleets") { ForEach(fleets, id: \.id) { Text($0.name).tag(-$0.id) } }
                    }
                    .labelsHidden()
                    TextField("%", value: Binding(get: { probs[i] }, set: { v in set("dudeProbs", i, v, key, 0) }), format: .number)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 44)
                        .disabled(types[i] == -1)
                }
            }
        }
    }

    private func persTable(_ key: ResourceKey) -> some View {
        let types = padded(model.arrayField("persTypes", key), 8, -1)
        let probs = padded(model.arrayField("persProbs", key), 8, 0)
        let pers = model.entries(NovaType.pers)
        let used = types.indices.filter { types[$0] != -1 }
        return DisclosureGroup("Pinned p\u{00EB}rs (\(used.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    HStack(spacing: 4) {
                        Picker("", selection: Binding(get: { types[i] }, set: { v in set("persTypes", i, v, key, -1) })) {
                            Text("None").tag(-1)
                            if types[i] != -1, !pers.contains(where: { $0.id == types[i] }) { Text("#\(types[i]) (missing)").tag(types[i]) }
                            ForEach(pers, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        TextField("%", value: Binding(get: { probs[i] }, set: { v in set("persProbs", i, v, key, 0) }), format: .number)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 44)
                            .disabled(types[i] == -1)
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func navOrder(_ key: ResourceKey) -> some View {
        let slots = padded(model.arrayField("navDefaults", key), 16, -1)
        let used = slots.indices.filter { slots[$0] >= 128 }
        return VStack(alignment: .leading, spacing: 3) {
            if used.isEmpty { Text("No stellars").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(used, id: \.self) { i in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 16)
                    Button { onSelectStellar(slots[i]) } label: { Text(model.displayName(NovaType.spob, slots[i])).font(.system(size: 11)) }
                        .buttonStyle(.plain)
                    Spacer()
                    Button { move(i, -1, slots, key) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0).buttonStyle(.plain)
                    Button { move(i, 1, slots, key) } label: { Image(systemName: "chevron.down") }
                        .disabled(i >= 15).buttonStyle(.plain)
                }
            }
            Text("F1\u{2013}F4 select the first four slots. Stellars not listed never appear.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func move(_ i: Int, _ d: Int, _ slots: [Int], _ key: ResourceKey) {
        var s = slots
        let j = i + d
        guard j >= 0, j < s.count else { return }
        s.swapAt(i, j)
        model.setArray(s, field: "navDefaults", of: key)
    }

    private func padded(_ a: [Int], _ n: Int, _ fill: Int) -> [Int] {
        a.count >= n ? Array(a.prefix(n)) : a + Array(repeating: fill, count: n - a.count)
    }

    private func set(_ field: String, _ i: Int, _ v: Int, _ key: ResourceKey, _ fill: Int) {
        var a = padded(model.arrayField(field, key), 8, fill)
        a[i] = v
        model.setArray(a, field: field, of: key)
    }
}
#endif
