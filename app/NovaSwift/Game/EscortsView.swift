import SwiftUI
import NovaSwiftEngine
import NovaSwiftStory
import NovaSwiftKit

/// The in-flight **Escorts** command window — an authentic recreation of
/// DLOG/DITL #1022 "Escorts" (`novaswift-extract dlog "data/EV Nova/Nova.rez"
/// 1022` → DLOG bounds 424×259, DITL "Escorts" 12 items whose rects ARE the
/// pixel layout; frame art PICT #8513 "Escort communications").
///
/// EV Nova opens this window when you **hail one of your own escorts** — so the
/// container gates it on hailing a targeted escort ship, exactly as the generic
/// comm dialog (`HailDialogView`, DITL #1007) is gated on hailing anyone else.
/// It is built from the same authentic pieces every other game screen uses —
/// the real frame PICT, three-slice `NovaButton` art, and Geneva `NovaText`,
/// placed straight from the DITL item rects (via `NovaSpace`/`.novaPlace`, see
/// `NovaMenu.swift`) — with no native SwiftUI chrome.
///
/// Live layout, from DITL #1022 (top,left)-(bottom,right):
///  - items 2/3/1/0 (146×26, x=29) → the four stacked standing-order buttons
///  - item 9  (14,9)-(206,67)   192×58 → wing summary  (drawn on the PICT's box)
///  - item 11 (14,79)-(206,131) 192×52 → current standing order
///  - item 10 (217,30)-(417,230) 200×200 → the roster list / empty state
///
/// The captured-escort economy actions (Release / Upgrade / Sell) that EV Nova
/// itself routes through this hail have no on-PICT slot inside the 259px frame
/// (the DITL's own action items 4–7 sit *below* the visible window), so they
/// live in an action strip appended under the frame — styled to read as part of
/// the window, still built entirely from `NovaButton` art.
struct EscortsView: View {
    /// The session's interface art, for the real frame PICT #8513 and three-slice
    /// buttons. Nil only in the no-data preview path → falls back to plain chrome.
    var graphics: SpaceportGraphics? = nil
    var escorts: [GameScene.EscortInfo] = []
    /// The persistent escort records (origin, daily fee) joined to the live wing
    /// by `EscortInfo.recordID`, so each row can show whether it's hired (and its
    /// upkeep) vs a free captured ship, and offer the right hail action.
    var records: [EscortRecord] = []
    /// Ship data, to resolve a captured escort's upgrade target/cost and resale
    /// value for the hail menu. Nil in the demo path → upgrade/sell hidden.
    var game: NovaGame? = nil
    var currentOrder: EscortOrder? = nil
    var onCommand: (EscortOrder) -> Void = { _ in }
    /// AI-35: under the original AI, orders go to one EscortType group (nil =
    /// all ships; 0 fighters, 1 medium, 2 warships, 3 freighters) as the
    /// original's escort overlay does, and Return to Hangar exists. Nil keeps
    /// the port's whole-wing orders.
    var onGroupCommand: ((_ category: Int?, _ command: Int) -> Void)? = nil
    /// STR# 2002, for the group and order labels (#140–#149).
    var strings: StringListRes? = nil
    @State private var group: Int? = nil
    @Environment(\.novaTheme) private var theme
    /// Release / dismiss the escort with this `EscortRecord.id` — EV Nova's
    /// "Release from Servitude" hail action.
    var onRelease: (Int) -> Void = { _ in }
    /// The pilot, for the Upgrade gate (the target hull's availability
    /// expression, `PilotEconomy.escortUpgradeTarget`). Nil in the demo path.
    var pilot: PlayerState? = nil
    /// Mark the escort with this record id for an upgrade to its hull's
    /// `UpgradeTo` — no charge yet; the fleet pass applies it on leaving a
    /// shipyard stellar (EC-22, `PilotEconomy.processEscortFleetAtStellar`).
    var onUpgrade: (Int) -> Void = { _ in }
    /// Clear the upgrade mark for the escort with this record id.
    var onCancelUpgrade: (Int) -> Void = { _ in }
    /// Mark the captured escort with this record id to be sold at the next
    /// shipyard, for its `EscSellValue`.
    var onSell: (Int) -> Void = { _ in }
    /// Clear the sale mark for the escort with this record id.
    var onCancelSale: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}

    /// The selected row's live `EscortInfo.id` (entity id) — entity-keyed, not
    /// record-keyed, so a fighter (which has no `EscortRecord`) can still be
    /// selected to show its status; only the action strip's Upgrade/Sell/Release
    /// gate on whether that selection is a fighter.
    @State private var selectedEntityID: Int? = nil

    // PICT #8513's decoded size — the coordinate origin every item is placed
    // relative to (frame centre, top-left anchored; see NovaMenu.swift).
    private static let framePICT = 8513
    private static let frameW: CGFloat = 424
    private static let frameH: CGFloat = 259
    private static let actionBarH: CGFloat = 42
    private let space = NovaSpace(width: frameW, height: frameH)

    private var hasEscorts: Bool { !escorts.isEmpty }

    /// The persistent record backing a live escort row (nil for an untracked
    /// wing member, e.g. a debug-spawned escort).
    private func record(for e: GameScene.EscortInfo) -> EscortRecord? {
        guard let rid = e.recordID else { return nil }
        return records.first { $0.id == rid }
    }
    /// The currently selected escort row, if the selection is still present.
    private var selectedEscort: GameScene.EscortInfo? {
        guard let eid = selectedEntityID else { return nil }
        return escorts.first { $0.id == eid }
    }
    /// The selected escort's persistent record — nil for a fighter (no record
    /// exists) or an untracked wing member.
    private var selectedRecord: EscortRecord? {
        guard let sel = selectedEscort else { return nil }
        return record(for: sel)
    }

    var body: some View {
        VStack(spacing: 0) {
            frameLayer
            actionBar
        }
        .frame(width: Self.frameW, alignment: .top)
        .background(Color(white: 0.06))
    }

    // MARK: - The authentic frame + placed items

    /// DITL #1022 resolved from the loaded data (stock rects as fallback), so a
    /// plug-in's replacement layout moves these items.
    private var ditl: DITLPlacement {
        DITLPlacement(game ?? graphics?.game, 1022, window: space.size)
    }

    private var frameLayer: some View {
        let d = ditl
        let summary = d.rect(9, top: 9, left: 14, bottom: 67, right: 206)
        let order = d.rect(11, top: 79, left: 14, bottom: 131, right: 206)
        let list = d.rect(10, top: 30, left: 217, bottom: 230, right: 417)
        return ZStack(alignment: .topLeading) {
            art

            // Item 9: wing summary, on the PICT's box.
            VStack(spacing: 3) {
                NovaText(hasEscorts ? "Escort Wing" : "No escorts",
                         size: 12, color: hasEscorts ? .white : Color(white: 0.5), weight: .bold)
                NovaText(hasEscorts ? "\(escorts.count) ship\(escorts.count == 1 ? "" : "s") under command"
                                    : "Capture or hire ships to command",
                         size: 10, color: Color(white: 0.6), width: max(0, summary.width - 12), align: .center)
            }
            .frame(width: summary.width, height: summary.height)
            .ditlPlace(space, d, summary)

            // Item 11: current standing order.
            NovaText(hasEscorts ? "Order: \(currentOrder?.title ?? "Mixed")" : "—",
                     size: 11, color: hasEscorts ? novaAmber : Color(white: 0.4),
                     width: max(0, order.width - 12), align: .center)
                .frame(width: order.width, height: order.height)
                .ditlPlace(space, d, order)

            // Item 10: the roster list / empty state.
            roster
                .frame(width: list.width, height: list.height)
                .ditlPlace(space, d, list)

            // Items 2,3,1,0 top-to-bottom — the four escort-command buttons.
            commandButton(.aggressive, d.rect(2, top: 141, left: 29, bottom: 167, right: 175), d)
            commandButton(.defensive, d.rect(3, top: 169, left: 29, bottom: 195, right: 175), d)
            commandButton(.evasive, d.rect(1, top: 197, left: 29, bottom: 223, right: 175), d)
            commandButton(.hold, d.rect(0, top: 225, left: 29, bottom: 251, right: 175), d)
        }
        .frame(width: Self.frameW, height: Self.frameH, alignment: .topLeading)
    }

    /// The real frame PICT #8513 "Escort communications" when the session's
    /// graphics are available, else a dark plate the same footprint so every
    /// item still lands where the real frame would put it.
    private var art: some View {
        Group {
            if let img = graphics?.pict(Self.framePICT) {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Color(white: 0.1))
            }
        }
        .frame(width: Self.frameW, height: Self.frameH)
    }

    // MARK: - Roster list (item 10)

    @ViewBuilder
    private var roster: some View {
        if hasEscorts {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(escorts) { escortRow($0) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NovaText("No escorts under your command.", size: 11, color: Color(white: 0.55),
                     width: 168, align: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func escortRow(_ e: GameScene.EscortInfo) -> some View {
        let selected = selectedEntityID == e.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                NovaText(e.name, size: 11, color: .white, width: 118, align: .leading, weight: .semibold)
                Spacer(minLength: 0)
                if e.isFighter { fighterLabel } else if let rec = record(for: e) { originLabel(rec) }
            }
            HStack(spacing: 6) {
                bar("SH", e.shieldFraction, Color(red: 0.4, green: 0.7, blue: 1))
                bar("AR", e.armorFraction, Color(red: 1, green: 0.72, blue: 0.3))
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Squared, inverted selection box — the classic Mac list-selection look,
        // not a rounded native pill. cölr.escortHilite drives the selection tint
        // (a solid fill for an opaque theme colour, a subtle wash for the
        // translucent amber fallback); the border uses the same colour.
        .background(selected ? theme.escortHilite : Color.clear)
        .overlay(Rectangle().strokeBorder(selected ? theme.escortHilite : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // "Hail" the escort — select it to reveal its status/actions. Fighters
            // are selectable too (to show their status), but the action strip
            // below gates Upgrade/Sell/Release off for them explicitly.
            selectedEntityID = (selectedEntityID == e.id) ? nil : e.id
        }
    }

    /// How the escort was acquired and, for a hired one, its daily upkeep — plain
    /// coloured Geneva, no native capsule pill.
    private func originLabel(_ rec: EscortRecord) -> some View {
        let (text, color): (String, Color) = {
            switch rec.origin {
            case .hired:    return ("\(rec.dailyFee)cr/day", novaAmber)
            case .captured: return ("Captured", Color(red: 0.5, green: 0.8, blue: 1))
            case .mission:  return ("Mission", Color(white: 0.6))
            }
        }()
        return NovaText(text, size: 8, color: color)
    }

    private var fighterLabel: some View {
        NovaText("Fighter", size: 8, color: Color(white: 0.6))
    }

    private func bar(_ label: String, _ frac: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            NovaText(label, size: 8, color: Color(white: 0.5))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(color).frame(width: 56 * max(0, min(1, frac)))
            }
            .frame(width: 56, height: 4)
        }
    }

    // MARK: - Command buttons (items 0–3)

    /// A 146×26 authentic command button. Enabled only when there's a wing to
    /// command; the wing's current standing order is shown in the order panel.
    private func commandButton(_ order: EscortOrder, _ rect: CGRect, _ d: DITLPlacement) -> some View {
        authButton(onGroupCommand == nil ? order.title : originalTitle(order), width: max(0, rect.width - 26), enabled: hasEscorts) {
            guard hasEscorts else { return }
            if let onGroupCommand {
                onGroupCommand(group, originalCommand(order))
            } else {
                onCommand(order)
            }
        }
        .ditlPlace(space, d, rect)
    }

    /// The original's order for a command button: Attack, Defend, Formation,
    /// Hold Position (STR# 2002 #146 / #145 / #149 / #147).
    private func originalCommand(_ order: EscortOrder) -> Int {
        switch order {
        case .aggressive: return OriginalEscortCommand.attack
        case .defensive: return OriginalEscortCommand.defend
        case .evasive: return OriginalEscortCommand.formation
        case .hold: return OriginalEscortCommand.hold
        }
    }

    private func originalTitle(_ order: EscortOrder) -> String {
        let index: Int
        switch order {
        case .aggressive: index = 146
        case .defensive: index = 145
        case .evasive: index = 149
        case .hold: index = 147
        }
        return strings?.string(at: index) ?? order.title
    }

    /// The group the original-AI orders go to, cycled All → Fighters → Medium
    /// → Warships → Freighters (STR# 2002 #144 / #140–#143).
    private var groupLabel: String {
        guard let group else { return strings?.string(at: 144) ?? "All Ships" }
        return strings?.string(at: 140 + group) ?? "Group \(group + 1)"
    }

    @ViewBuilder
    private var groupControls: some View {
        if let onGroupCommand {
            authButton(groupLabel, width: 92, enabled: hasEscorts) {
                group = group == nil ? 0 : (group! >= 3 ? nil : group! + 1)
            }
            authButton(strings?.string(at: 148) ?? "Return to Hangar", width: 112, enabled: hasEscorts) {
                if hasEscorts { onGroupCommand(group, OriginalEscortCommand.returnToHangar) }
            }
        }
    }

    // MARK: - Action strip (captured-escort economy, below the frame)

    private var actionBar: some View {
        HStack(spacing: 6) {
            if let sel = selectedEscort, sel.isFighter {
                fighterStatus(sel)
                Spacer(minLength: 6)
                fighterActions
            } else if let rec = selectedRecord {
                hailStatus(rec)
                Spacer(minLength: 6)
                hailActions(rec)
            } else if onGroupCommand != nil {
                groupControls
                Spacer(minLength: 6)
            } else {
                NovaText(hasEscorts ? "Select an escort to hail it." : "Hail an escort to command it.",
                         size: 10, color: Color(white: 0.45))
                Spacer(minLength: 6)
            }
            authButton("Done", width: 60, action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.frameW, height: Self.actionBarH)
        .background(Color(white: 0.08))
        .overlay(Rectangle().fill(novaAmber.opacity(0.22)).frame(height: 1), alignment: .top)
    }

    /// A selected fighter's status — no upkeep/upgrade/resale to show, since it
    /// isn't an independently-tracked escort.
    private func fighterStatus(_ sel: GameScene.EscortInfo) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            NovaText(sel.name, size: 11, color: novaAmber, weight: .bold)
            NovaText("Bay fighter · managed via its carrier", size: 9, color: Color(white: 0.55))
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    /// A fighter can't be individually upgraded, sold or released — those only
    /// apply to a roster-tracked (hired/captured/mission) escort — so the same
    /// verb is shown disabled rather than omitted, making the restriction
    /// visible instead of the row simply doing nothing when tapped.
    private var fighterActions: some View {
        authButton("Release", width: 46, enabled: false) {}
    }

    /// The selected escort's name and its upgrade/resale costs (resale only
    /// for a captured ship) — the detail the button verbs stay short by not
    /// repeating.
    private func hailStatus(_ sel: EscortRecord) -> some View {
        let detail: String = {
            // The original's status lines (STR# 2002 #292 / #295).
            if sel.pendingUpgradeTo != nil, let s = game?.stringList(2002)?.string(at: 292) { return s }
            if sel.pendingSale == true, let s = game?.stringList(2002)?.string(at: 295) { return s }
            guard let ship = game?.ship(sel.shipType) else {
                return sel.origin == .hired ? "Hired · \(sel.dailyFee)cr/day" : "Under command"
            }
            var parts = [sel.origin == .captured ? "Captured" : "Hired · \(sel.dailyFee)cr/day"]
            if ship.escortUpgradesTo >= 128 { parts.append("upgrade \(ship.escortUpgradeCost)cr") }
            if sel.origin == .captured { parts.append("sell \(PilotEconomy.escortSellValue(for: ship))cr") }
            return parts.joined(separator: " · ")
        }()
        return VStack(alignment: .leading, spacing: 1) {
            NovaText(sel.name, size: 11, color: novaAmber, weight: .bold)
            NovaText(detail, size: 9, color: Color(white: 0.55))
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    /// The escort window's actions (`NovaUi_RunEscortShipManagementWindow`
    /// 0x004853a0): Upgrade and Sell are exclusive toggle marks the fleet pass
    /// processes on leaving a shipyard stellar (EC-22). Upgrade is offered when
    /// the hull has an `UpgradeTo` whose availability expression passes; Sell
    /// never for a hired (or mission) escort. Release works for any escort.
    @ViewBuilder
    private func hailActions(_ sel: EscortRecord) -> some View {
        let canUpgrade = game.flatMap { g in pilot.flatMap { PilotEconomy.escortUpgradeTarget($0, recordID: sel.id, game: g) } } != nil
        if sel.pendingUpgradeTo != nil {
            authButton("Cancel Upgrade", width: 90) { onCancelUpgrade(sel.id) }
        } else if canUpgrade {
            authButton("Upgrade", width: 46) { onUpgrade(sel.id) }
        }
        if sel.pendingSale == true {
            authButton("Cancel Sale", width: 70) { onCancelSale(sel.id) }
        } else if pilot.map({ PilotEconomy.canSellEscort($0, recordID: sel.id) }) ?? (sel.origin == .captured) {
            authButton("Sell", width: 32) { onSell(sel.id) }
        }
        authButton(sel.origin == .hired ? "Release" : "Dismiss", width: 46) {
            onRelease(sel.id); selectedEntityID = nil
        }
    }

    // MARK: - Authentic button (three-slice art, plain fallback in the demo path)

    @ViewBuilder
    private func authButton(_ title: String, width: CGFloat, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        if let graphics {
            NovaButton(graphics: graphics, title: title, width: width, enabled: enabled, action: action)
        } else {
            // No game data loaded — no button art to decode (preview path only).
            Button { if enabled { action() } } label: {
                Text(title)
                    .font(.custom(NovaFontRole.button.family, size: 12))
                    .foregroundStyle(enabled ? .white : Color(white: 0.4))
                    .frame(width: 26 + width, height: 25)
                    .background(Color(white: 0.18))
                    .overlay(Rectangle().strokeBorder(Color(white: 0.3)))
            }
            .buttonStyle(.novaPlain)
            .disabled(!enabled)
        }
    }
}

#Preview("Escorts") {
    EscortsView()
        .padding(20)
        .background(Color.black)
}

/// The in-flight Escort Commands panel (`Ui_DrawTargetCategoryPanel`
/// 0x0049e430), composited over the playfield by 0x00439bb0 at
/// level / 32: a title and five rows — All plus the four EscortTypes — each
/// with its group's current order; empty groups dim, the selected row lit.
struct EscortCommandPanelView: View {
    @ObservedObject var hud: GameHUDModel
    /// Touch / controller-pointer path (no keys 1–5 / F D V C there): tap a row
    /// to pick the group, tap an order to issue it to that group.
    var onGroup: ((Int) -> Void)? = nil
    var onOrder: ((Int) -> Void)? = nil

    var body: some View {
        if let panel = hud.escortPanel {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .novaFont(.hud, weight: .bold, size: 11)
                    .foregroundStyle(.white)
                ForEach(Array(panel.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 8) {
                        Text("\(index + 1)  \(row.label)")
                        Spacer(minLength: 12)
                        Text(row.order)
                    }
                    .novaFont(.hud, weight: row.selected ? .bold : .regular, size: 10)
                    .foregroundStyle(row.enabled ? (row.selected ? Color.green : Color.white) : Color(white: 0.25))
                    .contentShape(Rectangle())
                    .onTapGesture { if row.enabled { onGroup?(index) } }
                }
                if onOrder != nil {
                    HStack(spacing: 4) {
                        ForEach([("Attack", OriginalEscortCommand.attack), ("Defend", OriginalEscortCommand.defend),
                                 ("Form", OriginalEscortCommand.formation), ("Hold", OriginalEscortCommand.hold),
                                 ("Hangar", OriginalEscortCommand.returnToHangar)], id: \.1) { item in
                            Button(item.0) { onOrder?(item.1) }
                                .buttonStyle(.bordered)
                                .novaFont(.hud, weight: .regular, size: 9)
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .padding(6)
            .frame(width: 200, alignment: .leading)
            .background(Color.black.opacity(0.85))
            .border(Color(white: 0.4), width: 1)
            .opacity(Double(panel.level) / 32)
            .allowsHitTesting(onOrder != nil)
        }
    }
}
