import SwiftUI
import NovaSwiftKit

/// "Add-ons for <total conversion>": the selected conversion's own plug-in list (`TCAddOns`).
///
/// The original runs a conversion with only its own Plug-Ins folder (global plug-ins do not apply);
/// adding an add-on such as EVO Facelift to EV Override meant copying files into that folder. This
/// is the same thing without copying: the plug-ins listed here load after the conversion's own
/// Plug-Ins, in list order. Suggestions come from names / read-mes / record overlap; a plug-in that
/// looks made for the base game is flagged but can still be added.
struct TCAddOnsSection: View {
    @EnvironmentObject private var model: AppModel
    let tc: PluginBundle
    @State private var overlap: [String: TCAddOns.Compatibility] = [:]
    @State private var pendingUnlikely: PluginBundle?
    @State private var showCandidates = false

    private var others: [PluginBundle] { model.data.plugins.filter { $0.isTotalConversion && $0.id != tc.id } }
    private var entries: [PluginEnableState] { model.data.tcAddOnLists[tc.id] ?? [] }

    private func compat(_ p: PluginBundle, deep: Bool) -> TCAddOns.Compatibility {
        let c = TCAddOns.compatibility(of: p, with: tc, others: others)
        return deep ? TCAddOns.combine(c, overlap[p.id] ?? .neutral) : c
    }

    private var candidates: [PluginBundle] {
        let listed = Set(entries.map(\.id))
        let rank: [String: Int] = ["recommended": 0, "neutral": 1, "unlikely": 2]
        return model.data.plugins
            .filter { !$0.isTotalConversion && !listed.contains($0.id) && ($0.folderURL != nil || !$0.fileURLs.isEmpty) }
            .enumerated()
            .sorted { a, b in
                let ra = rank[compat(a.element, deep: true).key] ?? 1, rb = rank[compat(b.element, deep: true).key] ?? 1
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add-ons for \(tc.name)", systemImage: "puzzlepiece.extension.fill").font(.headline)
            Text("While \(tc.name) is on, only its own plug-ins load, as in the original. Plug-ins you add here load after them, in this order (later wins) — the same as copying them into the conversion's Plug-Ins folder, without moving any files.")
                .font(.footnote).foregroundStyle(.secondary)
            if !tc.fileURLs.isEmpty {
                Text("Built in: " + tc.fileURLs.map { $0.deletingPathExtension().lastPathComponent }.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, e in listRow(index: index, entry: e) }
            Button { showCandidates.toggle() } label: {
                Label(showCandidates ? "Hide installed plug-ins" : "Add plug-in to \(tc.name)",
                      systemImage: showCandidates ? "chevron.up.circle" : "plus.circle")
            }
            .novaBorderedButton()
            if showCandidates {
                if candidates.isEmpty { Text("No other plug-ins installed.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(candidates) { p in candidateRow(p) }
            }
        }
        .padding(14)
        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: tc.id + "|\(model.data.plugins.count)") { await analyse() }
        .novaAlert("Add \(pendingUnlikely?.name ?? "plug-in") anyway?",
                   isPresented: Binding(get: { pendingUnlikely != nil }, set: { if !$0 { pendingUnlikely = nil } }),
                   message: pendingUnlikely.map { unlikelyMessage($0) },
                   buttons: addAnywayButtons)
    }

    private func unlikelyMessage(_ p: PluginBundle) -> String {
        let reason = compat(p, deep: true).reason
        return "This plug-in looks like it was made for the base game or another conversion (\(reason)). It may add things that do not exist in \(tc.name), or change the wrong records. You can still add it, and remove it again here."
    }

    private var addAnywayButtons: [NovaAlertButton] {
        let p = pendingUnlikely
        return [.destructive("Add anyway") { if let p { model.data.addOnAdd(tc: tc.id, id: p.id) } }, .cancel("Cancel") {}]
    }

    @ViewBuilder private func candidateRow(_ p: PluginBundle) -> some View {
        let c = compat(p, deep: true)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if c.key == "recommended" { PluginBadge(text: "Suggested", systemImage: "checkmark.seal.fill", color: .green) }
                    if c.key == "unlikely" { PluginBadge(text: "Base game?", systemImage: "exclamationmark.triangle.fill", color: .orange) }
                    if !c.reason.isEmpty { Text(c.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 6)
            Button("Add") { tryAdd(p) }.novaBorderedButton()
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tryAdd(_ p: PluginBundle) {
        if compat(p, deep: true).key == "unlikely" { pendingUnlikely = p } else { model.data.addOnAdd(tc: tc.id, id: p.id) }
    }

    @ViewBuilder private func listRow(index: Int, entry e: PluginEnableState) -> some View {
        let p = model.data.plugins.first { $0.id == e.id && !$0.isTotalConversion }
        let c = p.map { compat($0, deep: false) } ?? .neutral
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(p?.name ?? e.id).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if p == nil { PluginBadge(text: "Not installed", color: .red) }
                    if c.key == "recommended" { PluginBadge(text: "Made for this", systemImage: "checkmark.seal.fill", color: .green) }
                    if c.key == "unlikely" { PluginBadge(text: "Base game?", systemImage: "exclamationmark.triangle.fill", color: .orange) }
                }
            }
            Spacer(minLength: 6)
            Button { model.data.addOnMove(tc: tc.id, id: e.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.novaPlain).disabled(index == 0).accessibilityLabel("Move up")
            Button { model.data.addOnMove(tc: tc.id, id: e.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.novaPlain).disabled(index == entries.count - 1).accessibilityLabel("Move down")
            Button { model.data.addOnRemove(tc: tc.id, id: e.id) } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                .buttonStyle(.novaPlain).accessibilityLabel("Remove from \(tc.name)")
            Toggle("Enabled", isOn: Binding(get: { e.isEnabled },
                                            set: { model.data.addOnSetEnabled(tc: tc.id, id: e.id, enabled: $0) }))
                .labelsHidden()
                .cursorClickable { model.data.addOnSetEnabled(tc: tc.id, id: e.id, enabled: !e.isEnabled) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(e.isEnabled ? 1 : 0.6)
    }

    /// Record-overlap verdicts for the plug-ins not on the list yet, against the conversion's loaded data.
    private func analyse() async {
        guard let res = model.data.game?.resources else { return }
        let listed = Set(entries.map(\.id))
        let todo = model.data.plugins.filter { !$0.isTotalConversion && !$0.fileURLs.isEmpty && !listed.contains($0.id) && overlap[$0.id] == nil }
        guard !todo.isEmpty else { return }
        let results = await Task.detached(priority: .utility) {
            todo.map { ($0.id, TCAddOns.overlap(of: $0, in: res)) }
        }.value
        for (id, c) in results { overlap[id] = c }
    }
}
