#if os(macOS)
import SwiftUI
import AppKit
import QuickLookUI
import NovaSwiftKit

/// Everything in the plug-in's folder that isn't resource data: fonts, movies, music, pilots,
/// launchers, docs, images and `.nsx` graphics packs. Sizes are measured off the main actor;
/// "Add File" copies into the folder, "Remove" moves to the Trash after confirmation.
struct BundleFilesView: View {
    @ObservedObject var model: EditorModel

    enum Group: String, CaseIterable, Identifiable {
        case plugin = "Plug-in Files", packs = "Graphics Packs", fonts = "Fonts", movies = "Movies", music = "Music"
        case pilots = "Pilots", launchers = "Launchers", docs = "Docs", images = "Images", other = "Other"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .plugin: return "shippingbox"
            case .packs: return "cube"
            case .fonts: return "textformat"
            case .movies: return "film"
            case .music: return "music.note"
            case .pilots: return "person.crop.square"
            case .launchers: return "play.rectangle"
            case .docs: return "doc.text"
            case .images: return "photo"
            case .other: return "doc"
            }
        }

        static func classify(_ url: URL) -> Group {
            let ext = url.pathExtension.lowercased(), name = url.lastPathComponent.lowercased()
            if ext == "nsx" { return .packs }
            if name.hasPrefix("readme") || name.hasPrefix("read me") { return .docs }
            switch ext {
            case "ttf", "otf", "ttc", "dfont", "suit", "fon": return .fonts
            case "mov", "mp4", "m4v", "avi", "mpg", "mpeg", "qt": return .movies
            case "mp3", "m4a", "aif", "aiff", "wav", "mid", "midi", "ogg", "flac", "caf", "aac", "song": return .music
            case "plt", "evpilot", "pilot": return .pilots
            case "nplay", "app", "command", "sh", "exe", "bat": return .launchers
            case "txt", "md", "rtf", "rtfd", "pdf", "html", "htm", "doc", "docx": return .docs
            case "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "icns", "ico", "webp", "heic": return .images
            default: return name.contains("pilot") && ext.isEmpty ? .pilots : .other
            }
        }
    }

    struct FileItem: Identifiable, Hashable, Sendable {
        let url: URL
        let group: Group
        let size: Int64
        let isDirectory: Bool
        /// Resource files and `.nsx` packs are loaded into the document; they can be shown, not removed here.
        let removable: Bool
        var id: URL { url }
    }

    @State private var items: [FileItem]?
    @State private var collapsed: Set<Group> = []
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(alignment: .top) { EditorRefreshStrip(active: items == nil) }
            content
        }
        .background(Color(white: 0.11))
        .task(id: model.bundle) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bundle Files").font(.system(size: 16, weight: .semibold))
                Text(model.bundle?.folderURL?.path ?? "No plug-in folder")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            if let folder = model.bundle?.folderURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                    Label("Reveal Folder", systemImage: "folder")
                }.controlSize(.small)
            }
            Button { addFiles() } label: { Label("Add File…", systemImage: "plus") }
                .controlSize(.small).disabled(model.bundle?.folderURL == nil)
                .help(model.bundle?.folderURL == nil ? "Save or open the plug-in as a folder to add files" : "Copy files into the plug-in folder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.bundle == nil {
            EditorEmptyState(icon: "doc", title: "A single-file plug-in",
                             subtitle: "This plug-in isn't a folder, so it has no fonts, movies, music or other bundle files.\nOpen an installed plug-in folder to see them here.")
        } else if let items {
            if items.isEmpty {
                EditorEmptyState(icon: "folder", title: "No other files",
                                 subtitle: "The plug-in folder holds only resource files.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Group.allCases) { g in
                            let rows = items.filter { $0.group == g }
                            if !rows.isEmpty {
                                SwiftUI.Section {
                                    if !collapsed.contains(g) { ForEach(rows) { row($0) } }
                                } header: { groupHeader(g, rows) }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        } else {
            SkeletonList(rows: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func groupHeader(_ g: Group, _ rows: [FileItem]) -> some View {
        let total = rows.reduce(Int64(0)) { $0 + $1.size }
        let isCollapsed = collapsed.contains(g)
        return Button {
            if isCollapsed { collapsed.remove(g) } else { collapsed.insert(g) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: g.icon).foregroundStyle(novaAmber).frame(width: 18)
                Text(g.rawValue).font(.system(size: 13, weight: .semibold))
                Text("\(rows.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(Self.sizeText(total)).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.15))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ f: FileItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(relativePath(f.url)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.sizeText(f.size)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            Button { BundleQuickLook.shared.show(f.url) } label: { Image(systemName: "eye") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quick Look")
            Button { remove(f) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(f.removable ? Color.red.opacity(0.85) : Color.secondary.opacity(0.3))
                .disabled(!f.removable)
                .help(f.removable ? "Move to Trash…" : "Loaded into the document — manage it from Project & Export")
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(f.url) }
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = model.bundle?.folderURL?.standardizedFileURL.path else { return url.deletingLastPathComponent().path }
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : url.deletingLastPathComponent().path
    }

    nonisolated static func sizeText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: Loading

    private func load() async {
        guard let b = model.bundle else { items = nil; return }
        items = nil
        let out = await Task.detached(priority: .utility) { Self.scan(b) }.value
        if Task.isCancelled { return }
        items = out
    }

    nonisolated private static func scan(_ b: EditorBundleInfo) -> [FileItem] {
        var out: [FileItem] = []
        var seen = Set<String>()
        func add(_ url: URL, group: Group?, removable: Bool) {
            let u = url.standardizedFileURL
            guard seen.insert(u.path).inserted else { return }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            out.append(FileItem(url: u, group: group ?? Group.classify(u), size: size(of: u, isDirectory: isDir),
                                isDirectory: isDir, removable: removable))
        }
        for u in b.resourceFiles { add(u, group: .plugin, removable: false) }
        for u in b.graphicsPacks { add(u, group: .packs, removable: false) }
        for u in b.otherFiles { add(u, group: nil, removable: true) }
        return out.sorted {
            ($0.group.rawValue, $0.url.lastPathComponent.lowercased()) < ($1.group.rawValue, $1.url.lastPathComponent.lowercased())
        }
    }

    nonisolated private static func size(of url: URL, isDirectory: Bool) -> Int64 {
        let fm = FileManager.default
        guard isDirectory else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Actions

    private func addFiles() {
        guard let folder = model.bundle?.folderURL else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose files to copy into \(folder.lastPathComponent)"
        guard panel.runModal() == .OK else { return }
        var added: [URL] = [], failures = 0
        let fm = FileManager.default
        for src in panel.urls {
            var dest = folder.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
                dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do { try fm.copyItem(at: src, to: dest); added.append(dest) } catch { failures += 1 }
        }
        if !added.isEmpty { model.bundle?.otherFiles.append(contentsOf: added) }
        status = failures == 0 ? "Added \(added.count) file\(added.count == 1 ? "" : "s")"
                               : "Added \(added.count), \(failures) failed"
    }

    private func remove(_ f: FileItem) {
        let alert = NSAlert()
        alert.messageText = "Move “\(f.url.lastPathComponent)” to the Trash?"
        alert.informativeText = "It will be removed from the plug-in folder. You can restore it from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: f.url, resultingItemURL: nil)
            let gone = f.url.standardizedFileURL.path
            model.bundle?.otherFiles.removeAll { $0.standardizedFileURL.path == gone }
            status = "Moved \(f.url.lastPathComponent) to the Trash"
        } catch {
            status = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}

/// Quick Look for bundle files via the shared preview panel.
final class BundleQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = BundleQuickLook()
    private var urls: [URL] = []

    @MainActor func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { NSWorkspace.shared.open(url); return }
        urls = [url]
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
#endif
