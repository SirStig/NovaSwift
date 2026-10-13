import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

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

        var symbol: String {
            switch self {
            case .all: return "list.bullet"
            case .held: return "checkmark.circle.fill"
            case .orphan: return "questionmark.circle"
            }
        }
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
            DevBrowserFrame(query: $query, placeholder: "Search bits or mission names…",
                            count: filtered.count, noun: "bit", symbol: "switch.2") {
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
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                DevFilterChip(title: f.rawValue, color: devConsoleGreen, active: filter == f,
                              symbol: f.symbol) { filter = f }
            }
            Spacer(minLength: 4)
            DevPill(text: "\(held.count) held", color: devConsoleGreen)
        }
        .padding(.horizontal, 12).padding(.top, 10)
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
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * devFontScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 10)
                    Text("bit \(bit)")
                        .font(.system(size: 13 * devFontScale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(expanded ? devConsoleGreen : .white)
                    Text(summary)
                        .font(.system(size: 10 * devFontScale, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stateChip
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
                    DevActionChip("Set", "bit set \(bit)", console: console, symbol: "checkmark")
                    DevActionChip("Clear", "bit clear \(bit)", console: console,
                                  destructive: true, symbol: "xmark")
                    DevActionChip("Toggle", "bit toggle \(bit)", console: console,
                                  symbol: "arrow.left.arrow.right", tint: devConsoleOrange)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(expanded ? devConsoleGreen.opacity(0.07) : .white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(expanded ? devConsoleGreen.opacity(0.4) : devHairline))
    }

    private var stateChip: some View {
        DevPill(text: isSet ? "set" : "clear",
                color: isSet ? devConsoleGreen : .white.opacity(0.5),
                symbol: isSet ? "checkmark.circle.fill" : "circle")
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(title == "TESTED BY" ? devConsoleBlue : devConsoleGreen)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.system(size: 9.5 * devFontScale, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(title == "TESTED BY" ? devConsoleBlue : devConsoleGreen)
                }
                ForEach(refs) { ref in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line(ref))
                            .font(.system(size: 10 * devFontScale, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if case let .test(negated) = ref.role {
                            DevPill(text: negated ? "needs clear" : "needs set",
                                    color: negated ? devConsoleOrange : devConsoleBlue)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    private func line(_ ref: NCBReference) -> String {
        "\(ref.kind) #\(ref.resourceID) \(ref.resourceName) · \(ref.field)"
    }
}
