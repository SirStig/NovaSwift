#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NovaSwiftKit

/// Export choices shown on the Project tab.
struct EditorExportOptions: Equatable {
    var format: PluginFormat = .rez
    var embedMetadata = true
    var includeHD = true
    /// Whole effective set incl. the base game (redistribution warning).
    var full = false
}

/// A deferred action waiting on "save changes?" confirmation.
struct EditorPendingAction: Identifiable {
    let id = UUID()
    let title: String
    let run: () -> Void
}

/// Owns the open `EditorModel` and everything around a project's lifecycle:
/// new / open / installed-plug-in editing, save / export / install, recents,
/// crash-safe recovery autosave. Pure project plumbing — no editing UI.
@MainActor
final class EditorProjectStore: ObservableObject {
    let model: EditorModel
    let cache = EditorBrowseCache()
    let lint = EditorLintModel()

    @Published private(set) var recents: [RecentDoc] = []
    @Published var message: String?
    @Published var errorText: String?
    @Published var isBusy = false
    @Published var busyText = ""
    /// Plug-in id (installed bundle) the open document came from / was installed as.
    @Published private(set) var installedID: String?
    @Published var recoveryAvailable = false
    @Published var pending: EditorPendingAction?
    @Published var exportOptions = EditorExportOptions()

    private weak var data: GameDataController?
    private var configured = false
    private var autosaveTimer: Timer?
    private var messageTask: Task<Void, Never>?

    struct RecentDoc: Codable, Identifiable, Hashable {
        var path: String
        var bookmark: Data
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    init() {
        model = EditorModel(document: PluginDocument())
        recents = Self.loadRecents()
    }

    deinit { autosaveTimer?.invalidate() }

    // MARK: Setup

