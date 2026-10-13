import Foundation

/// Which files of a user's EV Nova install matter to NovaSwift, shared by the Apple
/// `DataImporter` and the cross-platform `GameDataImport` (Godot frontend).
///
/// `GameLibrary.discoverResourceFiles` deliberately only looks at resource containers; the
/// original soundtrack, fonts, holovid races and `EVNova.ini` ship right beside them and must
/// be found separately. Moved here from `GameDataController` / `DataImporter` with no change in
/// behaviour.
public enum GameFileDiscovery {
    /// Audio file extensions EV Nova's shipped soundtrack might use (e.g. the CE's `Nova Music.mp3`).
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "aiff", "aif", "wav"]
    /// The game's original fonts (Charcoal.ttf, Geneva.ttf).
    public static let fontExtensions: Set<String> = ["ttf", "otf"]
    /// Holovid clip extensions (the Galaxy Racing Network's "Race 1.mov"..).
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Recursively find files under `directory` whose extension is in `exts`.
    public static func discover(in directory: URL, extensions exts: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { exts.contains($0.pathExtension.lowercased()) }
    }

    public static func discoverAudioFiles(in directory: URL) -> [URL] { discover(in: directory, extensions: audioExtensions) }
    public static func discoverFontFiles(in directory: URL) -> [URL] { discover(in: directory, extensions: fontExtensions) }
    public static func discoverVideoFiles(in directory: URL) -> [URL] { discover(in: directory, extensions: videoExtensions) }

    /// `EVNova.ini` sitting directly in `directory`, if any.
    public static func iniFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.lastPathComponent.caseInsensitiveCompare("EVNova.ini") == .orderedSame
        }
    }

    /// Everything the Apple importer copies from a game folder: resource containers, audio,
    /// fonts, holovids and the top-level `EVNova.ini` (in that order).
    public static func importableFiles(in directory: URL) -> [URL] {
        GameLibrary.discoverResourceFiles(in: directory)
            + discoverAudioFiles(in: directory)
            + discoverFontFiles(in: directory)
            + discoverVideoFiles(in: directory)
            + iniFiles(in: directory)
    }

    /// The resource kinds a data set genuinely can't play without, phrased for the import
    /// screens (moved from `GameDataController.findMissingEssentials`). Deliberately
    /// conservative: only things whose absence wedges the app or the game.
    public static func missingEssentials(in merged: ResourceCollection) -> [String] {
        var missing: [String] = []
        let counts = Dictionary(uniqueKeysWithValues: merged.typeCounts.map { ($0.type, $0.count) })
        let gameplay: [(FourCharCode, String)] = [
            (NovaType.ship, "ships"), (NovaType.syst, "star systems"),
            (NovaType.spob, "planets"), (NovaType.outfit, "outfits"),
            (NovaType.weapon, "weapons"),
        ]
        let absent = gameplay.filter { counts[$0.0, default: 0] == 0 }.map(\.1)
        if !absent.isEmpty {
            missing.append("game data (\(absent.joined(separator: "/")))")
        }
        // The main-menu button art (rlëD 8050), shipped in Nova Graphics 3.
        if merged.resource(NovaType.rleD, 8050) == nil {
            missing.append("menu art (Nova Graphics)")
        }
        return missing
    }
}
