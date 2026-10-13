#if os(macOS)
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import NovaSwiftKit

/// Export choices shown on the Project tab.
struct EditorExportOptions: Equatable {
    var format: PluginFormat = .rez
    var embedMetadata = true
    var includeHD = true
    /// Folder saves: fold `.nsx` graphics packs into the plug-in's data file (as `NSgx`/`NSbl`)
    /// instead of writing them back as `.nsx` folders.
    var embedPackHD = false
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
    private var conflictDebounce: AnyCancellable?
    /// `dataRevision` the conflicts were last computed for (skips Save/metadata-only bumps).
    private var conflictsRevision = -1

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
        replace(PluginDocument(base: baseForNew()), url: nil)
        recoveryAvailable = FileManager.default.fileExists(atPath: recoveryInfoURL.path)
            || FileManager.default.fileExists(atPath: recoveryURL.path)
        // Edits change which keys the layer defines: re-intersect with the other plug-ins' (cached)
        // key sets once the author pauses for a second. Never blocks; stale results are dropped.
        conflictDebounce = model.$revision
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.model.dataRevision != self.conflictsRevision else { return }
                    self.refreshConflicts()
                }
            }
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

    /// Swap the open document. Derived caches are dropped first so the UI shows skeletons
    /// (not the previous document's lists) while the new merged view is assembled off-main.
    private func replace(_ doc: PluginDocument, url: URL?) {
        cache.reset()
        model.replaceDocument(doc, url: url)
    }

    func newPlugin() {
        replace(PluginDocument(base: baseForNew()), url: nil)
        installedID = nil
        model.bundle = nil
        model.conflicts = [:]
        conflictGeneration += 1
        model.format = .rez
        clearRecovery()
        flash("New plug-in")
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.message = "Open a plug-in file (.rez, .ndat, classic), a plug-in folder, a total conversion, or an .nsx graphics pack"
        p.allowsMultipleSelection = false
        p.canChooseFiles = true
        p.canChooseDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url: url)
    }

    private struct OpenFailure: Swift.Error, CustomStringConvertible { let description: String }

    func open(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            let installed = installedBundle(forFolder: url)
            openLayout(installed: installed) {
                if PluginBundleLoader.isGraphicsPack(url) { return PluginBundleLoader.layout(ofPack: url) }
                guard let l = PluginBundleLoader.layout(ofFolder: url) else {
                    throw OpenFailure(description: "\(url.lastPathComponent) holds no plug-in files (.rez / .ndat), total conversion or .nsx graphics pack")
                }
                return l
            }
            noteRecent(url)
            return
        }
        let bundle = installedBundle(containing: url)
        openLayout(installed: bundle) {
            // A file of a multi-file plug-in (or one with a pack beside it) opens the whole plug-in.
            if let bundle {
                let l = PluginBundleLoader.layout(of: bundle)
                if l.dataFiles.count > 1 || !l.graphicsPacks.isEmpty || l.isTotalConversion { return l }
            }
            return PluginBundleLoader.layout(ofFile: url)
        }
        noteRecent(url)
    }

    func openInstalled(_ bundle: PluginBundle) {
        openLayout(installed: bundle) { PluginBundleLoader.layout(of: bundle) }
    }

    private struct DocBox: @unchecked Sendable {
        let doc: PluginDocument
        var layout: PluginLayout?
        var skippedPacks: [URL] = []
        var warnings: [String] = []
    }

    /// The one open path: scan the plug-in's layout, build its base, then read every file and
    /// pack off the main actor. See docs/PLUGIN_EDITOR.md, "Plug-in shapes".
    private func openLayout(installed: PluginBundle?, _ build: @escaping @Sendable () throws -> PluginLayout) {
        runBusy("Opening plug-in…") {
            self.busyText = "Looking at the plug-in's files…"
            let layout = try await Task.detached(priority: .userInitiated) { try build() }.value
            self.busyText = "Opening \(layout.name)…"
            let base: ResourceCollection
            if layout.isTotalConversion { base = try await self.totalConversionBase(layout) }
            else { base = try await self.base(excluding: installed?.id) }
            self.busyText = "Reading \(layout.name)…"
            let box = try await Task.detached(priority: .userInitiated) { () -> DocBox in
                let loaded = try PluginBundleLoader.load(layout)
                let doc = PluginDocument.open(files: loaded.files, defaultName: layout.name, base: base)
                return DocBox(doc: doc, layout: layout, skippedPacks: loaded.skippedPacks, warnings: loaded.warnings)
            }.value
            self.adopt(box, installed: installed?.id)
            if let w = box.warnings.first { self.flash(w) }
        }
    }

    /// A total conversion's document base. The conversion replaces the stock `Nova Files`, so the
    /// stock game is NOT mixed in (its ids mean different things there); the only shared piece is
    /// `Nova.rez`, which the original loads for every scenario, and only when the conversion
    /// doesn't ship its own. Otherwise the base is empty and the layer is the conversion itself.
    private func totalConversionBase(_ layout: PluginLayout) async throws -> ResourceCollection {
        guard let inputs = data?.editorMergeInputs() else { return ResourceCollection() }
        let hasOwn = layout.novaFiles.contains { $0.lastPathComponent.uppercased() == "NOVA.REZ" }
        let shared = hasOwn ? [] : inputs.baseFiles.filter { $0.lastPathComponent.uppercased() == "NOVA.REZ" }
        guard !shared.isEmpty else { return ResourceCollection() }
        busyText = "Loading the shared Nova.rez…"
        return try await Task.detached(priority: .userInitiated) {
            try GameLibrary.merge(baseFiles: shared, plugins: [])
        }.value
    }

    private func adopt(_ box: DocBox, installed: String?) {
        let doc = box.doc
        busyText = "Preparing data…"
        let layout = box.layout
        // A multi-file / pack document is addressed by its folder; a single file by itself.
        let url: URL? = doc.usesFolderLayout ? layout?.root : layout?.dataFiles.first
        replace(doc, url: url)
        installedID = installed
        if let primary = doc.primaryFile, let f = doc.fileFormats[primary] { model.format = f }
        else if let u = layout?.dataFiles.first { model.format = u.pathExtension.lowercased() == "rez" ? .rez : .classic }
        if let layout { model.bundle = Self.bundleInfo(layout, skippedPacks: box.skippedPacks, installedID: installed) }
        clearRecovery()
        refreshConflicts()
    }

    /// `EditorModel.bundle` for an opened / saved layout.
    private static func bundleInfo(_ l: PluginLayout, skippedPacks: [URL] = [], installedID: String?) -> EditorBundleInfo {
        let lone = l.dataFiles.count == 1 && l.graphicsPacks.isEmpty && l.otherFiles.isEmpty && !l.isTotalConversion
        let skipped = Set(skippedPacks.map { $0.standardizedFileURL.path })
        return EditorBundleInfo(name: l.name, folderURL: lone ? nil : l.root, resourceFiles: l.dataFiles,
                                graphicsPacks: l.graphicsPacks.filter { !skipped.contains($0.standardizedFileURL.path) },
                                otherFiles: l.otherFiles, isTotalConversion: l.isTotalConversion,
                                installedID: installedID)
    }

    private func installedBundle(containing url: URL) -> PluginBundle? {
        let p = url.standardizedFileURL.path
        return data?.plugins.first { $0.allFileURLs.contains { $0.standardizedFileURL.path == p } }
    }

    private func installedBundle(forFolder url: URL) -> PluginBundle? {
        let p = url.standardizedFileURL.path
        return data?.plugins.first { b in
            if b.id == url.lastPathComponent { return true }
            if let f = b.folderURL?.standardizedFileURL.path, f == p || p.hasPrefix(f + "/") { return true }
            return false
        }
    }

    // MARK: Conflicts

    private let conflictScanner = EditorConflictScanner()
    private var conflictGeneration = 0

    /// Which other enabled plug-ins define the keys this document defines. Runs off-main after
    /// opening / saving and never blocks either; parsed key sets are cached per file.
    func refreshConflicts() {
        conflictGeneration += 1
        let gen = conflictGeneration
        conflictsRevision = model.dataRevision
        guard let data, !(model.bundle?.isTotalConversion ?? false) else { setConflicts([:]); return }
        let thisID = installedID
        let enabled = data.plugins.filter { $0.isEnabled && $0.id != thisID }
        // With a total conversion selected, none of the global plug-ins load.
        guard !enabled.contains(where: \.isTotalConversion) else { setConflicts([:]); return }
        let flat = data.editorMergeInputs()?.flatPluginOrder ?? true
        var files: [(name: String, url: URL)] = []
        for b in enabled { for u in b.fileURLs.sorted(by: { Self.nameKey($0) < Self.nameKey($1) }) { files.append((b.name, u)) } }
        if flat {
            files = files.enumerated().sorted { a, b in
                let ka = Self.nameKey(a.element.url), kb = Self.nameKey(b.element.url)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
        }
        let layer = model.document.layer
        let scanner = conflictScanner
        let inputs = files
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.conflicts(of: layer, with: inputs)
            }.value
            guard let self, gen == self.conflictGeneration else { return }
            self.setConflicts(result)
        }
    }

    /// Publish only real changes, so the debounced refresh doesn't re-render views for nothing.
    private func setConflicts(_ c: [ResourceKey: [String]]) {
        if model.conflicts != c { model.conflicts = c }
    }

    private static func nameKey(_ u: URL) -> String { u.lastPathComponent.uppercased() + "\u{0}" + u.lastPathComponent }

    /// Base game + other plug-ins, never including the document itself.
    private func base(excluding id: String?) async throws -> ResourceCollection {
        guard let data else { return ResourceCollection() }
        guard let id, let inputs = data.editorMergeInputs() else { return baseForNew() }
        let plugs = data.plugins.filter { $0.id != id }
        busyText = "Merging the base game and other plug-ins…"
        return try await Task.detached(priority: .userInitiated) {
            try GameLibrary.merge(baseFiles: inputs.baseFiles, plugins: plugs, flatPluginOrder: inputs.flatPluginOrder)
        }.value
    }

    private func runBusy(_ text: String, errorPrefix: String = "", _ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; busyText = text
        Task {
            do { try await work() } catch { errorText = errorPrefix + "\(error)" }
            isBusy = false
        }
    }

    // MARK: Save / export / install

    func save() {
        if model.document.usesFolderLayout { saveFolder(); return }
        guard let url = model.fileURL else { saveAs(); return }
        write(to: url)
    }

    func saveAs() {
        let doc = model.document
        guard doc.usesFolderLayout else { saveAsSingleFile(); return }
        let a = NSAlert()
        a.messageText = "Save \(doc.sourceFiles.count) files"
        a.informativeText = "This plug-in is made of \(doc.sourceFiles.count) files (data files and/or .nsx graphics packs). Save them to a new folder, each in its own file, or merge everything into one file?"
        a.addButton(withTitle: "Save to Folder…")
        a.addButton(withTitle: "Merge into One File…")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: saveToNewFolder()
        case .alertSecondButtonReturn: saveAsSingleFile()
        default: break
        }
    }

    private func saveAsSingleFile() {
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

    /// Single-file save. The document is snapshotted on the main actor; encoding and the file
    /// write run on a background task behind the busy overlay.
    private func write(to url: URL) {
        let doc = model.document
        let fmt = model.format
        let job = doc.makeExportJob(format: fmt, embedMetadata: exportOptions.embedMetadata)
        let collapse = doc.usesFolderLayout
        runBusy("Saving \(url.lastPathComponent)…", errorPrefix: "Couldn't save: ") {
            try await Task.detached(priority: .userInitiated) {
                try job.encode().write(to: url, options: .atomic)
            }.value
            doc.markSaved(atChangeCount: job.changeCount)
            // A merged multi-file document is now one file; later saves go to it.
            if collapse { doc.collapseSources(to: url.lastPathComponent, format: fmt) }
            self.model.fileURL = url
            self.model.bundle = Self.bundleInfo(PluginBundleLoader.layout(ofFile: url), installedID: self.installedID)
            self.model.metadataChanged()
            self.clearRecovery()
            self.noteRecent(url)
            self.flash("Saved \(url.lastPathComponent)")
            self.refreshConflicts()
        }
    }

    private func saveToNewFolder() {
        let p = NSOpenPanel()
        p.title = "Save Plug-in Files"
        p.message = "Choose (or create) a folder for the plug-in's files"
        p.prompt = "Save Here"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        saveFolder(to: url)
    }

    /// Save a multi-file / pack document: only files that changed are rewritten (all of them for
    /// a new folder), each in its original format, atomically; `.nsx` packs go back as `.nsx`
    /// folders unless "embed HD in plug-in file" is on. Encoding and writing run off-main. Saving
    /// to a new folder also copies the bundle's other files (fonts, movies, music, pilots, `.nplay`,
    /// readmes, images…) there, keeping their relative paths.
    private func saveFolder(to dest: URL? = nil) {
        let doc = model.document
        guard let root = dest ?? model.bundle?.folderURL else { saveToNewFolder(); return }
        let plan = doc.makeSavePlan(rewriteAll: dest != nil, embedPacksInFile: exportOptions.embedPackHD,
                                    embedMetadata: exportOptions.embedMetadata)
        let oldBundle = model.bundle
        runBusy("Saving \(doc.name)…", errorPrefix: "Couldn't save: ") {
            _ = try await Task.detached(priority: .userInitiated) { try plan.write(to: root) }.value
            doc.didSave(plan)
            var copyNote = ""
            if dest != nil {
                var copied: PluginBundleLoader.CopyResult?
                if let from = oldBundle?.folderURL, let others = oldBundle?.otherFiles, !others.isEmpty,
                   from.standardizedFileURL.path != root.standardizedFileURL.path {
                    self.busyText = "Copying \(others.count) other file\(others.count == 1 ? "" : "s")…"
                    copied = await Task.detached(priority: .userInitiated) {
                        PluginBundleLoader.copyBundleFiles(others, from: from, to: root) { done, total in
                            guard done == total || done % 5 == 0 else { return }
                            Task { @MainActor in self.busyText = "Copying other files (\(done) of \(total))…" }
                        }
                    }.value
                    if let c = copied {
                        copyNote = c.copiedCount > 0 ? " and copied \(c.copiedCount) other file\(c.copiedCount == 1 ? "" : "s")" : ""
                        if !c.failed.isEmpty {
                            self.errorText = "Saved the plug-in, but \(c.failed.count) other file(s) couldn't be copied: "
                                + c.failed.prefix(3).joined(separator: "; ")
                        }
                    }
                } else if let others = oldBundle?.otherFiles, oldBundle?.folderURL?.standardizedFileURL.path == root.standardizedFileURL.path {
                    copied = PluginBundleLoader.CopyResult(present: others)   // saved in place: nothing moves
                }
                // The document now lives in the new folder.
                var b = oldBundle ?? EditorBundleInfo(name: doc.name, folderURL: root, resourceFiles: [],
                                                      graphicsPacks: [], otherFiles: [],
                                                      isTotalConversion: false, installedID: nil)
                b.folderURL = root
                b.resourceFiles = doc.sourceFiles.filter { !PluginDocument.isPackKey($0) }
                    .map { root.appendingPathComponent($0) }
                b.graphicsPacks = doc.sourceFiles.filter(PluginDocument.isPackKey)
                    .map { root.appendingPathComponent(String($0.dropFirst(PluginDocument.packPrefix.count)), isDirectory: true) }
                b.otherFiles = copied?.present ?? []
                b.installedID = nil
                self.model.bundle = b
                self.model.fileURL = root
                self.installedID = nil
                self.noteRecent(root)
            }
            self.model.metadataChanged()
            self.clearRecovery()
            let n = plan.dataFiles.count + plan.packs.count
            self.flash(n == 0 ? "Nothing to write — no file changed" : "Saved \(n) file\(n == 1 ? "" : "s")\(copyNote)")
            self.refreshConflicts()
        }
    }

    /// Snapshot of what an export with these options writes (cheap; encode it off-main).
    func exportJob(_ o: EditorExportOptions) -> PluginDocument.ExportJob {
        model.document.makeExportJob(format: o.format, includeBase: o.full, embedMetadata: o.embedMetadata,
                                     excludeHD: !o.full && !o.includeHD)
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
        let job = exportJob(o)
        runBusy("Exporting \(url.lastPathComponent)…", errorPrefix: "Export failed: ") {
            try await Task.detached(priority: .userInitiated) {
                try job.encode().write(to: url, options: .atomic)
            }.value
            self.flash("Exported \(url.lastPathComponent)")
        }
    }

    /// Copy into NovaSwift's plug-ins folder and reload the game data.
    func installIntoPlugins() {
        guard let data else { return }
        let doc = model.document
        let fmt = model.format
        let job = doc.makeExportJob(format: fmt, embedMetadata: exportOptions.embedMetadata)
        let fileName = Self.fileName(doc.name, ext: fmt == .rez ? "rez" : "ndat")
        runBusy("Installing…") {
            let tmp = try await Task.detached(priority: .userInitiated) { () -> URL in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(fileName)
                try job.encode().write(to: file)
                return file
            }.value
            doc.markSaved(atChangeCount: job.changeCount)
            // Importing registers the plug-in with the game data (main-actor state).
            let id = try data.importPlugin(from: tmp)
            try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
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

    /// Recovery layout (under `NovaSwift/Editor/Recovery`):
    /// - `recovery.json`  — `RecoveryInfo`: where the document came from, its source-file mapping
    ///   (`sourceFiles`, per-file formats, `targetFile`) and the bundle info.
    /// - `bundle/`        — a source-tracked document (anything opened from disk): every source file
    ///   at its relative path (always written as `.rez`; the real format is in the info), every
    ///   `.nsx` pack as a folder, and the editor metadata in the primary file. Restoring loads it
    ///   back through `PluginBundleLoader`, so resources keep their files.
    /// - `recovery.rez`   — a document with no tracked sources (a brand-new plug-in): one merged file.
    private var recoveryDir: URL {
        NovaStorage.root.appendingPathComponent("NovaSwift/Editor/Recovery", isDirectory: true)
    }
    private var recoveryURL: URL { recoveryDir.appendingPathComponent("recovery.rez") }
    private var recoveryInfoURL: URL { recoveryDir.appendingPathComponent("recovery.json") }
    private var recoveryBundleURL: URL { recoveryDir.appendingPathComponent("bundle", isDirectory: true) }

    private struct RecoveryBundle: Codable {
        var name: String
        var folder: String?
        var resourceFiles: [String]
        var graphicsPacks: [String]
        var otherFiles: [String]
        var isTotalConversion: Bool
    }

    private struct RecoveryInfo: Codable {
        var path: String?
        var installedID: String?
        var classic: Bool
        /// Source keys in load order (nil = the old single merged file).
        var sourceFiles: [String]?
        var fileFormats: [String: PluginFormat]?
        var targetFile: String?
        var bundle: RecoveryBundle?
    }

    private func autosaveTick() {
        let d = model.document
        guard d.isDirty else { return }
        // Serialising a big layer takes a while; snapshot the (value-type) state here and encode +
        // write on a background thread so typing never hitches.
        var info = RecoveryInfo(path: model.fileURL?.path, installedID: installedID, classic: model.format == .classic)
        var plan: PluginSavePlan?
        var snapshot: PluginDocument?
        if d.sourceFiles.isEmpty {
            snapshot = PluginDocument(name: d.name, author: d.author, version: d.version, notes: d.notes, layer: d.layer)
        } else {
            plan = d.makeSavePlan(rewriteAll: true, embedPacksInFile: false, embedMetadata: true)
            info.sourceFiles = d.sourceFiles
            info.fileFormats = d.fileFormats
            info.targetFile = d.targetFile
            if let b = model.bundle {
                info.bundle = RecoveryBundle(name: b.name, folder: b.folderURL?.path, resourceFiles: b.resourceFiles.map(\.path),
                                             graphicsPacks: b.graphicsPacks.map(\.path), otherFiles: b.otherFiles.map(\.path),
                                             isTotalConversion: b.isTotalConversion)
            }
        }
        let infoOut = info, planIn = plan
        let job = snapshot?.makeExportJob(format: .rez)       // always rez on disk; real format is in the info
        let dir = recoveryDir, file = recoveryURL, infoFile = recoveryInfoURL, bundleDir = recoveryBundleURL
        let gen = recoveryGeneration
        Task.detached(priority: .utility) { [weak self] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if var plan = planIn {
                    for i in plan.dataFiles.indices { plan.dataFiles[i].format = .rez }
                    let staging = dir.appendingPathComponent("bundle.tmp", isDirectory: true)
                    try? fm.removeItem(at: staging)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    _ = try plan.write(to: staging)
                    try? fm.removeItem(at: bundleDir)
                    try fm.moveItem(at: staging, to: bundleDir)
                    try? fm.removeItem(at: file)
                } else if let job {
                    try job.encode().write(to: file, options: .atomic)
                    try? fm.removeItem(at: bundleDir)
                }
                try JSONEncoder().encode(infoOut).write(to: infoFile, options: .atomic)
            } catch { /* best effort */ }
            // A save/new/close may have cleared recovery while we were writing: drop the stale copy.
            await self?.dropStaleRecovery(generation: gen)
        }
    }

    private var recoveryGeneration = 0

    private func dropStaleRecovery(generation gen: Int) {
        if recoveryGeneration != gen { removeRecoveryFiles() }
    }

    private func removeRecoveryFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: recoveryURL)
        try? fm.removeItem(at: recoveryInfoURL)
        try? fm.removeItem(at: recoveryBundleURL)
        try? fm.removeItem(at: recoveryDir.appendingPathComponent("bundle.tmp", isDirectory: true))
    }

    func clearRecovery() {
        recoveryGeneration += 1
        removeRecoveryFiles()
        recoveryAvailable = false
    }

    func restoreRecovery() {
        let info = (try? Data(contentsOf: recoveryInfoURL)).flatMap { try? JSONDecoder().decode(RecoveryInfo.self, from: $0) }
        let url = recoveryURL, bundleDir = recoveryBundleURL
        runBusy("Restoring…", errorPrefix: "Couldn't restore: ") {
            if let info, let keys = info.sourceFiles, !keys.isEmpty,
               FileManager.default.fileExists(atPath: bundleDir.path) {
                try await self.restoreBundle(info, keys: keys, bundleDir: bundleDir)
            } else {
                let base = try await self.base(excluding: info?.installedID)
                let box = try await Task.detached { DocBox(doc: try PluginDocument.open(url: url, base: base)) }.value
                let doc = box.doc
                self.finishRestore(doc, info: info, url: info?.path.map { URL(fileURLWithPath: $0) }, bundle: nil)
            }
        }
    }

    /// Rebuild a multi-file document from the recovery bundle: same files, same resource-to-file
    /// mapping, formats, target file and bundle info as when the autosave ran.
    private func restoreBundle(_ info: RecoveryInfo, keys: [String], bundleDir: URL) async throws {
        let dataKeys = keys.filter { !PluginDocument.isPackKey($0) }
        let packKeys = keys.filter(PluginDocument.isPackKey)
        let name = info.bundle?.name ?? "Recovered plug-in"
        let layout = PluginLayout(
            name: name, root: bundleDir,
            dataFiles: dataKeys.map { bundleDir.appendingPathComponent($0) },
            graphicsPacks: packKeys.map {
                bundleDir.appendingPathComponent(String($0.dropFirst(PluginDocument.packPrefix.count)), isDirectory: true)
            },
            isTotalConversion: info.bundle?.isTotalConversion ?? false,
            novaFiles: dataKeys.filter { $0.lowercased().hasPrefix("nova files/") }.map { bundleDir.appendingPathComponent($0) })
        let base: ResourceCollection
        if layout.isTotalConversion { base = try await totalConversionBase(layout) }
        else { base = try await self.base(excluding: info.installedID) }
        busyText = "Reading recovered files…"
        let formats = info.fileFormats ?? [:]
        let box = try await Task.detached(priority: .userInitiated) { () -> DocBox in
            let loaded = try PluginBundleLoader.load(layout)
            // Recovery files are always .rez on disk; put the original container format back.
            let files = loaded.files.map { f in
                LoadedPluginFile(key: f.key, format: f.isPack ? f.format : (formats[f.key] ?? f.format),
                                 isPack: f.isPack, collection: f.collection)
            }
            return DocBox(doc: PluginDocument.open(files: files, defaultName: name, base: base), layout: layout)
        }.value
        let doc = box.doc
        doc.targetFile = info.targetFile.flatMap { doc.sourceFiles.contains($0) ? $0 : nil }
        // The originals on disk may not match the recovered content: Save must rewrite every file.
        doc.markAllSourcesModified()
        var bundle: EditorBundleInfo?
        if let b = info.bundle {
            bundle = EditorBundleInfo(name: b.name, folderURL: b.folder.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                      resourceFiles: b.resourceFiles.map { URL(fileURLWithPath: $0) },
                                      graphicsPacks: b.graphicsPacks.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                      otherFiles: b.otherFiles.map { URL(fileURLWithPath: $0) },
                                      isTotalConversion: b.isTotalConversion, installedID: info.installedID)
        }
        finishRestore(doc, info: info, url: info.path.map { URL(fileURLWithPath: $0) }, bundle: bundle)
    }

    private func finishRestore(_ doc: PluginDocument, info: RecoveryInfo?, url: URL?, bundle: EditorBundleInfo?) {
        // Opened files are clean; a recovered document is not.
        let n = doc.name; doc.name = n + "~"; doc.name = n
        busyText = "Preparing data…"
        replace(doc, url: url)
        model.format = (info?.classic ?? false) ? .classic : .rez
        installedID = info?.installedID
        model.bundle = bundle
        refreshConflicts()
        recoveryAvailable = false
        flash("Recovered unsaved work")
    }
}
#endif