    func configure(data: GameDataController) {
        guard !configured else { return }
        configured = true
        self.data = data
        model.replaceDocument(PluginDocument(base: baseForNew()), url: nil)
        recoveryAvailable = FileManager.default.fileExists(atPath: recoveryURL.path)
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosaveTick() }
        }
    }

    var hasBaseData: Bool { data?.game != nil }

    private func baseForNew() -> ResourceCollection { data?.game?.resources ?? ResourceCollection() }

    // MARK: Status

    func flash(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    // MARK: Dirty guard

    /// Run `action` now if the document is clean, else ask first.
    func guardDirty(_ title: String, _ action: @escaping () -> Void) {
        if model.document.isDirty { pending = EditorPendingAction(title: title, run: action) } else { action() }
    }

    // MARK: New / open

    func newPlugin() {
        model.replaceDocument(PluginDocument(base: baseForNew()), url: nil)
        installedID = nil
        model.format = .rez
        clearRecovery()
        flash("New plug-in")
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.message = "Open a plug-in (.rez, .ndat or classic resource file)"
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let bundle = installedBundle(containing: url)
        runBusy("Opening \(url.lastPathComponent)…") {
            let base = try await self.base(excluding: bundle?.id)
            let box = try await Task.detached(priority: .userInitiated) {
                DocBox(doc: try PluginDocument.open(url: url, base: base))
            }.value
            self.adopt(box.doc, url: url, installed: bundle?.id)
            self.noteRecent(url)
        }
    }

    func openInstalled(_ bundle: PluginBundle) {
        runBusy("Opening \(bundle.name)…") {
            let base = try await self.base(excluding: bundle.id)
            let files = bundle.allFileURLs
            let box = try await Task.detached(priority: .userInitiated) { () -> DocBox in
                if files.count == 1 { return DocBox(doc: try PluginDocument.open(url: files[0], base: base)) }
                var layer = ResourceCollection()
                for f in files { layer.overlay(try ResourceFile.read(contentsOf: f)) }
                return DocBox(doc: PluginDocument(name: bundle.name, base: base, layer: layer))
            }.value
            self.adopt(box.doc, url: files.count == 1 ? files[0] : nil, installed: bundle.id)
            if files.count != 1 { self.flash("Multi-file plug-in merged — use Save As to write one file") }
        }
    }

    private struct DocBox: @unchecked Sendable { let doc: PluginDocument }

    private func adopt(_ doc: PluginDocument, url: URL?, installed: String?) {
        model.replaceDocument(doc, url: url)
        installedID = installed
        if let url { model.format = url.pathExtension.lowercased() == "rez" ? .rez : .classic }
        clearRecovery()
    }

    private func installedBundle(containing url: URL) -> PluginBundle? {
        let p = url.standardizedFileURL.path
        return data?.plugins.first { $0.allFileURLs.contains { $0.standardizedFileURL.path == p } }
    }

    /// Base game + other plug-ins, never including the document itself.
    private func base(excluding id: String?) async throws -> ResourceCollection {
        guard let data else { return ResourceCollection() }
        guard let id, let inputs = data.editorMergeInputs() else { return baseForNew() }
        let plugs = data.plugins.filter { $0.id != id }
        return try await Task.detached(priority: .userInitiated) {
            try GameLibrary.merge(baseFiles: inputs.baseFiles, plugins: plugs, flatPluginOrder: inputs.flatPluginOrder)
        }.value
    }

    private func runBusy(_ text: String, _ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; busyText = text
        Task {
            do { try await work() } catch { errorText = "\(error)" }
            isBusy = false
        }
    }

    // MARK: Save / export / install

    func save() {
        guard let url = model.fileURL else { saveAs(); return }
        write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Plug-in"
        panel.canCreateDirectories = true
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["EV Nova plug-in (.rez)", "Classic resource fork (.ndat)"])
        popup.selectItem(at: model.format == .rez ? 0 : 1)
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup]); stack.spacing = 8
        panel.accessoryView = stack
        panel.nameFieldStringValue = Self.fileName(model.document.name, ext: model.format == .rez ? "rez" : "ndat")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        let fmt: PluginFormat = popup.indexOfSelectedItem == 0 ? .rez : .classic
        let ext = fmt == .rez ? "rez" : "ndat"
        if !["rez", "ndat"].contains(url.pathExtension.lowercased()) { url.appendPathExtension(ext) }
        model.format = fmt
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try model.document.save(to: url, format: model.format, embedMetadata: exportOptions.embedMetadata)
            model.fileURL = url
            model.metadataChanged()
            clearRecovery()
            noteRecent(url)
            flash("Saved \(url.lastPathComponent)")
        } catch { errorText = "Couldn't save: \(error)" }
    }

    func exportBytes(_ o: EditorExportOptions) throws -> Data {
        let d = model.document
        if o.full {
            return try d.exportFull(format: o.format, acknowledgingBaseRedistribution: true, embedMetadata: o.embedMetadata)
        }
        if o.includeHD { return try d.exportData(format: o.format, embedMetadata: o.embedMetadata) }
        var layer = ResourceCollection()
        for (t, rs) in d.layer.byType where t != GraphicsEnhancementType.descriptor && t != GraphicsEnhancementType.blob {
            for r in rs.values { layer.add(r) }
        }
        let tmp = PluginDocument(name: d.name, author: d.author, version: d.version, notes: d.notes, layer: layer)
        return try tmp.exportData(format: o.format, embedMetadata: o.embedMetadata)
    }

    /// Export a copy (does not change the open document's file or dirty state).
    func exportCopy() {
        let o = exportOptions
        if o.full {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Full export redistributes game data"
            a.informativeText = "A full export contains the base game's own resources. Only share it if you are allowed to redistribute them. Plain plug-in exports contain only your changes."
            a.addButton(withTitle: "Export Anyway"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.nameFieldStringValue = Self.fileName(model.document.name + (o.full ? " (full)" : ""),
                                                   ext: o.format == .rez ? "rez" : "ndat")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportBytes(o).write(to: url, options: .atomic); flash("Exported \(url.lastPathComponent)") }
        catch { errorText = "Export failed: \(error)" }
    }

    /// Copy into NovaSwift's plug-ins folder and reload the game data.
    func installIntoPlugins() {
        guard let data else { return }
        runBusy("Installing…") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(Self.fileName(self.model.document.name,
                                                               ext: self.model.format == .rez ? "rez" : "ndat"))
            try self.model.document.save(to: tmp, format: self.model.format, embedMetadata: self.exportOptions.embedMetadata)
            await Task.yield()
            let id = try data.importPlugin(from: tmp)
            try? FileManager.default.removeItem(at: dir)
            self.installedID = id
            self.model.fileURL = data.importedPluginsDir.appendingPathComponent(id)
            self.model.metadataChanged()
            self.clearRecovery()
            self.flash("Installed \(id) — enable it in Plugins to play with it")
        }
    }

    static func fileName(_ name: String, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "Untitled Plug-in" }
        return s + "." + ext
    }

    // MARK: Recents

    private static let recentsKey = "NovaSwiftEditor.recents.v1"

    private static func loadRecents() -> [RecentDoc] {
        guard let d = UserDefaults.standard.data(forKey: recentsKey),
              let r = try? JSONDecoder().decode([RecentDoc].self, from: d) else { return [] }
        return r
    }

    private func noteRecent(_ url: URL) {
        let bm = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        recents.removeAll { $0.path == url.path }
        recents.insert(RecentDoc(path: url.path, bookmark: bm), at: 0)
        if recents.count > 10 { recents.removeLast(recents.count - 10) }
        if let d = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(d, forKey: Self.recentsKey) }
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    func open(recent: RecentDoc) {
        var stale = false
        if !recent.bookmark.isEmpty,
           let url = try? URL(resolvingBookmarkData: recent.bookmark, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            open(url: url)
        } else {
            open(url: URL(fileURLWithPath: recent.path))
        }
    }

    // MARK: Recovery autosave

    private var recoveryDir: URL {
        NovaStorage.root.appendingPathComponent("NovaSwift/Editor/Recovery", isDirectory: true)
    }
    private var recoveryURL: URL { recoveryDir.appendingPathComponent("recovery.rez") }
    private var recoveryInfoURL: URL { recoveryDir.appendingPathComponent("recovery.json") }

    private struct RecoveryInfo: Codable { var path: String?; var installedID: String?; var classic: Bool }

    private func autosaveTick() {
        guard model.document.isDirty else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
            // Always rez on disk; the real format is kept in the info file.
            try model.document.exportData(format: .rez).write(to: recoveryURL, options: .atomic)
            let info = RecoveryInfo(path: model.fileURL?.path, installedID: installedID, classic: model.format == .classic)
            try JSONEncoder().encode(info).write(to: recoveryInfoURL, options: .atomic)
        } catch { /* best effort */ }
    }

    func clearRecovery() {
        try? FileManager.default.removeItem(at: recoveryURL)
        try? FileManager.default.removeItem(at: recoveryInfoURL)
        recoveryAvailable = false
    }

    func restoreRecovery() {
        let info = (try? Data(contentsOf: recoveryInfoURL)).flatMap { try? JSONDecoder().decode(RecoveryInfo.self, from: $0) }
        let url = recoveryURL
        runBusy("Restoring…") {
            let base = try await self.base(excluding: info?.installedID)
            let box = try await Task.detached { DocBox(doc: try PluginDocument.open(url: url, base: base)) }.value
            let doc = box.doc
            // Opened files are clean; a recovered document is not.
            let n = doc.name; doc.name = n + "~"; doc.name = n
            self.model.replaceDocument(doc, url: info?.path.map { URL(fileURLWithPath: $0) })
            self.model.format = (info?.classic ?? false) ? .classic : .rez
            self.installedID = info?.installedID
            self.recoveryAvailable = false
            self.flash("Recovered unsaved work")
        }
    }
}
#endif
