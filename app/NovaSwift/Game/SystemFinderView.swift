import SwiftUI
import NovaSwiftKit

/// "Named System" search — DITL #2000 idx8 (`novaswift-extract ditl "data/EV Nova/Nova.rez" 2000`,
/// item 8, 130×25, bottom-left of the Map dialog's button row). The real dialog has no room to
/// spell out every system name, so it opens this as a searchable picker; selecting a result plots
/// a course the same way tapping the system on the starmap does (`nav.plotCourse(to:)`).
///
/// Only systems the player actually knows about are listed — the same fog-of-war rule the map
/// canvas itself draws under (`NavigationModel.visibility(of:explored:adjacent:charted:)`):
/// merely-adjacent (glimpsed-but-unvisited) systems are left off since their real name hasn't
/// been learned in-fiction, same as the map hides their label.
struct SystemFinderView: View {
    @ObservedObject var nav: NavigationModel
    @ObservedObject var pilot: PilotStore
    /// Called after a course has been plotted, so the presenter can also recentre the map.
    var onSelect: (SystRes) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var known: [SystRes] {
        guard nav.game != nil else { return [] }
        let explored = pilot.state.exploredSystems
        let charted = pilot.chartedSystems
        let adjacent = nav.adjacentToKnown(explored: explored, charted: charted)
        return nav.systems()
            .filter {
                let vis = nav.visibility(of: $0.id, explored: explored, adjacent: adjacent, charted: charted)
                return vis == .explored || vis == .chartered
            }
            .sorted { $0.name < $1.name }
    }

    private var filtered: [SystRes] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? known : known.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { system in
                Button {
                    nav.plotCourse(to: system.id)
                    onSelect(system)
                    dismiss()
                } label: {
                    HStack {
                        Text(system.name).novaFont(.body)
                        Spacer()
                        if system.id == nav.currentSystemID {
                            Text("Current").novaFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if filtered.isEmpty {
                    Text(known.isEmpty ? "No charted systems yet." : "No systems match “\(query)”.")
                        .novaFont(.body).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "System name")
            .navigationTitle("Named System")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
