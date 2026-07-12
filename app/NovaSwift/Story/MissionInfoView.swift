import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// EV Nova's **Mission Info** dialog — the in-flight list of every mission the
/// player is currently on, with the selected mission's briefing and where to go
/// on the right, an "Abort Mission" button (disabled when the mission forbids
/// it), and Done. Rebuilt from the real dialog: backdrop PICT #8517 "Mission
/// Info" (471×155, `Nova Files/Nova Graphics 3.rez`), item rects from DITL
/// #1012 (`novaswift-extract ditl "data/EV Nova/Nova.rez" 1012`) — see `Item`.
///
/// The list, description and destination all come from `StoryEngine`'s
/// `activeMissionSummaries()`, so the destination shown here is the exact same
/// concrete stellar the galaxy-map arrow points at and the briefing named.
struct MissionInfoView: View {
    let graphics: SpaceportGraphics
    let game: NovaGame
    @ObservedObject var pilot: PilotStore
    var onClose: () -> Void

    @State private var summaries: [StoryEngine.MissionSummary] = []
    @State private var selectedID: Int?

    private static let frameID = 8517

    /// DITL #1012 rects (left, top, w, h), top-left anchored in the 471×155
    /// frame. Item [5] sits below the frame (an unused off-screen control) and
    /// isn't drawn; the two header labels ([2],[6]) are baked into the PICT art,
    /// so only the interactive items are placed here.
    private enum Item {
        static let list    = (left: 9,   top: 24,  w: 195, h: 84)  // idx1 — mission list
        static let desc    = (left: 218, top: 26,  w: 242, h: 91)  // idx3 — briefing/where-to-go
        static let abort   = (left: 57,  top: 125, w: 99,  h: 25)  // idx4 — "Abort Mission"
        static let done    = (left: 290, top: 125, w: 99,  h: 25)  // idx0 — "Done"
    }

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let missionOrange = Color(red: 1.0, green: 0.52, blue: 0.0)

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { onClose() }
            if let frame = graphics.pict(Self.frameID) {
                chrome(frame: frame)
            }
        }
        .novaResponsive()
        .onAppear(perform: rebuild)
    }

    private var selected: StoryEngine.MissionSummary? {
        summaries.first { $0.id == selectedID }
    }

    private func rebuild() {
        let engine = StoryEngine(game: game, player: pilot.state)
        summaries = engine.activeMissionSummaries()
        if selectedID == nil || !summaries.contains(where: { $0.id == selectedID }) {
            selectedID = summaries.first?.id
        }
    }

    private func abortSelected() {
        guard let m = selected, m.canAbort else { return }
        let engine = StoryEngine(game: game, player: pilot.state)
        engine.abortMission(m.id)
        pilot.state = engine.player
        pilot.save()
        rebuild()
    }

    // MARK: Chrome

    private func cx(_ i: (left: Int, top: Int, w: Int, h: Int), _ nw: CGFloat) -> CGFloat { CGFloat(i.left) - nw / 2 }
    private func cy(_ i: (left: Int, top: Int, w: Int, h: Int), _ nh: CGFloat) -> CGFloat { CGFloat(i.top) - nh / 2 }

    private func chrome(frame: CGImage) -> some View {
        let nw = CGFloat(frame.width), nh = CGFloat(frame.height)
        let space = NovaSpace(width: nw, height: nh)
        return GeometryReader { geo in
            let scale = novaFrameScale(frame: CGSize(width: nw, height: nh), viewport: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1).interpolation(.high).resizable()
                    .frame(width: nw, height: nh)

                missionList
                    .frame(width: CGFloat(Item.list.w), height: CGFloat(Item.list.h), alignment: .top)
                    .clipped()
                    .novaPlace(space, cx(Item.list, nw), cy(Item.list, nh))

                description
                    .frame(width: CGFloat(Item.desc.w), height: CGFloat(Item.desc.h), alignment: .topLeading)
                    .clipped()
                    .novaPlace(space, cx(Item.desc, nw), cy(Item.desc, nh))

                NovaButton(graphics: graphics, title: "Abort Mission",
                           width: CGFloat(Item.abort.w - 26),
                           enabled: selected?.canAbort ?? false,
                           action: abortSelected)
                    .novaPlace(space, cx(Item.abort, nw), cy(Item.abort, nh))

                NovaButton(graphics: graphics, title: "Done",
                           width: CGFloat(Item.done.w - 26), action: onClose)
                    .novaPlace(space, cx(Item.done, nw), cy(Item.done, nh))
            }
            .frame(width: nw, height: nh, alignment: .topLeading)
            .scaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder
    private var missionList: some View {
        if summaries.isEmpty {
            VStack {
                Spacer()
                NovaText("No active missions.", size: 11, color: Color(white: 0.6),
                         width: CGFloat(Item.list.w), align: .center)
                Spacer()
            }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summaries) { m in
                        Button { selectedID = m.id } label: {
                            NovaText(m.name, size: 11,
                                     color: m.id == selectedID ? .white : Color(white: 0.78),
                                     width: CGFloat(Item.list.w) - 10, align: .leading)
                                .padding(.vertical, 3).padding(.horizontal, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(m.id == selectedID ? amber.opacity(0.28) : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var description: some View {
        if let m = selected {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    NovaText(m.name, size: 11, color: amber,
                             width: CGFloat(Item.desc.w), align: .leading, weight: .bold)

                    // The current objective, with live progress folded in (ship
                    // kills counted, the active travel/return leg named).
                    if !m.objective.isEmpty {
                        NovaText("Objective: \(m.objective)", size: 10, color: amber,
                                 width: CGFloat(Item.desc.w), align: .leading)
                    }

                    // Where to go — the concrete destination stellar + system,
                    // the same one the galaxy-map arrow points at.
                    if !m.destinationSpob.isEmpty {
                        NovaText("Destination: \(m.destinationSpob)\(m.destinationSystem.isEmpty ? "" : " (\(m.destinationSystem))")",
                                 size: 10, color: missionOrange, width: CGFloat(Item.desc.w), align: .leading)
                    }
                    if let deadline = m.deadline {
                        NovaText("Deadline: \(deadline.description)", size: 10,
                                 color: Color(white: 0.62), width: CGFloat(Item.desc.w), align: .leading)
                    }
                    if !m.payload.isEmpty {
                        NovaText(m.payload, size: 10, color: Color(white: 0.82),
                                 width: CGFloat(Item.desc.w), align: .leading)
                    }
                }
            }
        } else {
            NovaText("You are not currently on any missions.", size: 10,
                     color: Color(white: 0.62), width: CGFloat(Item.desc.w), align: .leading)
        }
    }
}
