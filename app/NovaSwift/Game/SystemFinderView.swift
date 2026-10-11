import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

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
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    /// Discovery level > 0 (visited, revealed or charted), in system order.
    private var known: [SystRes] {
        guard nav.game != nil else { return [] }
        return nav.systems().filter { pilot.state.isSystemExplored($0.id) }
    }

    private var filtered: [SystRes] {
        let q = StarMapFind.normalize(query)
        guard !q.isEmpty else { return known.sorted { $0.displayName < $1.displayName } }
        return known.filter { StarMapFind.normalize($0.displayName).starts(with: q) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Return in the search field is the original's Find: the longest-common-
    /// prefix winner (0x004aab30), or a failure beep.
    private func submit() {
        if let id = StarMapFind.find(query, in: known.map { ($0.id, $0.displayName) }),
           let system = nav.system(id) {
            model.audio.play(.beep5)   // NovaUi_RunStarmapSearchDialog 0x004aab30: a match, snd 154
            pick(system)
        } else {
            model.audio.play(.beep4)   // no match, snd 153
        }
    }

    private func pick(_ system: SystRes) {
        // The original's Find only selects the system and re-centres; the
        // `autoRoutePlotting` enhancement plots a course there too.
        if nav.autoRoutePlotting { nav.plotCourse(to: system.id) }
        nav.selectedSystemID = system.id
        onSelect(system)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { system in
                Button {
                    pick(system)
                } label: {
                    HStack {
                        Text(system.displayName).novaFont(.body)
                        Spacer()
                        if system.id == nav.currentSystemID {
                            Text("Current").novaFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.novaPlain)
            }
            .overlay {
                if filtered.isEmpty {
                    Text(known.isEmpty ? "No charted systems yet." : "No systems match “\(query)”.")
                        .novaFont(.body).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "System name")
            .onSubmit(of: .search) { submit() }
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
