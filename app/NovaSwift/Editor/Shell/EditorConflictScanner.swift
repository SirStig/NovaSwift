#if os(macOS)
import Foundation
import NovaSwiftKit

/// Finds, for the keys a document defines, which other enabled plug-ins define them too.
/// Parsing a plug-in file is the expensive part, so each file's key set (not the parsed
/// resources) is cached by path + size + modification date and reused across opens and saves.
/// Thread-safe; call from a background task.
final class EditorConflictScanner: @unchecked Sendable {
    private struct Entry { var size: Int; var modified: Date?; var keys: Set<ResourceKey> }
    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Set<ResourceKey>?]
        init(count: Int) { items = [Set<ResourceKey>?](repeating: nil, count: count) }
        func set(_ i: Int, _ v: Set<ResourceKey>?) { lock.lock(); items[i] = v; lock.unlock() }
        var values: [Set<ResourceKey>?] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    /// Editor-only bookkeeping that every editor stamps into a file; never a real clash.
    private static let ignored: Set<NovaSwiftKit.FourCharCode> = [PluginDocument.metadataType, NovaSwiftKit.FourCharCode("dsïg")!]

    /// `files` are the other plug-ins' files in effective load order (later wins in game).
    /// Result: key -> plug-in names that also define it, in load order, each name once.
    func conflicts(of layer: ResourceCollection, with files: [(name: String, url: URL)]) -> [ResourceKey: [String]] {
        guard !files.isEmpty else { return [:] }
        var mine = Set<ResourceKey>()
        for (type, rs) in layer.byType where !Self.ignored.contains(type) {
            for id in rs.keys { mine.insert(ResourceKey(type, id)) }
        }
        guard !mine.isEmpty else { return [:] }

        // Parse the files we haven't seen (or that changed) concurrently.
        let slots = Slots(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            slots.set(i, self.keys(of: files[i].url))
        }
        let sets = slots.values

        var out: [ResourceKey: [String]] = [:]
        for (i, f) in files.enumerated() {
            guard let theirs = sets[i] else { continue }
            for k in theirs.intersection(mine) {
                var names = out[k] ?? []
                if names.last != f.name, !names.contains(f.name) { names.append(f.name) }
                out[k] = names
            }
        }
        return out
    }

    private func keys(of url: URL) -> Set<ResourceKey>? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? -1
        let modified = attrs?[.modificationDate] as? Date
        let path = url.standardizedFileURL.path
        lock.lock()
        if let e = cache[path], e.size == size, e.modified == modified { lock.unlock(); return e.keys }
        lock.unlock()
        guard let col = try? ResourceFile.read(contentsOf: url) else { return nil }
        var keys = Set<ResourceKey>()
        for (type, rs) in col.byType { for id in rs.keys { keys.insert(ResourceKey(type, id)) } }
        lock.lock(); cache[path] = Entry(size: size, modified: modified, keys: keys); lock.unlock()
        return keys
    }
}
#endif
