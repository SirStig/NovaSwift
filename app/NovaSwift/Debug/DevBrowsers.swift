import SwiftUI
import NovaSwiftKit

/// The dev console's **browsers**: searchable, illustrated lists of the loaded
/// game data — ships, outfits and governments.
///
/// These exist because some developer actions are genuinely worse as typed
/// commands. Nobody remembers that the Kestrel is `#158`; you want to search
/// "kes", see the hull, and read its stats. But selecting a row does not poke
/// the model directly — it **submits the console command** the row represents
/// (`ship 158`, `spawn hostile 158`, …). So the browser is a discovery layer
/// over the same command surface: one execution path, every action recorded in
/// the scrollback, and the command you'd have typed shown right on the row.
///
/// Rows expand in place rather than pushing a detail screen — the inspector
/// rail is only ~380pt wide, and a push would hide the log you're watching.

// MARK: - Ships

struct DevShipBrowser: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController

    @State private var query = ""
    @State private var selectedID: Int?
    /// Snapshotted once rather than re-read per keystroke — `ships()` walks
    /// the whole resource fork.
    @State private var all: [ShipRes] = []

    private var graphics: SpaceportGraphics? { model.uiGraphics }

    private var filtered: [ShipRes] {
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || "\($0.id)" == query
        }
    }

    var body: some View {
        DevBrowserFrame(query: $query, placeholder: "search ships…",
                        count: filtered.count, noun: "ship") {
            ForEach(filtered, id: \.id) { ship in
                DevBrowserRow(
                    image: graphics?.shipFallbackPicture(ship),
                    title: ship.displayName,
                    id: ship.id,
                    stats: stats(ship),
                    detail: model.data.game?.descText(13000 + ship.id - 128),
                    expanded: selectedID == ship.id,
                    onTap: { selectedID = selectedID == ship.id ? nil : ship.id }
                ) {
                    DevActionChip("Fly this", "ship \(ship.id)", console: console)
                    DevActionChip("Hostile", "spawn hostile \(ship.id)", console: console,
                                  destructive: true)
                    DevActionChip("Escort", "spawn escort \(ship.id)", console: console)
                    DevActionChip("Neutral", "spawn neutral \(ship.id)", console: console)
                }
            }
        }
        .task {
            if all.isEmpty {
                all = (model.data.game?.ships() ?? []).sorted { $0.displayName < $1.displayName }
            }
        }
    }

    private func stats(_ s: ShipRes) -> String {
        "S\(s.shield) A\(s.armor) · spd \(s.speed) trn \(s.turnRate) · \(s.cost.creditsAbbreviated)"
    }
}

// MARK: - Outfits

struct DevOutfitBrowser: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController

    @State private var query = ""
    @State private var selectedID: Int?
    @State private var all: [OutfRes] = []

    private var graphics: SpaceportGraphics? { model.uiGraphics }

    private var filtered: [OutfRes] {
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.outfitterDisplayName.localizedCaseInsensitiveContains(query) || "\($0.id)" == query
        }
    }

    var body: some View {
        DevBrowserFrame(query: $query, placeholder: "search outfits…",
                        count: filtered.count, noun: "outfit") {
            ForEach(filtered, id: \.id) { outfit in
                let owned = model.pilot.state.outfits[outfit.id] ?? 0
                DevBrowserRow(
                    image: graphics?.outfitPicture(outfit),
                    title: outfit.outfitterDisplayName,
                    id: outfit.id,
                    stats: stats(outfit),
                    detail: model.data.game?.descText(outfit.id - 128 + 3000),
                    badge: owned > 0 ? "×\(owned)" : nil,
                    expanded: selectedID == outfit.id,
                    onTap: { selectedID = selectedID == outfit.id ? nil : outfit.id }
                ) {
                    DevActionChip("Grant ×1", "outfit add \(outfit.id)", console: console)
                    DevActionChip("Grant ×5", "outfit add \(outfit.id) 5", console: console)
                    DevActionChip("Remove", "outfit remove \(outfit.id)", console: console,
                                  destructive: true)
                }
            }
        }
        .task {
            if all.isEmpty {
                all = (model.data.game?.outfits() ?? [])
                    .sorted { $0.outfitterDisplayName < $1.outfitterDisplayName }
            }
        }
    }

    private func stats(_ o: OutfRes) -> String {
        var parts = [o.cost.creditsAbbreviated, "\(o.mass)t", "tech \(o.techLevel)"]
        if let mod = o.modifiers.first {
            parts.append("\(mod.type)".replacingOccurrences(of: "_", with: " "))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Governments

struct DevGovtBrowser: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var console: ConsoleController

    @State private var query = ""
    @State private var selectedID: Int?
    @State private var all: [GovtRes] = []

    private var filtered: [GovtRes] {
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || "\($0.id)" == query
        }
    }

    var body: some View {
        DevBrowserFrame(query: $query, placeholder: "search governments…",
                        count: filtered.count, noun: "govt") {
            ForEach(filtered, id: \.id) { govt in
                let record = model.pilot.state.legalRecord[govt.id] ?? 0
                DevBrowserRow(
                    swatch: Color(red: Double(govt.mapColor.r) / 255,
                                  green: Double(govt.mapColor.g) / 255,
                                  blue: Double(govt.mapColor.b) / 255),
                    title: govt.name.isEmpty ? "Govt #\(govt.id)" : govt.name,
                    id: govt.id,
                    stats: "record \(record) · \(govt.allies.count) allies · \(govt.enemies.count) enemies",
                    badge: record == 0 ? nil : (record > 0 ? "friendly" : "hostile"),
                    expanded: selectedID == govt.id,
                    onTap: { selectedID = selectedID == govt.id ? nil : govt.id }
                ) {
                    DevActionChip("Hostile", "relation \(govt.id) -30000", console: console,
                                  destructive: true)
                    DevActionChip("Neutral", "relation \(govt.id) 0", console: console)
                    DevActionChip("Friendly", "relation \(govt.id) 30000", console: console)
                }
            }
        }
        .task {
            if all.isEmpty {
                all = (model.data.game?.govts() ?? []).sorted { $0.name < $1.name }
            }
        }
    }
}

