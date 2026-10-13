import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Rounded icon tile: the catalog icon, else (for installed plug-ins) one built
/// from the plug-in's own resources, else a symbol for the plug-in's kind.
struct PluginIconTile: View {
    @EnvironmentObject private var model: AppModel
    let entry: PluginCatalogEntry
    var size: CGFloat = 56
    @State private var generated: Image?

    private var isInstalled: Bool { model.store.status(for: entry).isInstalled }

    var body: some View {
        RemoteImage(url: entry.iconURL) {
            ZStack {
                symbolTile
                if let generated {
                    generated.resizable().aspectRatio(contentMode: .fit).padding(size * 0.08)
                        .background(Color.black.opacity(0.35))
                }
            }
        }
        .task(id: "\(entry.id)|\(isInstalled)|\(entry.iconURL == nil)") {
            generated = nil
            guard isInstalled else { return }
            let id = entry.id, root = model.data.importedPluginsDir
            let data = await Task.detached(priority: .utility) {
                PluginIconGenerator.iconPNG(for: id, pluginsRoot: root)
            }.value
            guard let data else { return }
            #if canImport(UIKit)
            if let ui = UIImage(data: data) { generated = Image(uiImage: ui) }
            #elseif canImport(AppKit)
            if let ns = NSImage(data: data) { generated = Image(nsImage: ns) }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var symbolTile: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.75), tint.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .totalConversion: return pluginTCTint
        case .patch: return .teal
        case .gameplay: return .orange
        default: return .gray
        }
    }
}

struct PluginBadge: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
        .lineLimit(1)
    }
}

/// Install-state pill used on cards and in the detail header: Get / Update / Installed / Failed,
/// and while a download runs, a compact progress indicator.
struct PluginStateLabel: View {
    @EnvironmentObject private var model: AppModel
    let entry: PluginCatalogEntry

    private func pill(_ text: String, _ symbol: String, _ color: Color, filled: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Color.black : color)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(filled ? color : color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.4)))
            .lineLimit(1)
    }

    var body: some View {
        if let t = model.store.transfer(for: entry) {
            switch t {
            case .working(let p):
                pill(p.map { "\(Int($0 * 100))%" } ?? "Working", "arrow.down.circle", pluginAccent)
            case .failed:
                pill("Failed", "exclamationmark.triangle.fill", .orange)
            }
        } else {
            switch model.store.status(for: entry) {
            case .notInstalled: pill("Get", "arrow.down.circle.fill", pluginAccent)
            case .installed: pill("Installed", "checkmark.circle.fill", .green)
            case .updateAvailable: pill("Update", "arrow.triangle.2.circlepath.circle.fill", .orange)
            }
        }
    }
}

struct PluginCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: PluginCatalogEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    PluginIconTile(entry: entry)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        Text("by \(entry.author)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if case .working(let p)? = model.store.transfer(for: entry) {
                    PluginProgressBar(progress: p)
                }
                HStack(spacing: 6) {
                    if entry.isTotalConversion {
                        PluginBadge(text: "Total conversion", systemImage: "sparkles", color: pluginTCTint)
                    }
                    ForEach(entry.tags.prefix(entry.isTotalConversion ? 1 : 2), id: \.self) { PluginBadge(text: $0) }
                    Spacer(minLength: 0)
                    PluginStateLabel(entry: entry)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.novaPlain)
        .accessibilityLabel("\(entry.name) by \(entry.author)")
    }
}

/// Large card for the "Featured total conversions" row: icon, name and blurb over procedural space art.
struct PluginFeaturedCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: PluginCatalogEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    PluginIconTile(entry: entry, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.title3.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                        Text("by \(entry.author)").font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.summary).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if case .working(let p)? = model.store.transfer(for: entry) { PluginProgressBar(progress: p) }
                HStack(spacing: 6) {
                    PluginBadge(text: "Total conversion", systemImage: "sparkles", color: pluginTCTint)
                    ForEach(entry.tags.prefix(1), id: \.self) { PluginBadge(text: $0) }
                    Spacer(minLength: 0)
                    PluginStateLabel(entry: entry)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(PluginSpaceArt(tint: pluginTCTint, seed: pluginArtSeed(entry.id)))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(pluginTCTint.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.novaPlain)
        .accessibilityLabel("Featured: \(entry.name) by \(entry.author)")
    }
}
