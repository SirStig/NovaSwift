import Foundation

/// Per-total-conversion add-on lists (an enhancement beyond the original).
///
/// The original runs a total conversion with its OWN `Nova Files` + `Plug-Ins`
/// folders and ignores the user's global plug-ins (`nv_WinMain` 0x004d2a80 /
/// `Resource_ValidateInstallFolders` 0x004bd160: the data root `9:` is the TC's
/// folder; `nv_LoadFilesInFolder` 0x0046f500 loads its top-level `.rez` files;
/// only `Nova.rez` is shared). A player adds an add-on to a conversion (EVO
/// Facelift -> EV Override) by copying files into that conversion's `Plug-Ins`
/// folder. This type is the "without copying files" equivalent: each conversion
/// keeps an ordered list of installed plug-ins that load *after* the
/// conversion's own `Plug-Ins` files, exactly as if they sat in that folder.
///
/// Persisted as `[tcID: [PluginEnableState]]` (array order = load order). The
/// Apple app stores it in UserDefaults, Godot in `plugins-state.json` under
/// `tcAddOns`; the JSON is identical.
public enum TCAddOns {
    public typealias Lists = [String: [PluginEnableState]]

    /// The conversion that is in effect (what `GameLibrary.resolveLayers` picks).
    public static func selectedTC(_ plugins: [PluginBundle]) -> PluginBundle? {
        plugins.last { $0.isEnabled && $0.isTotalConversion }
    }

    /// Folds the persisted lists into the conversions: sets each TC's `addOnIDs`
    /// to its enabled, still-installed, non-conversion entries (de-duplicated).
    public static func apply(_ lists: Lists, to plugins: inout [PluginBundle]) {
        let installed = Set(plugins.filter { !$0.isTotalConversion }.map(\.id))
        for i in plugins.indices where plugins[i].isTotalConversion {
            var seen = Set<String>()
            plugins[i].addOnIDs = (lists[plugins[i].id] ?? []).compactMap { e in
                guard e.isEnabled, installed.contains(e.id), seen.insert(e.id).inserted else { return nil }
                return e.id
            }
        }
    }

    // MARK: List editing (all return false when nothing changed)

    @discardableResult
    public static func add(_ lists: inout Lists, tc: String, id: String, enabled: Bool = true) -> Bool {
        var l = lists[tc] ?? []
        guard !tc.isEmpty, !id.isEmpty, id != tc, !l.contains(where: { $0.id == id }) else { return false }
        l.append(PluginEnableState(id: id, isEnabled: enabled))
        lists[tc] = l
        return true
    }

    @discardableResult
    public static func remove(_ lists: inout Lists, tc: String, id: String) -> Bool {
        guard var l = lists[tc], let i = l.firstIndex(where: { $0.id == id }) else { return false }
        l.remove(at: i)
        lists[tc] = l.isEmpty ? nil : l
        return true
    }

    @discardableResult
    public static func setEnabled(_ lists: inout Lists, tc: String, id: String, enabled: Bool) -> Bool {
        guard var l = lists[tc], let i = l.firstIndex(where: { $0.id == id }), l[i].isEnabled != enabled else { return false }
        l[i] = PluginEnableState(id: id, isEnabled: enabled)
        lists[tc] = l
        return true
    }

    @discardableResult
    public static func move(_ lists: inout Lists, tc: String, id: String, by offset: Int) -> Bool {
        guard var l = lists[tc], let i = l.firstIndex(where: { $0.id == id }), l.indices.contains(i + offset), offset != 0 else { return false }
        l.swapAt(i, i + offset)
        lists[tc] = l
        return true
    }

    // MARK: Compatibility hints

    public enum Compatibility: Equatable, Sendable {
        /// Made for this conversion (name, folder, read-me or record overlap says so).
        case recommended(String)
        /// Nothing says either way.
        case neutral
        /// Looks made for the base game (or another conversion): warn, but allow.
        case unlikely(String)

        public var key: String {
            switch self { case .recommended: return "recommended"; case .neutral: return "neutral"; case .unlikely: return "unlikely" }
        }
        public var reason: String {
            switch self { case .recommended(let r), .unlikely(let r): return r; case .neutral: return "" }
        }
    }

    private static let stop: Set<String> = ["for", "nova", "the", "of", "a", "an", "and", "plug", "ins", "plugins",
                                            "plug-ins", "total", "conversion", "play", "rez", "ndat", "files", "file", "ev"]

