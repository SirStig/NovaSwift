import SwiftUI
import NovaSwiftEngine
import NovaSwiftStory
import NovaSwiftKit

/// The in-flight **Escorts** command window — an authentic-geometry recreation
/// of DLOG/DITL #1022 "Escorts" (`novaswift-extract dlog/ditl "data/EV Nova/
/// Nova.rez" 1022` → bounds 424×259, 12 `userItem`/`statText` items whose rects
/// ARE the pixel layout; frame art PICT #8513 "Escort communications"). The four
/// 146×26 buttons (items 0–3) issue standing orders to the wing; the big 200×200
/// panel (item 10) lists the ships under your command.
///
/// Now wired to the live escort roster (`GameScene.escortRoster()` /
/// `commandEscorts`): the buttons command every escort, the current order is
/// highlighted, and the list shows each escort's name and condition. With no
/// escorts it shows the honest empty state, buttons disabled — matching the real
/// window when your wing is empty.
///
/// It still degrades to plain chrome (Geneva text + grey pills) rather than the
/// three-slice PICT art, since its call sites aren't wired with the
/// `SpaceportGraphics` environment — the same documented no-graphics branch
/// `HailDialogView` uses — but at the exact same `NovaSpace`/`.novaPlace`
/// coordinates as every authentic screen.
struct EscortsView: View {
    /// The session's interface art, for the real frame PICT #8513 and three-slice
    /// buttons. Nil in the no-data demo path → falls back to plain chrome.
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
    /// Release / dismiss the escort with this `EscortRecord.id` — EV Nova's
    /// "Release from Servitude" hail action.
    var onRelease: (Int) -> Void = { _ in }
    /// Upgrade the captured escort with this record id to its hull's `UpgradeTo`.
    var onUpgrade: (Int) -> Void = { _ in }
    /// Sell the captured escort with this record id for its `EscSellValue`.
    var onSell: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var selectedRecordID: Int? = nil

    // PICT #8513's own decoded size — the coordinate origin every item below
    // is placed relative to (frame-centre, top-left anchored; see NovaMenu.swift).
    private static let framePICT = 8513
    private static let frameW: CGFloat = 424
    private static let frameH: CGFloat = 259
    private let space = NovaSpace(width: frameW, height: frameH)

    /// The persistent record backing a live escort row (nil for an untracked
    /// wing member, e.g. a debug-spawned escort).
    private func record(for e: GameScene.EscortInfo) -> EscortRecord? {
        guard let rid = e.recordID else { return nil }
        return records.first { $0.id == rid }
    }
    /// The currently selected escort's record, if the selection is still present.
    private var selectedRecord: EscortRecord? {
        guard let rid = selectedRecordID else { return nil }
        return records.first { $0.id == rid }
    }

    // Full footprint including the plain lower strip for items 4/8.
    private static let totalW: CGFloat = 424
    private static let totalH: CGFloat = 340

