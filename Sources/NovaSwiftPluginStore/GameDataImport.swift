import Foundation
import NovaSwiftKit

/// Cross-platform "bring your own data" importer: inspect a source the player picked, then
/// copy it into a managed data directory with progress, cancel, a disk-space check and an
/// atomic finish (copy to a sibling temp dir, validate the copy, rename into place).
///
/// This is the Godot frontend's `DataImporter` + `DataSetupWizard` backend (the bridge only
/// plumbs it: `data_import_*`). It shares its file discovery and "what is missing" rules with
/// the Apple `DataImporter` through `NovaSwiftKit.GameFileDiscovery`. It lives in
/// NovaSwiftPluginStore (not Kit) only because zip support (`GameDataArchiver`) is linked here.
///
/// Accepted sources: a game folder (Windows / Community Edition install, Mac install or
/// `.app` with its `Nova Files`), a `Nova Files` folder, a single `.rez`/`.ndat` (or audio,
/// font, holovid) file, or a `.zip` of any of those. Music (`Nova Music.mp3`), fonts, race
/// movies and `EVNova.ini` come along; plug-in folders found alongside the game
/// (`Nova Plug-ins`) are kept separate as `Nova Plug-ins/` inside the destination, where the
/// plug-in runtime already looks for them.
public enum GameDataImport {

    /// Folder names (lower-case) treated as plug-in folders, not base data.
    public static let pluginFolderNames: Set<String> = ["nova plug-ins", "nova plugins", "nova plug-in", "plug-ins", "plugins"]
    /// Where plug-ins are copied inside the destination (matches `PluginRuntime.gameFolderNames`).
    public static let destPluginFolder = "Nova Plug-ins"

    // MARK: Inspection

    public struct Inspection: Codable, Sendable {
        public var source = ""
        /// folder | file | zip | missing
        public var kind = "missing"
        /// windows-ce | mac | nova-files | files | file | none
        public var layout = "none"
        public var layoutLabel = ""
        public var version = ""
        public var baseFiles: [String] = []
        public var audioFiles: [String] = []
        public var fontFiles: [String] = []
        public var videoFiles: [String] = []
        public var hasIni = false
        public var pluginFolders: [String] = []
        public var pluginFileCount = 0
        public var totalBytes: Int64 = 0
        public var freeBytes: Int64 = 0
        public var resourceCount = 0
        public var unreadable: [String] = []
        public var missingFiles: [String] = []
        public var missingEssentials: [String] = []
        public var resourceForkOnly: [String] = []
        public var warnings: [String] = []
        public var error = ""
        /// Parsed (deep) rather than just listed.
        public var deep = false
        /// Something recognisable was found (even if incomplete).
        public var hasBase: Bool { !baseFiles.isEmpty }
        /// Parsed clean and nothing essential missing: safe to import.
        public var valid = false
    }

    /// One planned copy: source file and its path relative to the destination root.
    struct Item { var src: URL; var rel: String; var size: Int64 }

    struct Plan {
        var items: [Item] = []
        var inspection = Inspection()
        var root: URL?        // the resolved folder (a zip's extraction), nil for a single file
    }

    private static let lock = NSLock()
    private static var extracted: [String: URL] = [:]

    /// Remove every zip extraction made by `inspect` (call when leaving the wizard / after import).
    public static func discardExtractions() {
        lock.lock(); let all = extracted; extracted = [:]; lock.unlock()
        for (_, u) in all { try? FileManager.default.removeItem(at: u) }
    }

    /// Inspect `source`. `deep` also parses every resource container (version, counts,
    /// missing essentials) -- seconds on a full install, so frontends run it off the UI thread.
    public static func inspect(_ source: URL, deep: Bool, includePlugins: Bool = true,
                               cancelled: @escaping () -> Bool = { false }) -> Inspection {
        var plan = makePlan(source, includePlugins: includePlugins)
        if deep && plan.inspection.hasBase && plan.inspection.error.isEmpty {
            validate(&plan.inspection, files: plan.items.filter { isResource($0.src) && !$0.rel.hasPrefix(destPluginFolder + "/") }.map(\.src),
                     cancelled: cancelled)
        }
        return plan.inspection
    }

    static func isResource(_ u: URL) -> Bool { GameLibrary.resourceExtensions.contains(u.pathExtension.lowercased()) }

    private static func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

