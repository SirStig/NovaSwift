import Foundation

/// A persistent, cross-launch cache of `StorylineAnalyzer.storylineTags()` —
/// the whole-data-set mission→storyline lookup table. Reconstructing that
/// table means scanning every `mïsn`/`crön`'s control-bit scripts
/// (`StorylineAnalyzer.indexBitSources()`), which is cheap once but wasteful
/// to redo on every mission screen; this mirrors `SpriteDiskCache`'s
/// fingerprint-keyed, lazily-pruned pattern so the table is computed at most
/// once per data set (base game + enabled plug-ins) per launch, and persists
/// across launches on a warm cache.
///
/// A single small JSON file per fingerprint (unlike `SpriteDiskCache`'s
/// per-record files) — the whole table is a few hundred small entries, so
/// there's no benefit to splitting it up.
public final class StorylineTagCache: @unchecked Sendable {
    private let fileURL: URL

    public init?(fingerprint: String, subdirectory: String = "NovaSwift/StorylineTags") {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true) else { return nil }
        let root = caches.appendingPathComponent(subdirectory, isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        self.fileURL = root.appendingPathComponent("\(fingerprint).json", isDirectory: false)
        Self.pruneStale(under: root, keeping: fingerprint)
    }

    /// Load the cached table, or nil on a miss (including a corrupt/stale record).
    public func load() -> [Int: MissionStorylineTag]? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder().decode([Int: MissionStorylineTag].self, from: data)
    }

    /// Persist `tags`. Best-effort: a write failure just means the next
    /// launch recomputes.
    public func store(_ tags: [Int: MissionStorylineTag]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes any other fingerprint's cache file — the data set changed
    /// (new base data, a plug-in toggled), so old tables are just clutter.
    private static func pruneStale(under root: URL, keeping fingerprint: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let keep = "\(fingerprint).json"
        for url in entries where url.lastPathComponent != keep {
            try? fm.removeItem(at: url)
        }
    }
}
