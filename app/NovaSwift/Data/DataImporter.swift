import Foundation
import NovaSwiftKit

/// Copies resource files (`.rez`/`.ndat`) — and any bundled soundtrack file
/// (e.g. `Nova Music.mp3`) or original fonts (`Charcoal.ttf`/`Geneva.ttf`) —
/// from a chosen folder or file into the app's base-data directory. Handles
/// iOS security-scoped URLs. Driven by `DataSetupWizard`'s Import step.
///
/// `GameLibrary.discoverResourceFiles` deliberately only looks at resource
/// containers, so without also copying audio/font/video files here,
/// `GameDataController.musicTrackURL()`/`registerFonts(from:)`/`raceVideoURL()`
/// would search a sandbox copy that never had them in it — even the player's own
/// EV Nova install ships them right alongside the `.rez`s.
enum DataImporter {
    @discardableResult
    static func importBase(from src: URL, into destDir: URL) throws -> Int {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var sources: [URL] = []
        if (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            sources = GameLibrary.discoverResourceFiles(in: src)
                + GameDataController.discoverAudioFiles(in: src)
                + GameDataController.discoverFontFiles(in: src)
                + GameDataController.discoverVideoFiles(in: src)
        } else {
            sources = [src]
        }
        var copied = 0
        for file in sources {
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
            copied += 1
        }
        return copied
    }
}