    private static func size(_ u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Resolves a zip to its (cached) extraction folder.
    private static func resolveZip(_ zip: URL) throws -> URL {
        let key = zip.standardizedFileURL.path
        lock.lock(); let have = extracted[key]; lock.unlock()
        if let have, FileManager.default.fileExists(atPath: have.path) { return have }
        let dir = try GameDataArchiver.unzipToTemporary(archive: zip)
        lock.lock(); extracted[key] = dir; lock.unlock()
        return dir
    }

    static func makePlan(_ source: URL, includePlugins: Bool) -> Plan {
        var plan = Plan()
        var ins = Inspection()
        ins.source = source.path
        let fm = FileManager.default
        var isDirFlag: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirFlag) else {
            ins.error = "That path doesn't exist."
            plan.inspection = ins
            return plan
        }
        var root = source
        if !isDirFlag.boolValue {
            let ext = source.pathExtension.lowercased()
            if ext == "zip" {
                ins.kind = "zip"
                do { root = try resolveZip(source) } catch {
                    ins.error = "Couldn't open that zip: \(error.localizedDescription)"
                    plan.inspection = ins
                    return plan
                }
            } else {
                ins.kind = "file"
                ins.layout = "file"
                ins.layoutLabel = "A single file"
                let ok = isResource(source) || GameFileDiscovery.audioExtensions.contains(ext)
                    || GameFileDiscovery.fontExtensions.contains(ext) || GameFileDiscovery.videoExtensions.contains(ext)
                if !ok { ins.error = "That file isn't an EV Nova data file (.rez / .ndat, music, font or movie)." }
                else { plan.items = [Item(src: source, rel: source.lastPathComponent, size: size(source))] }
                classify(&ins, items: plan.items, hasExe: false, hasApp: false, rootName: "")
                plan.inspection = ins
                return plan
            }
        } else {
            ins.kind = "folder"
        }
        plan.root = root

        // The resolved folder. A zip often wraps everything in one folder: look through it.
        root = lookThroughWrapper(root)
        plan.root = root
        let top = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        let names = top.map { $0.lastPathComponent.lowercased() }
        let hasExe = names.contains { $0.hasSuffix(".exe") && $0.contains("nova") } || names.contains("ddraw.dll") || names.contains("evnova.ini")
        let hasApp = top.contains { $0.pathExtension.lowercased() == "app" }

        // Plug-in folders anywhere in the tree (depth <= 4), outermost only.
        var pluginDirs: [URL] = []
        collectPluginDirs(root, depth: 0, into: &pluginDirs)
        let pluginPrefixes = pluginDirs.map { $0.standardizedFileURL.path + "/" }
        func inPlugins(_ u: URL) -> Bool {
            let p = u.standardizedFileURL.path
            return pluginPrefixes.contains { p.hasPrefix($0) }
        }
        // Base = everything importable outside the plug-in folders.
        let rootPath = root.standardizedFileURL.path
        func rel(_ u: URL) -> String {
            let p = u.standardizedFileURL.path
            return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : u.lastPathComponent
        }
        var seen = Set<String>()
        for f in GameFileDiscovery.importableFiles(in: root) where !inPlugins(f) {
            // Flat copy (as the Apple importer); first one wins on a name clash.
            if seen.insert(f.lastPathComponent.lowercased()).inserted {
                plan.items.append(Item(src: f, rel: f.lastPathComponent, size: size(f)))
            }
        }
        if includePlugins {
            for d in pluginDirs {
                guard let e = fm.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                            options: [.skipsHiddenFiles]) else { continue }
                var n = 0
                for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    let inner = String(f.standardizedFileURL.path.dropFirst(d.standardizedFileURL.path.count + 1))
                    plan.items.append(Item(src: f, rel: destPluginFolder + "/" + inner, size: size(f)))
                    if isResource(f) { n += 1 }
                }
                ins.pluginFileCount += n
                ins.pluginFolders.append(rel(d))
            }
        }
        classify(&ins, items: plan.items, hasExe: hasExe, hasApp: hasApp, rootName: root.lastPathComponent)
        // Classic Mac resource-fork-only files ("Nova Data 1" with no extension).
        let baseNames = Set(plan.items.map { $0.src.lastPathComponent.lowercased() })
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.pathExtension.isEmpty && f.lastPathComponent.lowercased().hasPrefix("nova ")
                && !isDir(f) && !inPlugins(f) && !baseNames.contains(f.lastPathComponent.lowercased()) {
                ins.resourceForkOnly.append(f.lastPathComponent)
            }
        }
        if !ins.resourceForkOnly.isEmpty && ins.baseFiles.isEmpty {
            ins.error = "These look like classic Mac resource-fork files, which can't be copied between systems. Use the Windows build's .zip (or the .ndat files) instead."
        } else if !ins.resourceForkOnly.isEmpty {
            ins.warnings.append("Skipped \(ins.resourceForkOnly.count) classic Mac resource-fork file(s) without an extension: " + ins.resourceForkOnly.prefix(4).joined(separator: ", "))
        }
        if ins.baseFiles.isEmpty && ins.error.isEmpty {
            ins.error = "No EV Nova data (.rez / .ndat files) was found there. Pick the game folder, its Nova Files folder, or a zip of them."
        }
        plan.inspection = ins
        return plan
    }

    private static func lookThroughWrapper(_ root: URL) -> URL {
        let fm = FileManager.default
        var cur = root
        for _ in 0..<2 {
            let kids = ((try? fm.contentsOfDirectory(at: cur, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.lastPathComponent != "__MACOSX" }
            if kids.count == 1, isDir(kids[0]), kids[0].pathExtension.lowercased() != "app" { cur = kids[0] } else { break }
        }
        return cur
    }

    private static func collectPluginDirs(_ dir: URL, depth: Int, into out: inout [URL]) {
        guard depth <= 4 else { return }
        let kids = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? [])
        for k in kids where isDir(k) {
            if pluginFolderNames.contains(k.lastPathComponent.lowercased()) { out.append(k) }
            else { collectPluginDirs(k, depth: depth + 1, into: &out) }
        }
    }

    private static func classify(_ ins: inout Inspection, items: [Item], hasExe: Bool, hasApp: Bool, rootName: String) {
        var base: [String] = [], audio: [String] = [], fonts: [String] = [], videos: [String] = []
        for it in items where !it.rel.hasPrefix(destPluginFolder + "/") {
            let n = it.src.lastPathComponent, ext = it.src.pathExtension.lowercased()
            ins.totalBytes += it.size
            if isResource(it.src) { base.append(n) }
            else if GameFileDiscovery.audioExtensions.contains(ext) { audio.append(n) }
            else if GameFileDiscovery.fontExtensions.contains(ext) { fonts.append(n) }
            else if GameFileDiscovery.videoExtensions.contains(ext) { videos.append(n) }
            else if n.lowercased() == "evnova.ini" { ins.hasIni = true }
        }
        for it in items where it.rel.hasPrefix(destPluginFolder + "/") { ins.totalBytes += it.size }
        ins.baseFiles = base.sorted { $0.lowercased() < $1.lowercased() }
        ins.audioFiles = audio.sorted(); ins.fontFiles = fonts.sorted(); ins.videoFiles = videos.sorted()
        let isNdat = base.contains { $0.lowercased().hasSuffix(".ndat") }
        if ins.layout != "file" {
            if hasExe { ins.layout = "windows-ce"; ins.layoutLabel = "Windows / Community Edition install" }
            else if hasApp { ins.layout = "mac"; ins.layoutLabel = "Mac install (EV Nova.app)" }
            else if rootName.lowercased() == "nova files" || !base.isEmpty { ins.layout = isNdat ? "mac" : "nova-files"
                ins.layoutLabel = isNdat ? "Mac / cross-platform data files (.ndat)" : "Nova Files folder" }
            else { ins.layout = "none" }
        }
        // Version: format + markers; the 'vers' resource refines it when parsed.
        let fmt = isNdat ? ".ndat (Mac / cross-platform)" : (base.isEmpty ? "" : ".rez (Windows)")
        let ce = ins.hasIni || ins.audioFiles.contains { $0.lowercased() == "nova music.mp3" } || hasExe
        ins.version = base.isEmpty ? "" : ((ce ? "EV Nova (Windows / Community Edition data)" : "EV Nova") + (fmt.isEmpty ? "" : " - " + fmt))
        // Expected families (warnings only: editions differ).
        let lower = base.map { $0.lowercased() }
        func has(_ prefix: String) -> Bool { lower.contains { $0.hasPrefix(prefix) } }
        if ins.layout != "file" {
            for (prefix, label) in [("nova data", "Nova Data"), ("nova graphics", "Nova Graphics"), ("nova ships", "Nova Ships"),
                                    ("nova sounds", "Nova Sounds"), ("nova titles", "Nova Titles")] where !has(prefix) {
                ins.missingFiles.append(label)
            }
            if audio.isEmpty { ins.warnings.append("No soundtrack (Nova Music.mp3) found - the game will have no music.") }
            if fonts.isEmpty { ins.warnings.append("No original fonts (Charcoal / Geneva .ttf) found - look-alike fonts will be used.") }
            if videos.isEmpty && !base.isEmpty { ins.warnings.append("No race movies (Race 1-4.mov) found - the Galaxy Racing Network bar screen will lack its holovids.") }
        }
        if !ins.missingFiles.isEmpty && !base.isEmpty {
            ins.warnings.append("Missing file group(s): " + ins.missingFiles.joined(separator: ", ") + ".")
        }
    }

    /// Parse every container: unreadable ones, resource count, missing essentials, 'vers' text.
    static func validate(_ ins: inout Inspection, files: [URL], cancelled: () -> Bool) {
        var merged = ResourceCollection()
        var unreadable: [String] = []
        let ordered = GameLibrary.baseLoadOrder(files)
        for f in ordered {
            if cancelled() { return }
            do { merged.overlay(try ResourceFile.read(contentsOf: f)) }
            catch { unreadable.append(f.lastPathComponent) }
        }
        ins.deep = true
        ins.unreadable = unreadable
        ins.resourceCount = merged.totalCount
        ins.missingEssentials = GameFileDiscovery.missingEssentials(in: merged)
        if let v = versionString(merged) {
            let ce = ins.version.contains("Community")
            ins.version = "EV Nova " + v + (ce ? " (Windows / Community Edition data)" : "")
        }
        if !unreadable.isEmpty {
            ins.warnings.append("Couldn't read: " + unreadable.joined(separator: ", ") + " (damaged or not a resource file).")
        }
        ins.valid = ins.error.isEmpty && !files.isEmpty && unreadable.count < files.count && ins.missingEssentials.isEmpty
        if !ins.valid && ins.error.isEmpty && !ins.missingEssentials.isEmpty {
            ins.error = "This isn't a complete set yet - still missing: " + ins.missingEssentials.joined(separator: ", ") + ". Pick the whole game folder to get everything at once."
        } else if !ins.valid && ins.error.isEmpty {
            ins.error = "None of those files could be read as EV Nova data."
        }
    }

    /// The short version text from `vers` 1 (pascal string after the 6-byte header), e.g. "1.1.0".
    static func versionString(_ c: ResourceCollection) -> String? {
        guard let tag = FourCharCode("vers") else { return nil }
        for id in [1, 2] {
            guard let r = c.resource(tag, id), r.data.count > 7 else { continue }
            let d = [UInt8](r.data)
            let n = Int(d[6])
            guard n > 0, 7 + n <= d.count else { continue }
            if let s = String(bytes: d[7..<(7 + n)], encoding: .macOSRoman) ?? String(bytes: d[7..<(7 + n)], encoding: .isoLatin1),
               !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: Disk space

    public static func freeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        var p = url
        while !fm.fileExists(atPath: p.path), p.path != "/", p.pathComponents.count > 1 { p = p.deletingLastPathComponent() }
        if let a = try? fm.attributesOfFileSystem(forPath: p.path), let n = a[.systemFreeSize] as? NSNumber { return n.int64Value }
        return Int64.max   // unknown: don't block
    }

    // MARK: Import job

    public struct Progress: Codable, Sendable {
        public var running = false
        public var done = false
        public var ok = false
        public var cancelled = false
        public var phase = ""
        public var fraction = 0.0
        public var filesDone = 0
        public var filesTotal = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var error = ""
        public var failed: [String] = []
        public var warnings: [String] = []
        public var destination = ""
        public var resourceCount = 0
        public var version = ""
    }

    /// One import run on a worker thread. `snapshot()` is safe from any thread.
    public final class Job: @unchecked Sendable {
        private let source: URL
        private let destination: URL
        private let includePlugins: Bool
        private let mutex = NSLock()
        private var p = Progress()
        private var cancelFlag = false

        public init(source: URL, destination: URL, includePlugins: Bool = true) {
            self.source = source
            self.destination = destination.standardizedFileURL
            self.includePlugins = includePlugins
            p.destination = destination.path
        }

        public func snapshot() -> Progress { mutex.lock(); defer { mutex.unlock() }; return p }
        public func cancel() { mutex.lock(); cancelFlag = true; mutex.unlock() }
        private var isCancelled: Bool { mutex.lock(); defer { mutex.unlock() }; return cancelFlag }
        private func update(_ f: (inout Progress) -> Void) { mutex.lock(); f(&p); mutex.unlock() }

        public func start() {
            update { $0.running = true; $0.phase = "Reading your files"; $0.fraction = 0.02 }
            Thread.detachNewThread { [self] in
                run()
                discardExtractions()
            }
        }

        private func fail(_ msg: String, cancelled: Bool = false) {
            update { $0.running = false; $0.done = true; $0.ok = false; $0.cancelled = cancelled
                $0.error = msg; $0.phase = cancelled ? "Cancelled" : "Failed" }
        }

        private func run() {
            let fm = FileManager.default
            let plan = GameDataImport.makePlan(source, includePlugins: includePlugins)
            if !plan.inspection.error.isEmpty && plan.items.isEmpty { fail(plan.inspection.error); return }
            if isCancelled { fail("Cancelled.", cancelled: true); return }
            let items = plan.items
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            update { $0.filesTotal = items.count; $0.bytesTotal = total; $0.warnings = plan.inspection.warnings }

            // Source is the managed folder itself: nothing to copy, just validate.
            let srcPath = (plan.root ?? source).standardizedFileURL.path
            if srcPath == destination.path || srcPath.hasPrefix(destination.path + "/") {
                update { $0.phase = "Checking" }
                finishValidate(root: destination, extraFailed: [])
                return
            }

            // Disk space (copy + the old data is kept until the swap, so need the full size).
            let parent = destination.deletingLastPathComponent()
            do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
            catch { fail("Can't create \(parent.path): \(error.localizedDescription)"); return }
            let free = GameDataImport.freeBytes(at: parent)
            let need = total + max(total / 20, 64 << 20)
            if free < need {
                fail("Not enough disk space: the import needs about \(fmt(need)) and only \(fmt(free)) is free on that drive.")
                return
            }

            let tmp = parent.appendingPathComponent(".\(destination.lastPathComponent).importing-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
            catch { fail("Can't write to \(parent.path): \(error.localizedDescription)"); return }

            var failed: [String] = []
            var done: Int64 = 0
            update { $0.phase = "Copying your files" }
            for (i, it) in items.enumerated() {
                if isCancelled { try? fm.removeItem(at: tmp); fail("Cancelled.", cancelled: true); return }
                let dest = tmp.appendingPathComponent(it.rel)
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    try fm.copyItem(at: it.src, to: dest)
                } catch {
                    failed.append(it.src.lastPathComponent)
                }
                done += it.size
                let frac = total > 0 ? Double(done) / Double(total) : Double(i + 1) / Double(max(items.count, 1))
                update { $0.filesDone = i + 1; $0.bytesDone = done; $0.fraction = 0.05 + 0.80 * frac
                    $0.phase = "Copying \(it.src.lastPathComponent)"; $0.failed = failed }
            }
            if isCancelled { try? fm.removeItem(at: tmp); fail("Cancelled.", cancelled: true); return }

            // Validate the COPY before it replaces anything.
            update { $0.phase = "Checking the copy"; $0.fraction = 0.88 }
            var ins = Inspection()
            let files = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []).filter { GameDataImport.isResource($0) }
            ins.error = ""
            GameDataImport.validate(&ins, files: files, cancelled: { self.isCancelled })
            if isCancelled { try? fm.removeItem(at: tmp); fail("Cancelled.", cancelled: true); return }
            if !ins.valid {
                try? fm.removeItem(at: tmp)
                fail(ins.error.isEmpty ? "The copied data didn't validate." : ins.error)
                return
            }

            // Atomic swap.
            update { $0.phase = "Finishing"; $0.fraction = 0.96 }
            var old: URL?
            if fm.fileExists(atPath: destination.path) {
                let o = parent.appendingPathComponent(".\(destination.lastPathComponent).old-\(UUID().uuidString.prefix(8))", isDirectory: true)
                do { try fm.moveItem(at: destination, to: o); old = o }
                catch { try? fm.removeItem(at: tmp); fail("Couldn't replace the existing data: \(error.localizedDescription)"); return }
            }
            do { try fm.moveItem(at: tmp, to: destination) }
            catch {
                if let old { try? fm.moveItem(at: old, to: destination) }   // put the previous data back
                try? fm.removeItem(at: tmp)
                fail("Couldn't finish the import: \(error.localizedDescription)")
                return
            }
            if let old { try? fm.removeItem(at: old) }
            let version = ins.version.isEmpty ? plan.inspection.version : ins.version
            update { $0.running = false; $0.done = true; $0.ok = true; $0.fraction = 1; $0.phase = "Done"
                $0.resourceCount = ins.resourceCount; $0.version = version
                $0.warnings = plan.inspection.warnings + ins.warnings }
        }

        private func finishValidate(root: URL, extraFailed: [String]) {
            var ins = Inspection()
            let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { GameDataImport.isResource($0) }
            GameDataImport.validate(&ins, files: files, cancelled: { self.isCancelled })
            if ins.valid {
                update { $0.running = false; $0.done = true; $0.ok = true; $0.fraction = 1; $0.phase = "Done"; $0.resourceCount = ins.resourceCount }
            } else { fail(ins.error) }
        }

        private func fmt(_ b: Int64) -> String {
            let mb = Double(b) / 1_048_576
            return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
        }
    }

}
