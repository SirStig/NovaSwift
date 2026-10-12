import Foundation

// Opening and saving plug-ins that aren't a single file: several `.rez` files, `.nsx`
// graphics packs, total conversions. Platform-neutral plain data code (no UI), safe to run
// off the main actor. See docs/PLUGIN_EDITOR.md, "Plug-in shapes".

/// One source file of a plug-in, parsed.
public struct LoadedPluginFile: Sendable {
    /// Stable key (see `PluginDocument.sourceFiles`).
    public let key: String
    public let format: PluginFormat
    /// An `.nsx` pack embedded as `NSgx`/`NSbl` resources.
    public let isPack: Bool
    public var collection: ResourceCollection

    public init(key: String, format: PluginFormat, isPack: Bool, collection: ResourceCollection) {
        self.key = key; self.format = format; self.isPack = isPack; self.collection = collection
    }
}

public enum PluginBundleError: Swift.Error, CustomStringConvertible {
    case unreadable(file: String, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(f, r): return "\(f) couldn't be read: \(r)"
        }
    }
}

/// What a plug-in is on disk: its folder, data files in load order, `.nsx` packs, and the
/// remaining files that belong to it (fonts, movies, pilots, readmes…).
public struct PluginLayout: Sendable, Equatable {
    public var name: String
    /// The plug-in's folder; source keys are paths relative to it.
    public var root: URL
    /// Resource containers in load order (a total conversion: its `Nova Files`, then its `Plug-Ins`).
    public var dataFiles: [URL]
    /// `.nsx` graphics-pack folders.
    public var graphicsPacks: [URL]
    /// Non-hidden everything else in the folder (bounded depth and count).
    public var otherFiles: [URL]
    /// A total conversion: it has its own `Nova Files`.
    public var isTotalConversion: Bool
    /// A TC's own `Nova Files` (a prefix of `dataFiles`).
    public var novaFiles: [URL]

    public init(name: String, root: URL, dataFiles: [URL] = [], graphicsPacks: [URL] = [], otherFiles: [URL] = [],
                isTotalConversion: Bool = false, novaFiles: [URL] = []) {
        self.name = name; self.root = root; self.dataFiles = dataFiles; self.graphicsPacks = graphicsPacks
        self.otherFiles = otherFiles; self.isTotalConversion = isTotalConversion; self.novaFiles = novaFiles
    }

    /// Source key of a data file.
    public func key(of file: URL) -> String { PluginBundleLoader.relativePath(file, from: root) }
    /// Source key of a graphics pack.
    public func packKey(of pack: URL) -> String { PluginDocument.packPrefix + PluginBundleLoader.relativePath(pack, from: root) }
}

/// Everything `PluginDocument.makeSavePlan` decided to write, as plain values.
public struct PluginSavePlan: Sendable {
    public struct DataFile: Sendable {
        /// Path relative to the plug-in's folder.
        public var relativePath: String
        public var format: PluginFormat
        public var collection: ResourceCollection
    }
    public struct Pack: Sendable {
        public var relativePath: String
        public var name: String
        public var collection: ResourceCollection
    }
    public var dataFiles: [DataFile] = []
    public var packs: [Pack] = []
    /// `changeCount` when the plan was made.
    public let changeCount: Int
    /// Source keys this plan covers (cleared from the "modified" set by `didSave`).
    public var writtenKeys: Set<String> = []

    init(changeCount: Int) { self.changeCount = changeCount }

    public var isEmpty: Bool { dataFiles.isEmpty && packs.isEmpty }