// MARK: - Shared browser chrome

/// Search field + result count + scrolling list, shared by all three browsers.
private struct DevBrowserFrame<Content: View>: View {
    @Binding var query: String
    let placeholder: String
    let count: Int
    let noun: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11 * devFontScale))
                    .foregroundStyle(.secondary)
                #if os(tvOS)
                TVCursorTextField(placeholder: placeholder, text: $query)
                #else
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * devFontScale, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                #endif
                if !query.isEmpty {
                    CursorButton { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11 * devFontScale))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Text("\(count)")
                    .font(.system(size: 10 * devFontScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 4) {
                    content()
                    if count == 0 {
                        Text("No \(noun) matches.")
                            .font(.system(size: 11 * devFontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(8)
            }
        }
    }
}

/// One browser row: thumbnail (or colour swatch), name, id, a stat line, and —
/// when expanded — the `dësc` blurb and the command chips for that item.
private struct DevBrowserRow<Actions: View>: View {
    var image: CGImage?
    var swatch: Color?
    let title: String
    let id: Int
    let stats: String
    var detail: String?
    var badge: String?
    let expanded: Bool
    let onTap: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CursorButton(action: onTap) {
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 12 * devFontScale, weight: .semibold,
                                              design: .monospaced))
                                .lineLimit(1)
                            if let badge {
                                Text(badge)
                                    .font(.system(size: 8 * devFontScale, weight: .bold,
                                                  design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(devConsoleGreen.opacity(0.25)))
                                    .foregroundStyle(devConsoleGreen)
                            }
                            Spacer(minLength: 0)
                            Text("#\(id)")
                                .font(.system(size: 9 * devFontScale, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(stats)
                            .font(.system(size: 9 * devFontScale, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .contentShape(Rectangle())
            }

            if expanded {
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10 * devFontScale, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Chips wrap onto a second line rather than squeezing: four
                // actions never fit one 380pt row legibly.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 5)], spacing: 5) {
                    actions()
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(expanded ? devConsoleGreen.opacity(0.1) : .white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(expanded ? devConsoleGreen.opacity(0.4) : .white.opacity(0.07)))
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 40 * devFontScale, height: 40 * devFontScale)
        } else if let swatch {
            RoundedRectangle(cornerRadius: 5)
                .fill(swatch)
                .frame(width: 40 * devFontScale, height: 40 * devFontScale)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.06))
                .frame(width: 40 * devFontScale, height: 40 * devFontScale)
                .overlay(Image(systemName: "questionmark")
                    .font(.system(size: 12 * devFontScale))
                    .foregroundStyle(.white.opacity(0.3)))
        }
    }
}

/// A browser action button. Shows a friendly label but submits the command,
/// so the log records `> spawn hostile 158` exactly as if typed.
private struct DevActionChip: View {
    let title: String
    let command: String
    let console: ConsoleController
    var destructive = false

    init(_ title: String, _ command: String, console: ConsoleController,
         destructive: Bool = false) {
        self.title = title
        self.command = command
        self.console = console
        self.destructive = destructive
    }

    var body: some View {
        let tint = destructive ? devConsoleRed : devConsoleGreen
        CursorButton { console.submit(command) } label: {
            Text(title)
                .font(.system(size: 10 * devFontScale, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.5)))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
    }
}
