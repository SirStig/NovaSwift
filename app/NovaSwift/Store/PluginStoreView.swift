import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore

/// Browsable catalog of downloadable plug-ins/total conversions. Fully usable
/// offline (all metadata + screenshots are bundled); only tapping Install
/// needs network, since the actual file streams from its original host —
/// see docs/MOBILE_AND_PLUGINS.md §3 and `PluginDownloader`.
struct PluginStoreView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var kindFilter: PluginKind?

    private var filtered: [PluginCatalogEntry] {
        PluginCatalog.all.filter { entry in
            let matchesKind = kindFilter == nil || entry.kind == kindFilter
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesQuery = q.isEmpty
                || entry.name.lowercased().contains(q)
                || entry.author.lowercased().contains(q)
                || entry.tags.contains { $0.lowercased().contains(q) }
            return matchesKind && matchesQuery
        }
    }

    var body: some View {
        List {
            if PluginCatalog.all.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Store catalog unavailable",
                    message: "No plug-in catalog is bundled with this build.")
            } else {
                Section {
                    filterPicker
                }
                Section(footer: Text("Plug-in files download directly from the author's original host — nothing is mirrored by this app. You must own EV Nova to play any of them.")) {
                    ForEach(filtered) { entry in
                        NavigationLink { PluginDetailView(entry: entry) } label: { row(entry) }
                    }
                    if filtered.isEmpty {
                        Text("No plug-ins match “\(query)”.").novaFont(.body).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .novaHiddenScrollContentBackground()
        .searchable(text: $query, prompt: "Search plug-ins")
        .navigationTitle("Store")
    }

    private var filterPicker: some View {
        Picker("Kind", selection: $kindFilter) {
            Text("All Kinds").tag(PluginKind?.none)
            ForEach([PluginKind.totalConversion, .patch, .gameplay], id: \.self) { kind in
                Text(kind.label).tag(PluginKind?.some(kind))
            }
        }
    }

    private func row(_ entry: PluginCatalogEntry) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: entry).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).novaFont(.heading)
                Text(entry.summary).novaFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(entry.kind.label).novaFont(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            statusBadge(for: entry)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(for entry: PluginCatalogEntry) -> some View {
        switch model.store.state(for: entry) {
        case .notInstalled:
            Text("Get").novaFont(.button, weight: .semibold).foregroundStyle(.tint)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress).frame(width: 36)
            } else {
                ProgressView().frame(width: 20, height: 20)
            }
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func thumbnail(for entry: PluginCatalogEntry) -> some View {
        if let firstName = entry.screenshotNames.first,
           let url = PluginCatalog.screenshotURL(entryID: entry.id, fileName: firstName),
           let image = PlatformImage(contentsOfFile: url.path) {
            image.swiftUIImage
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.15))
                .overlay(Image(systemName: entry.kind.symbolName).foregroundStyle(.secondary))
        }
    }
}
