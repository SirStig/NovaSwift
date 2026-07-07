import SwiftUI
import UniformTypeIdentifiers
import EVNovaKit

/// Explains the bring-your-own-data model and imports the user's owned EV Nova
/// base data into the app container. Plug-ins ship prebundled; the copyrighted
/// base game is never bundled — the user supplies it once. See docs/GET_THE_DATA.md.
struct ImportDataView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Bring your own data", systemImage: "externaldrive.badge.person.crop")
                    .font(.title3.bold())
                Text("EV Nova's game data is copyrighted and not included. To play, import your own legally-obtained EV Nova data — pick the game's **Nova Files** folder (or a .rez/.ndat file).")
                Text("On iPhone/iPad you can bring it in via the Files app, AirDrop, or “Open in”. Community plug-ins are already bundled and can be toggled under Plug-ins.")
                    .font(.callout).foregroundStyle(.secondary)

                Button {
                    importing = true
                } label: {
                    Label("Choose data…", systemImage: "folder.fill.badge.plus")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Text(model.data.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Import Data")
        .toolbar { Button("Done") { dismiss() } }
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

/// Copies resource files (`.rez`/`.ndat`) from a chosen folder or file into the
/// app's base-data directory. Handles iOS security-scoped URLs.
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