    /// Words that name a conversion: "EV Override for Nova" -> ["evo", "override"].
    public static func aliases(of tc: PluginBundle) -> [String] {
        var out: [String] = []
        let words = (tc.id + " " + tc.name).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for w in words where w.count >= 4 && !stop.contains(w) && !out.contains(w) { out.append(w) }
        // Acronym of the id's meaningful words, keeping a leading "EV": EV Override -> EVO.
        let idWords = tc.id.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let keep = idWords.filter { !["for", "nova", "the", "of", "and"].contains($0) }
        if keep.count >= 2 {
            let a = String(keep.compactMap(\.first))
            if a.count >= 3, !out.contains(a) { out.append(a) }
            if keep.first == "ev", keep.count == 2, let c = keep[1].first {
                let b = "ev" + String(c)
                if !out.contains(b) { out.append(b) }
            }
        }
        return out
    }

    /// The folder a plug-in lives in (a loose `.rez` has none of its own).
    static func folder(of plugin: PluginBundle) -> URL? {
        if let f = plugin.folderURL { return f }
        guard let first = plugin.fileURLs.first else { return nil }
        let top = String(plugin.id.split(separator: "/").first ?? "")
        var dir = first.deletingLastPathComponent()
        for _ in 0..<6 {
            if dir.lastPathComponent == top { return dir }
            let up = dir.deletingLastPathComponent()
            if up == dir { break }
            dir = up
        }
        return nil
    }

    /// Lower-cased searchable text of a plug-in: id, name, file names and the head
    /// of any read-me in its folder. Cheap (one small read), no resource parsing.
    public static func descriptiveText(of plugin: PluginBundle) -> String {
        var parts = [plugin.id, plugin.name] + plugin.fileURLs.map { $0.deletingPathExtension().lastPathComponent }
        if let dir = folder(of: plugin) {
            let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for k in kids where ["rtf", "txt", "md"].contains(k.pathExtension.lowercased())
                && k.lastPathComponent.lowercased().contains("read") {
                if let h = try? FileHandle(forReadingFrom: k) {
                    defer { try? h.close() }
                    let d = (try? h.read(upToCount: 24_000)) ?? Data()
                    parts.append(String(decoding: d, as: UTF8.self))
                }
            }
        }
        return parts.joined(separator: " ").lowercased()
    }

