#if os(macOS)
import SwiftUI
import CoreGraphics
import NovaSwiftKit

/// Frame-0 thumbnails of stellar graphics, keyed by the spöb `type` value
/// (spïn id = 1000 + type). Decoded off-main from a snapshot of the effective
/// collection; nothing is decoded while drawing.
@MainActor
final class StellarSpriteCache: ObservableObject {
    struct Entry { let image: CGImage; let size: CGSize }

    private var entries: [Int: Entry] = [:]
    private var missing: Set<Int> = []
    private var loading: Set<Int> = []
    private var generation = 0
    @Published private(set) var version = 0

    /// Types of resources whose change invalidates sprites.
    static let relevant: Set<NovaSwiftKit.FourCharCode> = [NovaType.spin, NovaType.rleD, NovaType.pict, NovaType.rle8]

    func invalidate() {
        generation += 1
        entries.removeAll(); missing.removeAll(); loading.removeAll()
        version += 1
    }

    /// Cached sprite, or nil (a load is started; `version` bumps when it lands).
    func entry(type: Int, collection: @autoclosure () -> ResourceCollection) -> Entry? {
        if let e = entries[type] { return e }
        if type < 0 || missing.contains(type) || loading.contains(type) { return nil }
        loading.insert(type)
        let snapshot = collection()
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let game = NovaGame(snapshot)
            var result: Entry?
            if let sheet = game.spinSheet(1000 + type), let cg = sheet.frameCGImage(0) {
                result = Entry(image: cg, size: CGSize(width: sheet.frameWidth, height: sheet.frameHeight))
            }
            let final = result
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.loading.remove(type)
                if let final { self.entries[type] = final } else { self.missing.insert(type) }
                self.version += 1
            }
        }
        return nil
    }
}

/// A searchable pick-list in a popover (for the 1.5k systems / hundreds of stellars).
struct MapSearchPicker<Label: View>: View {
    let items: () -> [(id: Int, name: String)]
    let onPick: (Int) -> Void
    @ViewBuilder var label: Label
    @State private var shown = false
    @State private var query = ""

    var body: some View {
        Button { query = ""; shown = true } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                let all = items()
                let q = query.lowercased()
                let rows = q.isEmpty ? Array(all.prefix(80)) : Array(all.filter { $0.name.lowercased().contains(q) || String($0.id) == q }.prefix(80))
                VStack(spacing: 6) {
                    TextField("Search\u{2026}", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.id) { r in
                                Button { shown = false; onPick(r.id) } label: {
                                    HStack {
                                        Text(r.name).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        Text("#\(r.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 3).padding(.horizontal, 6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if rows.isEmpty { Text("No matches").font(.caption).foregroundStyle(.secondary).padding(8) }
                        }
                    }
                    .frame(height: 260)
                }
                .padding(10).frame(width: 280)
            }
    }
}
#endif
