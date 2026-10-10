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
        case .totalConversion: return .indigo
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

/// Install-state control used on cards and in the detail header.
struct PluginStateLabel: View {
    @EnvironmentObject private var model: AppModel
    let entry: PluginCatalogEntry

    var body: some View {
        if let t = model.store.transfer(for: entry) {
            switch t {
            case .working(let p):
                if let p { ProgressView(value: p).frame(width: 60) } else { ProgressView() }
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        } else {
            switch model.store.status(for: entry) {
            case .notInstalled:
                Label("Get", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            case .updateAvailable:
                Label("Update", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }
}

struct PluginCard: View {
    let entry: PluginCatalogEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PluginIconTile(entry: entry)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline).lineLimit(2)
                        Text("by \(entry.author)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if entry.isTotalConversion {
                        PluginBadge(text: "Total conversion", systemImage: "sparkles", color: .indigo)
                    }
                    ForEach(entry.tags.prefix(entry.isTotalConversion ? 1 : 2), id: \.self) { PluginBadge(text: $0) }
                    Spacer(minLength: 0)
                    PluginStateLabel(entry: entry)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.novaPlain)
        .accessibilityLabel("\(entry.name) by \(entry.author)")
    }
}
