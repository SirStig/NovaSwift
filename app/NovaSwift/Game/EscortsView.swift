import SwiftUI
import NovaSwiftEngine

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
    var escorts: [GameScene.EscortInfo] = []
    var currentOrder: EscortOrder? = nil
    var onCommand: (EscortOrder) -> Void = { _ in }
    var onClose: () -> Void = {}

    // PICT #8513's own decoded size — the coordinate origin every item below
    // is placed relative to (frame-centre, top-left anchored; see NovaMenu.swift).
    private static let frameW: CGFloat = 424
    private static let frameH: CGFloat = 259
    private let space = NovaSpace(width: frameW, height: frameH)

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

            // Item 8: "Ship Identifier" statText label.
            NovaText("Ship Identifier", size: 10, color: Color(white: 0.4))
                .novaPlace(space, -174, 185.5)

            // Item 4: the identifier field — reused as a Done button so the
            // window can be dismissed on any platform.
            doneButton.novaPlace(space, -207, 174.5)
        }
        .frame(width: Self.totalW, height: Self.totalH, alignment: .topLeading)
        .background(Color(white: 0.07))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(novaAmber.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func escortRow(_ e: GameScene.EscortInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NovaText(e.name, size: 11, color: .white, width: 176, align: .leading, weight: .semibold)
            HStack(spacing: 6) {
                bar("SH", e.shieldFraction, Color(red: 0.4, green: 0.7, blue: 1))
                bar("AR", e.armorFraction, Color(red: 1, green: 0.72, blue: 0.3))
            }
        }
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

    /// Stand-in for PICT #8513 (see type doc): a dark plate the same 424×259
    /// footprint, so every item lands where the real frame would put it.
    private var art: some View {
        Rectangle().fill(Color(white: 0.1))
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

    private var doneButton: some View {
        Button(action: onClose) {
            Text("Done")
                .novaFont(.button)
                .foregroundStyle(.white)
                .frame(width: 200, height: 25)
                .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 3))
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
