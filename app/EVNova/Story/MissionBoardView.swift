import SwiftUI
import EVNovaKit
import EVNovaStory

/// A list of real `mïsn` offers at one `MissionOfferLocation`, shared by the
/// Mission BBS and Bar screens (`AvailLoc` 0 and 1 respectively — the two
/// locations the Bible/repo docs call out as the common case). Backed by the
/// actual `StoryEngine` (control-bit gated availability, random-appearance
/// roll, reward text) rather than a placeholder; accepting/declining writes
/// the mutated `PlayerState` straight back to the live pilot.
struct MissionBoardView: View {
    let game: NovaGame
    @ObservedObject var pilot: PilotStore
    let spob: SpobRes
    let location: MissionOfferLocation
    var width: CGFloat = 300

    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if offered.isEmpty {
                NovaText("No missions available at this time.", size: 11, color: Color(white: 0.6),
                          width: width, align: .leading)
            } else {
                ForEach(offered, id: \.id) { mission in
                    Button { engine?.present(mission) } label: {
                        HStack(spacing: 6) {
                            NovaText(mission.name, size: 11, width: width - 65, align: .leading)
                            Spacer(minLength: 0)
                            NovaText(creditsLabel(mission.pay), size: 11,
                                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 60, align: .trailing)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear(perform: buildEngine)
        .sheet(isPresented: Binding(get: { services.pendingOffer != nil },
                                    set: { if !$0 { services.pendingOffer = nil } })) {
            if let offer = services.pendingOffer {
                MissionOfferSheet(offer: offer, onAccept: { accept(offer) }, onDecline: { decline(offer) })
            }
        }
    }

    private func buildEngine() {
        let e = StoryEngine(game: game, player: pilot.state, services: services)
        engine = e
        offered = e.missionsOffered(at: location, spob: spob.id)
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        offered = engine.missionsOffered(at: location, spob: spob.id)
    }

    private func decline(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        services.pendingOffer = nil
    }

    private func creditsLabel(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}

/// The mission briefing + accept/decline choice. Not yet drawn from the
/// authentic "Mission offer" frame PICTs (8521-8523, a 3-slice resizable
/// dialog) — a plain sheet until that slicing is worth the effort relative
/// to the fixed-frame dialogs elsewhere in the spaceport.
private struct MissionOfferSheet: View {
    let offer: MissionOffer
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(offer.mission.name).novaFont(.heading)
            ScrollView { Text(offer.briefingText).novaFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if offer.canRefuse {
                    Button(offer.refuseButton, action: onDecline)
                }
                Spacer()
                Button(offer.acceptButton, action: onAccept).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380, height: 280)
        .novaResponsive()
    }
}
