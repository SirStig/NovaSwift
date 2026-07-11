import SwiftUI
import EVNovaKit
import EVNovaPluginStore

/// Full detail page for one catalog entry: description, screenshots (if any),
/// a link out to a trailer (if any — thumbnail + open externally, never an
/// embedded player), and the install/enable/disable/delete controls.
struct PluginDetailView: View {
    let entry: PluginCatalogEntry
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    private var installedBundle: PluginBundle? {
        model.data.plugins.first { $0.id == entry.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !entry.screenshotNames.isEmpty { screenshots }
                if let videoURL = entry.videoURL { videoLink(videoURL) }
                Text(entry.description).novaFont(.body)
                metadataSection
                actionButton
                legalNote
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).novaFont(.heading, weight: .bold)
            Text("by \(entry.author)").novaFont(.body).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Label(entry.kind.label, systemImage: entry.kind.symbolName)
                if let size = entry.approxSizeMB {
                    Text("· \(formatted(size))")
                }
            }
            .novaFont(.caption).foregroundStyle(.secondary)
        }
    }

    private var screenshots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(entry.screenshotNames, id: \.self) { name in
                    if let url = PluginCatalog.screenshotURL(entryID: entry.id, fileName: name),
                       let image = PlatformImage(contentsOfFile: url.path) {
                        image.swiftUIImage
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func videoLink(_ url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Image(systemName: "play.rectangle.fill").font(.title2)
                Text("Watch on YouTube")
                Spacer()
                Image(systemName: "arrow.up.forward")
            }
            .padding(12)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.tags.isEmpty {
                Text(entry.tags.joined(separator: " · ")).novaFont(.caption).foregroundStyle(.secondary)
            }
            if entry.requiresBase {
                Label("Requires your own EV Nova data", systemImage: "externaldrive.badge.person.crop")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch model.store.state(for: entry) {
        case .notInstalled:
            Button {
                model.store.install(entry, data: model.data)
            } label: {
                Label("Get", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .downloading(let progress):
            VStack(spacing: 8) {
                if let progress { ProgressView(value: progress) } else { ProgressView() }
                Button("Cancel", role: .cancel) { model.store.cancelInstall(entry) }
            }

        case .installed:
            VStack(spacing: 10) {
                if entry.prebundled {
                    Text("Included with the app").novaFont(.caption).foregroundStyle(.secondary)
                } else if let bundle = installedBundle {
                    Toggle("Enabled", isOn: Binding(
                        get: { bundle.isEnabled },
                        set: { model.data.setPlugin(entry.id, enabled: $0) }
                    ))
                    Button("Delete", role: .destructive) {
                        model.store.delete(entry, data: model.data)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // Installed on disk but not yet (re)discovered — reload will pick it up.
                    ProgressView()
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .novaFont(.caption).foregroundStyle(.orange)
                Button("Retry") { model.store.install(entry, data: model.data) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legalNote: some View {
        Text(entry.prebundled
             ? "Bundled with this app with the author's permission."
             : "Downloaded directly from \(entry.sourceHost.displayName). You must own EV Nova to play it.")
            .novaFont(.caption).foregroundStyle(.tertiary)
    }

    private func formatted(_ mb: Double) -> String {
        mb < 1 ? String(format: "%.0f KB", mb * 1024) : String(format: "%.1f MB", mb)
    }
}