    /// Write everything under `root`, all-or-nothing as far as the file system allows: every
    /// file is first written next to its destination under a temporary name, and only when all
    /// of them succeeded are they moved into place (replacing the originals atomically).
    /// Returns the destination URLs.
    @discardableResult
    public func write(to root: URL) throws -> [URL] {
        let fm = FileManager.default
        var staged: [(tmp: URL, dest: URL)] = []
        func cleanup() { for s in staged { try? fm.removeItem(at: s.tmp) } }
        do {
            for f in dataFiles {
                let dest = root.appendingPathComponent(f.relativePath)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes: Data
                switch f.format {
                case .rez: bytes = RezWriter.write(f.collection)
                case .classic: bytes = try ClassicForkWriter.write(f.collection)
                }
                let tmp = Self.tempURL(for: dest)
                try bytes.write(to: tmp)
                staged.append((tmp, dest))
            }
            for p in packs {
                let dest = root.appendingPathComponent(p.relativePath, isDirectory: true)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = Self.tempURL(for: dest)
                staged.append((tmp, dest))
                try GraphicsPackEmbedding.extract(from: p.collection, to: tmp, name: p.name)
                try Self.carryManifestDetails(from: dest, to: tmp)
            }
        } catch {
            cleanup()
            throw error
        }
        for s in staged {
            if fm.fileExists(atPath: s.dest.path) { _ = try fm.replaceItemAt(s.dest, withItemAt: s.tmp) }
            else { try fm.moveItem(at: s.tmp, to: s.dest) }
        }
        return staged.map(\.dest)
    }

    private static func tempURL(for dest: URL) -> URL {
        dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).nstmp")
    }

    /// `extract` writes a fresh manifest; keep the pack's name, author and license from the old one.
    private static func carryManifestDetails(from old: URL, to new: URL) throws {
        let oldURL = old.appendingPathComponent(GraphicsPackManifest.fileName)
        let newURL = new.appendingPathComponent(GraphicsPackManifest.fileName)
        guard let oldData = try? Data(contentsOf: oldURL),
              let o = try? JSONDecoder().decode(GraphicsPackManifest.self, from: oldData),
              let newData = try? Data(contentsOf: newURL),
              var m = try? JSONDecoder().decode(GraphicsPackManifest.self, from: newData) else { return }
        m.name = o.name ?? m.name
        m.author = o.author
        m.license = o.license
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: newURL, options: .atomic)
    }
}

public enum PluginBundleLoader {

    // MARK: Layouts

    /// Layout of an installed bundle (see `GameLibrary.discoverPlugins`).
    public static func layout(of bundle: PluginBundle) -> PluginLayout {
        if bundle.isTotalConversion {
            let root = bundle.novaFilesURLs[0].deletingLastPathComponent().deletingLastPathComponent()
            return tcLayout(name: bundle.name, root: root, novaFiles: bundle.novaFilesURLs, plugIns: bundle.fileURLs)
        }
        if bundle.fileURLs.isEmpty, let folder = bundle.folderURL {
            // Graphics-only plug-in: just its packs.
            return PluginLayout(name: bundle.name, root: folder,
                                graphicsPacks: GameLibrary.discoverGraphicsPacks(in: [folder]),
                                otherFiles: otherFiles(in: folder, excluding: []))
        }
        let files = bundle.fileURLs.sorted(by: fileNameOrder)
        guard let first = files.first else { return PluginLayout(name: bundle.name, root: URL(fileURLWithPath: "/")) }
        let parent = first.deletingLastPathComponent()
        if files.count == 1, bundle.id == first.lastPathComponent {
            // A loose file in a plug-ins folder owns only the pack beside it with the same name.
            let sibling = parent.appendingPathComponent(first.deletingPathExtension().lastPathComponent + "." + GraphicsPackManifest.folderExtension,
                                                        isDirectory: true)
            let packs = FileManager.default.fileExists(atPath: sibling.path) ? [sibling] : []
            return PluginLayout(name: bundle.name, root: parent, dataFiles: files, graphicsPacks: packs)
        }
        return folderLayout(name: bundle.name, root: parent, dataFiles: files)
    }

