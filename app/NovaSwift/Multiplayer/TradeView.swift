import SwiftUI
import NovaSwiftKit
import NovaSwiftNet

/// The trade / item hand-off window: a two-sided deal between the local pilot and
/// a session partner. Your side (left, amber "GIVE") is editable from what you're
/// carrying — credits, cargo, outfits — and streams live to the partner; their
/// side (right, green "RECEIVE") mirrors what they're offering. When both tap
/// Accept, the swap applies to each save. Responsive: side-by-side on wide
/// screens, stacked on a phone.
struct TradeView: View {
    @EnvironmentObject private var model: AppModel

    @State private var offer = TradeOffer()

    private var session: MultiplayerSession { model.session }
    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var game: NovaGame? { model.data.game }

    var body: some View {
        if let trade = session.trade {
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea()
                    .onTapGesture { }   // swallow taps behind the card

                VStack(spacing: 0) {
                    header(trade)
                    Divider().overlay(.white.opacity(0.12))
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 0) {   // wide: side by side
                            mySide.frame(maxWidth: .infinity)
                            swapDivider
                            theirSide(trade).frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 0) {                    // narrow: stacked
                            mySide
                            Divider().overlay(.white.opacity(0.12))
                            theirSide(trade)
                        }
                    }
                    Divider().overlay(.white.opacity(0.12))
                    acceptBar(trade)
                }
                .frame(maxWidth: 720, maxHeight: 620)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.05, green: 0.06, blue: 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
                .shadow(radius: 30)
                .padding(20)
            }
            .onAppear { offer = trade.myOffer }
            .onChange(of: offer) { _, new in session.updateMyOffer(new) }
        }
    }

    // MARK: Header

    private func header(_ trade: MultiplayerSession.TradeState) -> some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.title2).foregroundStyle(amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Trade").novaFont(.heading).foregroundStyle(.white)
                Text(trade.partnerJoined ? "with \(trade.partnerName)"
                     : "Waiting for \(trade.partnerName)…")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { session.cancelTrade() } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.bold))
                    .padding(8).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.novaPlain)
        }
        .padding(16)
    }

    // MARK: My side (editable)

    private var mySide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                columnTitle("YOU GIVE", color: amber, icon: "arrow.up.circle.fill")

                // Credits
                let held = model.pilot.state.credits
                offerCard(title: "Credits", trailing: "\(held.formatted()) cr") {
                    HStack(spacing: 10) {
                        stepperButton("minus") { offer.credits = max(0, offer.credits - creditStep(held)) }
                        Text("\(offer.credits.formatted()) cr")
                            .novaFont(.button, weight: .medium).foregroundStyle(amber)
                            .frame(maxWidth: .infinity)
                        stepperButton("plus") { offer.credits = min(held, offer.credits + creditStep(held)) }
                    }
                }

                // Cargo
                let cargo = model.pilot.state.cargo.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                if !cargo.isEmpty {
                    sectionLabel("Cargo")
                    ForEach(cargo, id: \.key) { id, tons in
                        itemStepper(name: cargoName(id), held: tons, unit: "t",
                                    value: binding(\.cargo, id))
                    }
                }

                // Outfits
                let outfits = model.pilot.state.outfits.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                if !outfits.isEmpty {
                    sectionLabel("Outfits")
                    ForEach(outfits, id: \.key) { id, count in
                        itemStepper(name: outfitName(id), held: count, unit: "",
                                    value: binding(\.outfits, id))
                    }
                }

                if cargo.isEmpty && outfits.isEmpty {
                    Text("You have no cargo or outfits to trade.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    // MARK: Their side (read-only)

    private func theirSide(_ trade: MultiplayerSession.TradeState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                columnTitle("YOU RECEIVE", color: .green, icon: "arrow.down.circle.fill")
                let o = trade.theirOffer
                if o.isEmpty {
                    Text(trade.partnerJoined ? "\(trade.partnerName) hasn't offered anything yet."
                         : "Waiting for \(trade.partnerName) to join…")
                        .novaFont(.caption).foregroundStyle(.secondary)
                } else {
                    if o.credits > 0 { receiveRow("Credits", "\(o.credits.formatted()) cr") }
                    if !o.cargo.isEmpty {
                        sectionLabel("Cargo")
                        ForEach(o.cargo.filter { $0.value > 0 }.sorted { $0.key < $1.key }, id: \.key) { id, t in
                            receiveRow(cargoName(id), "\(t) t")
                        }
                    }
                    if !o.outfits.isEmpty {
                        sectionLabel("Outfits")
                        ForEach(o.outfits.filter { $0.value > 0 }.sorted { $0.key < $1.key }, id: \.key) { id, n in
                            receiveRow(outfitName(id), "×\(n)")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Accept bar

    private func acceptBar(_ trade: MultiplayerSession.TradeState) -> some View {
        HStack(spacing: 14) {
            statusChip(name: "You", accepted: trade.myAccepted)
            statusChip(name: trade.partnerName, accepted: trade.theirAccepted)
            Spacer()
            Button {
                session.setTradeAccepted(!trade.myAccepted)
            } label: {
                Text(trade.myAccepted ? "Accepted — Waiting" : "Accept Trade")
                    .novaFont(.button, weight: .medium)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(trade.myAccepted ? Color.gray.opacity(0.3) : Color.green))
                    .foregroundStyle(trade.myAccepted ? .white : .black)
            }
            .buttonStyle(.novaPlain)
            .disabled(!trade.partnerJoined)
        }
        .padding(16)
    }

    // MARK: Small pieces

    private func columnTitle(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).novaFont(.button, weight: .medium).foregroundStyle(color)
        }
    }

    private var swapDivider: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            Image(systemName: "arrow.left.arrow.right").font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(6).background(Color(red: 0.05, green: 0.06, blue: 0.1), in: Circle())
        }
        .frame(width: 24)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).novaFont(.caption, weight: .bold).foregroundStyle(.white.opacity(0.5))
    }

    private func offerCard<Content: View>(title: String, trailing: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).novaFont(.button, weight: .medium).foregroundStyle(.white)
                Spacer()
                Text("You have \(trailing)").novaFont(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }

    private func itemStepper(name: String, held: Int, unit: String, value: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).novaFont(.caption, weight: .medium).foregroundStyle(.white).lineLimit(1)
                Text("Have \(held)\(unit.isEmpty ? "" : " \(unit)")").novaFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stepperButton("minus") { value.wrappedValue = max(0, value.wrappedValue - 1) }
            Text("\(value.wrappedValue)").novaFont(.button, weight: .medium)
                .foregroundStyle(value.wrappedValue > 0 ? amber : .white.opacity(0.4))
                .frame(minWidth: 24)
            stepperButton("plus") { value.wrappedValue = min(held, value.wrappedValue + 1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    private func receiveRow(_ name: String, _ amount: String) -> some View {
        HStack {
            Text(name).novaFont(.caption, weight: .medium).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Text(amount).novaFont(.button, weight: .medium).foregroundStyle(.green)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.green.opacity(0.08)))
    }

    private func stepperButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.bold)).frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.1))).foregroundStyle(.white)
        }
        .buttonStyle(.novaPlain)
    }

    private func statusChip(name: String, accepted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(accepted ? .green : .white.opacity(0.4))
            Text(name).novaFont(.caption, weight: .medium).foregroundStyle(.white).lineLimit(1)
        }
    }

    // MARK: Helpers

    /// Binding into `offer.cargo`/`offer.outfits` for a given id (0 when absent).
    private func binding(_ keyPath: WritableKeyPath<TradeOffer, [Int: Int]>, _ id: Int) -> Binding<Int> {
        Binding(
            get: { offer[keyPath: keyPath][id] ?? 0 },
            set: { newValue in
                if newValue > 0 { offer[keyPath: keyPath][id] = newValue }
                else { offer[keyPath: keyPath][id] = nil }
            })
    }

    /// A sensible credit increment based on how much you hold.
    private func creditStep(_ held: Int) -> Int {
        switch held {
        case ..<1_000: return 100
        case ..<100_000: return 1_000
        default: return 10_000
        }
    }

    private func cargoName(_ id: Int) -> String {
        if let c = Commodity(rawValue: id) { return game?.commodityName(c) ?? "Cargo" }
        return "Cargo #\(id)"
    }
    private func outfitName(_ id: Int) -> String { game?.outfit(id)?.name ?? "Outfit #\(id)" }
}

/// The incoming trade-invite prompt shown in flight when another player asks to
/// trade. Accept opens the trade window; Decline sends a polite no.
struct TradeInvitePromptView: View {
    @EnvironmentObject private var model: AppModel
    let invite: MultiplayerSession.TradeInvite
    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 34)).foregroundStyle(amber)
            Text("Trade Request").novaFont(.heading).foregroundStyle(.white)
            Text("\(invite.name) wants to trade with you.")
                .novaFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { model.session.declineTradeInvite() } label: {
                    Text("Decline").novaFont(.button, weight: .medium)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.novaPlain)
                Button { model.session.acceptTradeInvite() } label: {
                    Text("Trade").novaFont(.button, weight: .medium)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(amber))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.novaPlain)
            }
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.05, green: 0.06, blue: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(amber.opacity(0.3)))
        .shadow(radius: 20)
    }
}