    private var hasEscorts: Bool { !escorts.isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            art

            // Item 9: (14,9)-(206,67) 192×58 — wing summary.
            sidePanel(width: 192, height: 58) {
                VStack(spacing: 3) {
                    NovaText(hasEscorts ? "Escort Wing" : "No escorts",
                             size: 12, color: hasEscorts ? .white : Color(white: 0.5), weight: .bold)
                    NovaText(hasEscorts ? "\(escorts.count) ship\(escorts.count == 1 ? "" : "s") under command"
                                        : "Capture or hire ships to command",
                             size: 10, color: Color(white: 0.55), width: 180, align: .center)
                }
            }
            .novaPlace(space, -198, -120.5)

            // Item 11: (14,79)-(206,131) 192×52 — current standing order.
            sidePanel(width: 192, height: 52) {
                NovaText(hasEscorts ? "Order: \(currentOrder?.title ?? "Mixed")" : "—",
                         size: 11, color: hasEscorts ? novaAmber : Color(white: 0.4))
            }
            .novaPlace(space, -198, -50.5)

            // Item 10: (217,30)-(417,230) 200×200 — the roster list / empty state.
            sidePanel(width: 200, height: 200, amber: true) {
                if hasEscorts {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(escorts) { escortRow($0) }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 22)).foregroundStyle(Color(white: 0.45))
                        NovaText("No escorts hired.", size: 12, color: Color(white: 0.6),
                                 width: 160, align: .center)
                    }
                }
            }
            .novaPlace(space, 5, -99.5)

            // Items 2,3,1,0 top-to-bottom — the four escort-command buttons.
            commandButton(.aggressive).novaPlace(space, -183, 11.5)
            commandButton(.defensive).novaPlace(space, -183, 39.5)
            commandButton(.evasive).novaPlace(space, -183, 67.5)
            commandButton(.hold).novaPlace(space, -183, 95.5)

        }
        .overlay(alignment: .bottom) { bottomBar.padding(.bottom, 8).padding(.horizontal, 10) }
        .frame(width: Self.totalW, height: Self.totalH, alignment: .topLeading)
        .background(Color(white: 0.07))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(novaAmber.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func escortRow(_ e: GameScene.EscortInfo) -> some View {
        let rec = record(for: e)
        let selected = rec != nil && rec?.id == selectedRecordID
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                NovaText(e.name, size: 11, color: .white, width: 120, align: .leading, weight: .semibold)
                Spacer(minLength: 0)
                if let rec { originBadge(rec) }
            }
            HStack(spacing: 6) {
                bar("SH", e.shieldFraction, Color(red: 0.4, green: 0.7, blue: 1))
                bar("AR", e.armorFraction, Color(red: 1, green: 0.72, blue: 0.3))
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? novaAmber.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(novaAmber.opacity(selected ? 0.5 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // "Hail" the escort — select it to reveal its lifecycle action. Only
            // roster-tracked escorts (with a record) can be hailed/released.
            guard let rec else { return }
            selectedRecordID = (selectedRecordID == rec.id) ? nil : rec.id
        }
    }

    /// A small tag showing how the escort was acquired and, for a hired one, its
    /// daily upkeep — the money the player is on the hook for each day.
    private func originBadge(_ rec: EscortRecord) -> some View {
        let (text, color): (String, Color) = {
            switch rec.origin {
            case .hired:    return ("\(rec.dailyFee)cr/day", novaAmber)
            case .captured: return ("Captured", Color(red: 0.5, green: 0.8, blue: 1))
            case .mission:  return ("Mission", Color(white: 0.6))
            }
        }()
        return NovaText(text, size: 8, color: color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func bar(_ label: String, _ frac: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            NovaText(label, size: 8, color: Color(white: 0.5))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, frac)))
                }
            }
            .frame(width: 56, height: 4)
        }
    }

    /// The real frame PICT #8513 "Escort communications" when the session's
    /// graphics are available, else a dark plate the same 424×259 footprint so
    /// every item still lands where the real frame would put it.
    private var art: some View {
        Group {
            if let img = graphics?.pict(Self.framePICT) {
                Image(decorative: img, scale: 1).resizable().interpolation(.medium)
            } else {
                Rectangle().fill(Color(white: 0.1))
            }
        }
        .frame(width: Self.frameW, height: Self.frameH)
    }

    @ViewBuilder
    private func sidePanel<Content: View>(width: CGFloat, height: CGFloat, amber: Bool = false,
                                          @ViewBuilder content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder((amber ? novaAmber : Color.white).opacity(amber ? 0.25 : 0.12)))
    }

    /// A 146×26 command button. Enabled only when there's a wing to command;
    /// the active order is highlighted amber.
    private func commandButton(_ order: EscortOrder) -> some View {
        let active = hasEscorts && currentOrder == order
        return Button { if hasEscorts { onCommand(order) } } label: {
            Text(order.title)
                .novaFont(.button)
                .foregroundStyle(!hasEscorts ? Color(white: 0.45) : (active ? .black : .white))
                .frame(width: 146, height: 26)
                .background(active ? novaAmber : Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(white: 0.26)))
        }
        .buttonStyle(.plain)
        .disabled(!hasEscorts)
    }

    /// The lower action strip: contextual "hail" actions for the selected escort
    /// (Release, and Upgrade/Sell for a captured ship) on the left, Done on the
    /// right.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let sel = selectedRecord {
                hailActions(sel)
            } else {
                NovaText("Select an escort to hail it.", size: 10, color: Color(white: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onClose) {
                Text("Done")
                    .novaFont(.button).foregroundStyle(.white)
                    .frame(width: 90, height: 25)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.3)))
            }
            .buttonStyle(.plain)
        }
    }

    /// The hail-menu actions for the selected escort. A captured ship can also be
    /// upgraded (`UpgradeTo`, applied when the wing next respawns — i.e. at the
    /// next landing/takeoff, as in EV Nova) and sold (`EscSellValue`); a hired one
    /// can only be released.
    @ViewBuilder
    private func hailActions(_ sel: EscortRecord) -> some View {
        let ship = game?.ship(sel.shipType)
        let canUpgrade = sel.origin == .captured && (ship?.escortUpgradesTo ?? 0) > 0
        HStack(spacing: 6) {
            hailButton(sel.origin == .hired ? "Release from Servitude" : "Dismiss",
                       tint: Color(red: 0.4, green: 0.12, blue: 0.12)) {
                onRelease(sel.id); selectedRecordID = nil
            }
            if canUpgrade, let ship {
                hailButton("Upgrade \(ship.escortUpgradeCost)cr", tint: Color(white: 0.16)) {
                    onUpgrade(sel.id)
                }
            }
            if sel.origin == .captured, let ship {
                hailButton("Sell \(escortSellValue(ship))cr", tint: Color(white: 0.16)) {
                    onSell(sel.id); selectedRecordID = nil
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// EV Nova's resale value: `EscSellValue`, or 10% of Cost when unset (≤0).
    private func escortSellValue(_ ship: ShipRes) -> Int {
        ship.escortSellValue > 0 ? ship.escortSellValue : Int(Double(ship.cost) * 0.1)
    }

    private func hailButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .novaFont(.button).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 8).frame(height: 25)
                .background(tint, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.3)))
        }
        .buttonStyle(.plain)
    }
}

#Preview("Escorts") {
    EscortsView()
        .padding(20)
        .background(Color.black)
}