    /// Layout of a folder chosen with the open panel: a total conversion, a plug-in folder
    /// (looking through a lone wrapper subfolder), or a graphics-only folder. Nil if it holds none.
    public static func layout(ofFolder folder: URL) -> PluginLayout? {
        var dir = folder
        for _ in 0..<3 {
            if let tc = GameLibrary.totalConversion(at: dir, id: dir.lastPathComponent) {
                return tcLayout(name: tc.name, root: dir, novaFiles: tc.novaFilesURLs, plugIns: tc.fileURLs)
            }
            let files = GameLibrary.topLevelResourceFiles(in: dir)
            let subs = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            let isPack = { (u: URL) in u.pathExtension.lowercased() == GraphicsPackManifest.folderExtension }
            if files.isEmpty, !subs.contains(where: isPack), subs.count == 1 { dir = subs[0]; continue }
            let layout = folderLayout(name: dir.lastPathComponent, root: dir, dataFiles: files)
            return layout.dataFiles.isEmpty && layout.graphicsPacks.isEmpty ? nil : layout
        }
        return nil
    }

    /// Layout of a single plug-in file chosen directly.
    public static func layout(ofFile file: URL) -> PluginLayout {
        PluginLayout(name: file.deletingPathExtension().lastPathComponent,
                     root: file.deletingLastPathComponent(), dataFiles: [file])
    }

    /// Layout of an `.nsx` folder opened directly (a graphics-only document).
    public static func layout(ofPack pack: URL) -> PluginLayout {
        PluginLayout(name: pack.deletingPathExtension().lastPathComponent,
                     root: pack.deletingLastPathComponent(), graphicsPacks: [pack])
    }

    /// Whether `url` is an `.nsx` pack folder.
    public static func isGraphicsPack(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == GraphicsPackManifest.folderExtension
    }

    private static func folderLayout(name: String, root: URL, dataFiles: [URL]) -> PluginLayout {
        // Subfolders holding their own plug-in files are opt-in sub-items, not part of this plug-in.
        let subItems = subfolders(of: root).filter {
            !isGraphicsPack($0) && !GameLibrary.topLevelResourceFiles(in: $0).isEmpty
        }.map { $0.standardizedFileURL.path + "/" }
        let packs = GameLibrary.discoverGraphicsPacks(in: [root]).filter { pack in
            let p = pack.standardizedFileURL.path
            return !subItems.contains { p.hasPrefix($0) }
        }
        return PluginLayout(name: name, root: root, dataFiles: dataFiles, graphicsPacks: packs,
                            otherFiles: otherFiles(in: root, excluding: Set(dataFiles.map { $0.standardizedFileURL.path }),
                                                   skipping: subItems))
    }

    private static func tcLayout(name: String, root: URL, novaFiles: [URL], plugIns: [URL]) -> PluginLayout {
        let data = GameLibrary.baseLoadOrder(novaFiles) + plugIns.sorted(by: fileNameOrder)
        return PluginLayout(name: name, root: root, dataFiles: data,
                            graphicsPacks: GameLibrary.discoverGraphicsPacks(in: [root]),
                            otherFiles: otherFiles(in: root, excluding: Set(data.map { $0.standardizedFileURL.path })),
                            isTotalConversion: true, novaFiles: novaFiles)
    }

    private static func fileNameOrder(_ a: URL, _ b: URL) -> Bool {
        (a.lastPathComponent.uppercased(), a.lastPathComponent) < (b.lastPathComponent.uppercased(), b.lastPathComponent)
    }

    private static func subfolders(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
    }