    private static func contains(_ text: String, word: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            if !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber { return true }
            from = r.upperBound
        }
        return false
    }

    /// Name/folder/read-me heuristic. `others` are the other installed conversions (a plug-in that
    /// names one of those and not this one is made for it). Offline, no resource parsing.
    public static func compatibility(of plugin: PluginBundle, with tc: PluginBundle,
                                     others: [PluginBundle] = []) -> Compatibility {
        guard !plugin.isTotalConversion else { return .unlikely("A total conversion cannot be an add-on") }
        let text = descriptiveText(of: plugin)
        let mine = aliases(of: tc)
        if let hit = mine.first(where: { contains(text, word: $0) }) {
            return .recommended("Mentions \(hit.uppercased() == hit ? hit.uppercased() : hit.capitalized)")
        }
        for o in others where o.isTotalConversion && o.id != tc.id {
            if let hit = aliases(of: o).first(where: { contains(text, word: $0) }) {
                return .unlikely("Made for \(o.name)")
            }
        }
        return .neutral
    }

    /// Record-overlap check against the conversion's own resources: of the plug-in's records of the
    /// core types that also exist in the conversion, how many carry the SAME name (it replaces a
    /// conversion record) vs a DIFFERENT name (it was written for other data, i.e. the base game).
    /// Additive plug-ins (new ids) and unnamed records are ignored, so this stays `neutral` unless
    /// it is clear. `plugin` is parsed here; `tcResources` is the conversion alone (Nova.rez + its Nova Files).
    public static func overlap(of plugin: PluginBundle, in tcResources: ResourceCollection) -> Compatibility {
        let types: [FourCharCode] = [NovaType.ship, NovaType.weapon, NovaType.outfit, NovaType.spob, NovaType.syst]
        var same = 0, different = 0
        for url in plugin.fileURLs {
            guard let col = try? ResourceFile.read(contentsOf: url) else { continue }
            for t in types {
                for r in col.resources(of: t) {
                    guard let tcr = tcResources.resource(t, r.id), !r.name.isEmpty, !tcr.name.isEmpty else { continue }
                    if r.name.caseInsensitiveCompare(tcr.name) == .orderedSame { same += 1 } else { different += 1 }
                }
            }
        }
        if same >= 5 && same > different * 2 { return .recommended("Replaces \(same) records of this conversion") }
        if different >= 5 && different > same * 2 {
            return .unlikely("\(different) of its records replace different content here (made for another game data set)")
        }
        return .neutral
    }

    /// Combines the cheap and the deep verdicts: a name match always wins, an explicit "unlikely"
    /// from either stays, otherwise whichever is informative.
    public static func combine(_ a: Compatibility, _ b: Compatibility) -> Compatibility {
        if case .recommended = a { return a }
        if case .unlikely = a { return a }
        return b
    }

    // MARK: Media folders

    /// Where loose media (title music, `dësc` movies, fonts) is looked up, in priority order.
    /// The original asks "Nova Plug-ins" first, then "Nova Files" (`Ui_PlayMovieFileModal` 0x0049db00,
    /// `FUN_004ab5d0`); under a total conversion both are the conversion's own folders (the data root
    /// is its folder) plus, as an enhancement, the folders of the add-ons the user put on it.
    public struct MediaDirectories: Equatable, Sendable {
        public var plugIns: [URL]
        public var novaFiles: [URL]
        public var all: [URL] { plugIns + novaFiles }
    }

    public static func mediaDirectories(plugins: [PluginBundle], baseDir: URL?) -> MediaDirectories {
        var plugIns: [URL] = [], novaFiles: [URL] = []
        func add(_ list: inout [URL], _ u: URL?) {
            guard let u = u?.standardizedFileURL, !list.contains(u) else { return }
            list.append(u)
        }
        let active = plugins.filter(\.isEnabled)
        if let tc = active.last(where: \.isTotalConversion) {
            for id in tc.addOnIDs.reversed() {
                guard let p = plugins.first(where: { $0.id == id }) else { continue }
                for u in p.allFileURLs { add(&plugIns, u.deletingLastPathComponent()) }
                add(&plugIns, p.folderURL)
                if let f = folder(of: p) { add(&plugIns, f) }
            }
            for u in tc.fileURLs { add(&plugIns, u.deletingLastPathComponent()) }
            for u in tc.novaFilesURLs { add(&novaFiles, u.deletingLastPathComponent()) }
        } else {
            for p in active.reversed() {
                for u in p.allFileURLs { add(&plugIns, u.deletingLastPathComponent()) }
                add(&plugIns, p.folderURL)
            }
        }
        if let baseDir {
            add(&novaFiles, baseDir.appendingPathComponent("Nova Files", isDirectory: true))
            add(&novaFiles, baseDir)
        }
        plugIns = plugIns.filter { FileManager.default.fileExists(atPath: $0.path) }
        novaFiles = novaFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        return MediaDirectories(plugIns: plugIns, novaFiles: novaFiles)
    }

    /// The first file called `name` (case-insensitive) in the media folders, searched flat in order
    /// like the original, then one level of subfolders as an enhancement (imported data may be nested).
    public static func findMedia(named name: String, in dirs: MediaDirectories) -> URL? {
        let fm = FileManager.default
        for dir in dirs.all {
            if let names = try? fm.contentsOfDirectory(atPath: dir.path),
               let hit = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return dir.appendingPathComponent(hit)
            }
        }
        for dir in dirs.all {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { return u }
        }
        return nil
    }

    // MARK: Fonts

    /// Font files (`.ttf`/`.otf`) a total conversion ships next to its `Nova Files` (EV Classic / EV
    /// Override: `Sillycon.ttf` in the conversion's root), its Plug-Ins, and its add-ons' folders; a
    /// frontend registers them so the data's `ïntf` status font resolves. Nothing outside a
    /// conversion: the base game's own fonts (Charcoal, Geneva) are handled by the import step.
    public static func fontFiles(in dirs: MediaDirectories) -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        for d in dirs.all {
            roots.append(d)
            // The conversion's root (the folder holding `Nova Files/`) is where its font sits.
            if ["nova files", "plug-ins", "nova plug-ins"].contains(d.lastPathComponent.lowercased()) {
                roots.append(d.deletingLastPathComponent())
            }
        }
        var seen = Set<String>(), out: [URL] = []
        for r in roots {
            let kids = (try? fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil)) ?? []
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ["ttf", "otf"].contains(k.pathExtension.lowercased()) && seen.insert(k.path).inserted {
                out.append(k)
            }
        }
        return out
    }
}
