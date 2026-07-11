import SwiftUI
import UniformTypeIdentifiers
import NovaSwiftKit

/// Explains the bring-your-own-data model and imports the user's owned EV Nova
/// base data into the app container. Plug-ins ship prebundled; the copyrighted
/// base game is never bundled — the user supplies it once. See docs/GET_THE_DATA.md.
struct ImportDataView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}
    @State private var importing = false
    @State private var message: String?

    // Presented in the game's own dialog chrome (`NovaDialog`). Note the
    // "Choose data…" action degrades gracefully by design: before any data is
    // imported there is no game art, so NovaDialog and this button render
    // their clean fallback style — after a successful import they pick up the
    // real panel/button art.
    var body: some View {
        NovaDialog(title: "Import Data", width: 480, buttons: [
            NovaDialogButton(title: "Choose data…", isDefault: true) { importing = true },
            NovaDialogButton(title: "Done") { onClose() },
        ]) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Bring your own data", systemImage: "externaldrive.badge.person.crop")
                    .novaFont(.heading, weight: .bold)
                Text("EV Nova's game data is copyrighted and not included. To play, import your own legally-obtained EV Nova install — pick the top-level game folder (or a .rez/.ndat file). Picking the whole folder, not just **Nova Files**, also picks up the original Charcoal/Geneva fonts and soundtrack if your copy includes them.")
                    .novaFont(.body)
                Text("On iPhone/iPad you can bring it in via the Files app, AirDrop, or “Open in”. Community plug-ins are already bundled and can be toggled under Plug-ins.")
                    .novaFont(.caption).foregroundStyle(.secondary)

                if let message {
                    Text(message).novaFont(.caption).foregroundStyle(.secondary)
                }
                Text(model.data.status).novaFont(.caption).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let src = try result.get().first else { return }
            let count = try DataImporter.importBase(from: src, into: model.data.importedBaseDir)
            model.data.reload()
            message = "Imported \(count) data file(s)."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Copies resource files (`.rez`/`.ndat`) — and any bundled soundtrack file
/// (e.g. `Nova Music.mp3`) or original fonts (`Charcoal.ttf`/`Geneva.ttf`) —
/// from a chosen folder or file into the app's base-data directory. Handles
/// iOS security-scoped URLs.
///
/// `GameLibrary.discoverResourceFiles` deliberately only looks at resource
/// containers, so without also copying audio/font files here, `GameDataController.
/// musicTrackURL()`/`registerFonts(from:)` would search a sandbox copy that
/// never had them in it — even the player's own EV Nova install ships them
/// right alongside the `.rez`s.
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