    /// Non-hidden files under `root` that aren't plug-in data: fonts, movies, music, pilots,
    /// `.nplay`, readmes, images… Skips resource containers (those are plug-ins), pack insides
    /// and anything deeper than three levels; capped at 500 entries.
    static func otherFiles(in root: URL, excluding data: Set<String>, skipping prefixes: [String] = []) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let path = url.standardizedFileURL.path
            if isDir {
                if isGraphicsPack(url) || e.level >= 3 || prefixes.contains(where: { (path + "/").hasPrefix($0) }) {
                    e.skipDescendants()
                }
                continue
            }
            if data.contains(path) || GameLibrary.resourceExtensions.contains(url.pathExtension.lowercased()) { continue }
            out.append(url)
            if out.count >= 500 { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: Loading

    public struct LoadResult: Sendable {
        public var files: [LoadedPluginFile]
        /// Packs that were skipped (and so will not be touched by Save), with the reason.
        public var warnings: [String]
        public var skippedPacks: [URL]
    }

    /// Read and parse every data file (concurrently) and embed every `.nsx` pack. A data file
    /// that can't be read fails the whole load (saving would otherwise drop it); a broken pack
    /// is skipped with a warning.
    public static func load(_ layout: PluginLayout) throws -> LoadResult {
        var parsed = [LoadedPluginFile?](repeating: nil, count: layout.dataFiles.count)
        var firstError: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: layout.dataFiles.count) { i in
            let url = layout.dataFiles[i]
            do {
                let (col, fmt) = try readContainer(at: url)
                let f = LoadedPluginFile(key: layout.key(of: url), format: fmt, isPack: false, collection: col)
                lock.lock(); parsed[i] = f; lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil { firstError = PluginBundleError.unreadable(file: url.lastPathComponent, reason: String(describing: error)) }
                lock.unlock()
            }
        }
        if let firstError { throw firstError }
        var files = parsed.compactMap { $0 }
        var warnings: [String] = []
        var skipped: [URL] = []
        for pack in layout.graphicsPacks {
            do {
                let col = try GraphicsPackEmbedding.embed(pack: pack, into: ResourceCollection())
                files.append(LoadedPluginFile(key: layout.packKey(of: pack), format: .rez, isPack: true, collection: col))
            } catch {
                warnings.append("\(pack.lastPathComponent) skipped: \(error)")
                skipped.append(pack)
            }
        }
        return LoadResult(files: files, warnings: warnings, skippedPacks: skipped)
    }

    /// Parse one container; a classic file whose resources live in its resource fork is read from there.
    public static func readContainer(at url: URL) throws -> (ResourceCollection, PluginFormat) {
        var data = try Data(contentsOf: url)
        if data.isEmpty, let fork = try? Data(contentsOf: url.appendingPathComponent("..namedfork/rsrc")), !fork.isEmpty {
            data = fork
        }
        let fmt: PluginFormat = ResourceFile.detectFormat(data) == .rez ? .rez : .classic
        return (try ResourceFile.read(data), fmt)
    }

    /// Path of `url` relative to `root` (`/`-separated); the bare file name if it isn't inside.
    static func relativePath(_ url: URL, from root: URL) -> String {
        let r = root.standardizedFileURL.pathComponents, u = url.standardizedFileURL.pathComponents
        if u.count > r.count, Array(u.prefix(r.count)) == r { return u.dropFirst(r.count).joined(separator: "/") }
        return url.lastPathComponent
    }
}

// MARK: Copying a bundle's other files

extension PluginBundleLoader {

    public struct CopyResult: Sendable, Equatable {
        /// Where each file that is now present in the destination lives (copied or already there),
        /// in input order.
        public var present: [URL] = []
        /// Source files that were missing or couldn't be copied (name, reason).
        public var failed: [String] = []
        /// How many files were actually copied this time.
        public var copiedCount = 0

        public init(present: [URL] = [], failed: [String] = [], copiedCount: Int = 0) {
            self.present = present; self.failed = failed; self.copiedCount = copiedCount
        }
    }

    /// Copy the non-data files of a plug-in folder (fonts, movies, music, pilots, `.nplay`, readmes,
    /// images…) into `dest`, keeping each one's path relative to `root`. A file already at its
    /// destination (same path, or an existing file there) is left alone and never overwritten.
    /// Safe to call off the main actor; `progress(done, total)` is called after every file.
    public static func copyBundleFiles(_ files: [URL], from root: URL, to dest: URL,
                                       progress: (@Sendable (Int, Int) -> Void)? = nil) -> CopyResult {
        let fm = FileManager.default
        var result = CopyResult()
        for (i, file) in files.enumerated() {
            defer { progress?(i + 1, files.count) }
            let target = dest.appendingPathComponent(relativePath(file, from: root))
            if target.standardizedFileURL.path == file.standardizedFileURL.path || fm.fileExists(atPath: target.path) {
                result.present.append(target)
                continue
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: target)
                result.present.append(target)
                result.copiedCount += 1
            } catch {
                result.failed.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }
}
