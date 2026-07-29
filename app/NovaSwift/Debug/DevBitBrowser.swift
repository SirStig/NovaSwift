import SwiftUI
import NovaSwiftKit

/// The console's **control-bits (NCB) browser**.
///
/// EV Nova's entire story state is a sparse set of numbered bits, and the raw
/// editor that came before this could only poke a number and list which ones
/// were set — which tells you nothing about what any of them *mean*. Every
/// meaning is already declared in the data, though, just in the opposite
/// direction: missions say what they set on success and what they require to
/// be offered. `NCBIndex` inverts that, so a bit can explain itself:
///
///     bit 1042  [SET]
///       SET BY     mïsn #157 Ambush at Kania · OnSuccess
///       TESTED BY  mïsn #158 Kania Aftermath · AvailBits (needs set)
///                  crön #131 Kania patrols · EnableOn (needs set)
///
/// Read downward it answers "what turned this on"; read upward, "what does
/// holding this unlock". Searching by storyline name rather than number is the
/// point — you rarely know the number you want.
struct DevBitBrowser: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController

    @State private var query = ""
    @State private var selected: Int?
    @State private var filter: Filter = .all

    /// Owned by the controller, not this view — switching tabs destroys the
    /// view, and rebuilding the cross-reference on every visit was wasteful.
    private var index: NCBIndex { console.ncbIndex }
    private var indexing: Bool { index.bits.isEmpty && model.data.game != nil }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", held = "Held", orphan = "Orphans"
        var id: String { rawValue }
    }

    private var held: Set<Int> { model.pilot.state.setBits }

    /// Every bit worth showing: those referenced anywhere in the data, plus any
    /// the pilot holds — a held bit that appears nowhere in the data still has
    /// to be visible, since that combination is usually the bug.
    private var universe: [Int] {
        switch filter {
        case .all: return Array(Set(index.bits).union(held)).sorted()
        case .held: return held.sorted()
        case .orphan: return held.subtracting(index.bits).sorted()
        }
    }

    private var filtered: [Int] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return universe }
        return universe.filter {
            "\($0)".contains(q) || (index.searchText[$0]?.contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            DevBrowserFrame(query: $query, placeholder: "search bits or mission names…",
                            count: filtered.count, noun: "bit") {
                if indexing {
                    Text("Indexing control bits…")
                        .font(.system(size: 11 * devFontScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                ForEach(filtered, id: \.self) { bit in
                    BitRow(bit: bit,
                           isSet: held.contains(bit),
                           references: index.references(for: bit),
                           expanded: selected == bit,
                           onTap: { selected = selected == bit ? nil : bit },
                           console: console)
                }
            }
        }
        .task(id: model.data.dataStamp) {
            await console.buildNCBIndexIfNeeded(game: model.data.game,
                                                stamp: model.data.dataStamp)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases) { f in
                let on = filter == f
                CursorButton { filter = f } label: {
                    Text(f.rawValue)
                        .font(.system(size: 9 * devFontScale, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(on ? devConsoleGreen.opacity(0.22) : .white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(on ? devConsoleGreen.opacity(0.6) : .clear))
                        .foregroundStyle(on ? devConsoleGreen : .white.opacity(0.6))
                        .contentShape(Rectangle())
                }
            }
            Spacer()
            Text("\(held.count) held")
                .font(.system(size: 9 * devFontScale, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

}

// MARK: - Row

private struct BitRow: View {
    let bit: Int
    let isSet: Bool
    let references: [NCBReference]
    let expanded: Bool
    let onTap: () -> Void
    let console: ConsoleController

    private var setters: [NCBReference] { references.filter { $0.role == .set } }
    private var clearers: [NCBReference] { references.filter { $0.role == .clear } }
    private var togglers: [NCBReference] { references.filter { $0.role == .toggle } }
    private var tests: [NCBReference] { references.filter(\.isTest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CursorButton(action: onTap) {
                HStack(spacing: 10) {
                    stateChip
                    VStack(alignment: .leading, spacing: 2) {
                        Text("bit \(bit)")
                            .font(.system(size: 12 * devFontScale, weight: .semibold,
                                          design: .monospaced))
                        Text(summary)
                            .font(.system(size: 9 * devFontScale, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    group("SET BY", setters)
                    group("CLEARED BY", clearers)
                    group("TOGGLED BY", togglers)
                    group("TESTED BY", tests)
                    if references.isEmpty {
                        Text("Referenced nowhere in this data set — nothing sets, clears or reads it. Usually a plug-in bit, or a stale bit left in the save.")
                            .font(.system(size: 10 * devFontScale, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 5)], spacing: 5) {
                    DevActionChip("Set", "bit set \(bit)", console: console)
                    DevActionChip("Clear", "bit clear \(bit)", console: console, destructive: true)
                    DevActionChip("Toggle", "bit toggle \(bit)", console: console)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(expanded ? devConsoleGreen.opacity(0.1) : .white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(expanded ? devConsoleGreen.opacity(0.4) : .white.opacity(0.07)))
    }

    private var stateChip: some View {
        Text(isSet ? "SET" : "CLR")
            .font(.system(size: 9 * devFontScale, weight: .bold, design: .monospaced))
            .frame(width: 38 * devFontScale)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isSet ? devConsoleGreen.opacity(0.25) : .white.opacity(0.06)))
            .foregroundStyle(isSet ? devConsoleGreen : .white.opacity(0.45))
    }

    private var summary: String {
        guard !references.isEmpty else { return "no references" }
        var parts: [String] = []
        let writers = setters.count + clearers.count + togglers.count
        if writers > 0 { parts.append("\(writers) writer\(writers == 1 ? "" : "s")") }
        if !tests.isEmpty { parts.append("\(tests.count) test\(tests.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func group(_ title: String, _ refs: [NCBReference]) -> some View {
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 9 * devFontScale, weight: .bold, design: .monospaced))
                    .foregroundStyle(devConsoleGreen.opacity(0.9))
                ForEach(refs) { ref in
                    Text(line(ref))
                        .font(.system(size: 9.5 * devFontScale, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func line(_ ref: NCBReference) -> String {
        var text = "\(ref.kind) #\(ref.resourceID) \(ref.resourceName) · \(ref.field)"
        // Polarity is the whole point for a test: whether this gate wants the
        // bit set or clear decides if holding it helps or blocks you.
        if case let .test(negated) = ref.role {
            text += negated ? " (needs clear)" : " (needs set)"
        }
        return text
    }
}
