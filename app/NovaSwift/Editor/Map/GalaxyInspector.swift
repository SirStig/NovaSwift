#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Right-hand inspector of the galaxy editor: the selected system (or
/// nebula) with the fields authors reach for most. Everything writes through
/// `EditorModel.setValue`.
struct GalaxyInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var data: GalaxyMapData
    let selection: Set<Int>
    let nebula: Int?
    var onSelect: (Int) -> Void
    var onLink: (Int, Int) -> Void
    var onUnlink: (Int, Int) -> Void
    var onDelete: ([Int]) -> Void
    var onDeleteNebula: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !data.hasLoaded { SkeletonForm(groups: 2) }
                else if let n = nebula, selection.isEmpty { nebulaPanel(n) }
                else if selection.count == 1, let id = selection.first, data.system(id) != nil { systemPanel(id) }
                else if selection.count > 1 { multiPanel }
                else { emptyPanel }
            }
            .padding(12)
        }
        .background(Color(white: 0.105))
    }

    // MARK: Empty / multi

    private var emptyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GALAXY").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
            let touched = data.touchedCount
            Text("\(data.systems.count) systems  \u{2022}  \(data.pairs.count) hyperlinks  \u{2022}  \(data.nebulae.count) nebulae")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(touched) added or overridden by this plug-in").font(.system(size: 11)).foregroundStyle(.secondary)
            let oneWay = data.oneWayCount
            if oneWay > 0 {
                Label("\(oneWay) one-way hyperlink\(oneWay == 1 ? "" : "s") (dashed red)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider()
            Text("Select a system to edit it. Use the Link tool to connect systems, New System to add one, and double-click a system to edit its planets.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var multiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(selection.count) SYSTEMS").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
            HStack {
                Text("Government").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { sharedGovt ?? -2 }, set: { g in setGovt(g, for: selection) })) {
                    if sharedGovt == nil { Text("Mixed").tag(-2) }
                    Text("Independent").tag(-1)
                    ForEach(data.govts) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 150)
            }
            Button(role: .destructive) { onDelete(Array(selection)) } label: { Label("Delete Selected", systemImage: "trash") }
        }
    }

    private var sharedGovt: Int? {
        let g = Set(selection.compactMap { data.system($0)?.govt }.map { $0 < 128 ? -1 : $0 })
        return g.count == 1 ? g.first : nil
    }

    private func setGovt(_ g: Int, for ids: Set<Int>) {
        guard g != -2 else { return }
        model.document.withGroup("Set government") {
            for id in ids { model.setValue(.int(g), field: "govt", of: ResourceKey(NovaType.syst, id)) }
        }
    }

    // MARK: System

    private func systemPanel(_ id: Int) -> some View {
        let key = ResourceKey(NovaType.syst, id)
        let s = data.system(id)!
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("STAR SYSTEM #\(id)").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
                Spacer()
                provenanceBadge(s.provenance)
            }
            MapNameRow(model: model, key: key)

            VStack(alignment: .leading, spacing: 6) {
                MapPointRow(model: model, key: key, field: "position", label: "Map position")
                HStack {
                    Text("Government").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { s.govt < 128 ? -1 : s.govt },
                                                  set: { model.setValue(.int($0), field: "govt", of: key) })) {
                        Text("Independent").tag(-1)
                        ForEach(data.govts) { g in Text(g.name).tag(g.id) }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                }
            }
            .mapInspectorSection("General")

            linksSection(id, s, key)
            stellarsSection(id, key)

            VStack(alignment: .leading, spacing: 6) {
                MapIntRow(model: model, key: key, field: "avgShips", label: "Average ships")
                MapIntRow(model: model, key: key, field: "interference", label: "Interference %")
                MapIntRow(model: model, key: key, field: "asteroids", label: "Asteroids")
                trafficSummary(key)
                MapTextRow(model: model, key: key, field: "visibility", label: "Visibility (NCB test)")
            }
            .mapInspectorSection("Quick fields")

            HStack {
                Button { model.openSystemEditor(id) } label: { Label("Open in System Editor", systemImage: "scope") }
                Button { model.showInResources(key) } label: { Image(systemName: "list.bullet.rectangle") }.help("Show in Resources")
            }
            Button(role: .destructive) { onDelete([id]) } label: { Label("Delete System", systemImage: "trash") }
        }
    }

    private func provenanceBadge(_ p: Provenance) -> some View {
        let (t, c): (String, Color) = {
            switch p {
            case .new: return ("NEW", .green)
            case .override: return ("OVERRIDE", .orange)
            case .otherPlugin: return ("PLUG-IN", .blue)
            case .base: return ("BASE", .gray)
            }
        }()
        return Text(t).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.25))).foregroundStyle(c)
    }

    private func linksSection(_ id: Int, _ s: MapSystem, _ key: ResourceKey) -> some View {
        let linked = Set(s.links)
        let near = data.nearest(to: id, count: 15, excluding: linked)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(s.links, id: \.self) { l in
                HStack(spacing: 6) {
                    Circle().fill(data.color(data.system(l)?.govt ?? -1)).frame(width: 7, height: 7)
                    Button { onSelect(l) } label: { Text(data.system(l)?.name ?? "#\(l) (missing)").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                    if let o = data.system(l), !o.links.contains(id) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            .help("One-way link: \(o.name) doesn't link back")
                    }
                    Spacer()
                    Button { onUnlink(id, l) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Menu {
                ForEach(near) { n in Button("\(n.name)  (#\(n.id))") { onLink(id, n.id) } }
            } label: { Label("Add link\u{2026} (nearest)", systemImage: "plus") }
                .menuStyle(.borderlessButton).font(.system(size: 11)).disabled(near.isEmpty)
            Text("\(s.links.count)/\(SystemLinkEditing.maxLinks) slots used").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .mapInspectorSection("Hyperlinks")
    }

    private func stellarsSection(_ id: Int, _ key: ResourceKey) -> some View {
        let spobs = SystemLinkEditing.stellars(of: model.document, id)
        return VStack(alignment: .leading, spacing: 4) {
            if spobs.isEmpty { Text("No stellars").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(spobs, id: \.self) { sp in
                Button {
                    model.openSystemEditor(id)
                    model.selection = ResourceKey(NovaType.spob, sp)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.europe.africa").font(.system(size: 10)).foregroundStyle(novaAmber)
                        Text(model.displayName(NovaType.spob, sp)).font(.system(size: 11))
                        Spacer()
                        Text("#\(sp)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .mapInspectorSection("Stellars")
    }

    private func trafficSummary(_ key: ResourceKey) -> some View {
        let types = model.arrayField("dudeTypes", key), probs = model.arrayField("dudeProbs", key)
        let rows: [(String, Int)] = zip(types, probs).compactMap { t, p in
            guard t != -1, t != 0, p > 0 else { return nil }
            return t < 0 ? (model.displayName(NovaType.fleet, -t), p) : (model.displayName(NovaType.dude, t), p)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Traffic").font(.system(size: 11)).foregroundStyle(.secondary)
            if rows.isEmpty { Text("None").font(.system(size: 11)) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack { Text(r.0).font(.system(size: 11)).lineLimit(1); Spacer(); Text("\(r.1)%").font(.system(size: 11, design: .monospaced)) }
            }
        }
    }

    // MARK: Nebula

    private func nebulaPanel(_ id: Int) -> some View {
        let key = ResourceKey(NovaType.nebula, id)
        return VStack(alignment: .leading, spacing: 10) {
            Text("NEBULA #\(id)").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
            MapNameRow(model: model, key: key)
            MapPointRow(model: model, key: key, field: "position", label: "Position (x, y)")
            MapPointRow(model: model, key: key, field: "size", label: "Size (w, h)")
            MapTextRow(model: model, key: key, field: "activeOn", label: "Active on (NCB test)")
            Text("Artwork: PICT \((9502 + 7 * (id - 128))) (+ the six smaller zoom levels below it).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button { model.showInResources(key) } label: { Label("Show in Resources", systemImage: "list.bullet.rectangle") }
                Button(role: .destructive) { onDeleteNebula(id) } label: { Image(systemName: "trash") }
            }
        }
    }
}
#endif
