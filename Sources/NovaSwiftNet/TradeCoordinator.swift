import Foundation

/// Pure rules for hand-offs between two players: validation and application of a
/// `TradeOffer` against plain holdings (credits, cargo tons by id, outfit counts by id).
/// UI- and save-agnostic so both frontends (and tests) share one definition.
public enum TradeRules {
    /// Drop non-positive entries and negative credits. Offers from the wire go through
    /// this so a hostile peer can't "give" a negative amount to take items.
    public static func sanitized(_ o: TradeOffer) -> TradeOffer {
        TradeOffer(credits: max(0, o.credits),
                   cargo: o.cargo.filter { $0.value > 0 },
                   outfits: o.outfits.filter { $0.value > 0 })
    }

    /// Whether the holdings can cover what the offer gives away.
    public static func covers(_ o: TradeOffer, credits: Int, cargo: [Int: Int], outfits: [Int: Int]) -> Bool {
        if o.credits > credits { return false }
        for (id, t) in o.cargo where (cargo[id] ?? 0) < t { return false }
        for (id, n) in o.outfits where (outfits[id] ?? 0) < n { return false }
        return true
    }

    /// Remove `give` from the holdings and add `receive` (the same arithmetic the Apple
    /// app's `onTradeCommitted` does). Both offers are sanitized first.
    public static func apply(give: TradeOffer, receive: TradeOffer,
                             credits: inout Int, cargo: inout [Int: Int], outfits: inout [Int: Int]) {
        let g = sanitized(give), r = sanitized(receive)
        credits = max(0, credits - g.credits) + r.credits
        for (id, t) in g.cargo { let left = (cargo[id] ?? 0) - t; cargo[id] = left > 0 ? left : nil }
        for (id, t) in r.cargo { cargo[id, default: 0] += t }
        for (id, n) in g.outfits { let left = (outfits[id] ?? 0) - n; outfits[id] = left > 0 ? left : nil }
        for (id, n) in r.outfits { outfits[id, default: 0] += n }
    }
}

/// The two-sided trade state machine (invite -> offers -> dual accept -> commit) over
/// `TradeSignal`s. Frontend-neutral: the host app supplies `send`, the allow rule, an
/// accept/commit validity check and a commit callback. Mirrors the Apple
/// `MultiplayerSession` trade flow; any change to either offer resets both acceptances.
public final class TradeCoordinator {
    public struct Live: Equatable {
        public var partnerID: String
        public var partnerName: String
        public var partnerJoined: Bool
        public var myOffer = TradeOffer()
        public var theirOffer = TradeOffer()
        public var myAccepted = false
        public var theirAccepted = false
    }
    public struct Invite: Equatable { public var id: String; public var name: String }

    public enum Event: Equatable {
        case invited(Invite)
        case opened(partnerID: String, partnerName: String)
        case changed
        case declined(String)
        case cancelled(String)
        case committed(give: TradeOffer, receive: TradeOffer)
        case failed(String)
    }

    public private(set) var live: Live?
    public private(set) var incoming: Invite?

    public var send: (TradeSignal, String) -> Void = { _, _ in }
    public var allowTrade: () -> Bool = { true }
    public var localName: () -> String = { "Captain" }
    public var partnerName: (String) -> String? = { _ in nil }
    /// Is this peer in the session? (invites to absent peers are refused)
    public var isPresent: (String) -> Bool = { _ in true }
    /// May `give` be offered (does the player hold it)? Return a reason to refuse.
    public var offerCheck: (TradeOffer) -> String? = { _ in nil }
    /// May we accept / commit this swap (holdings still cover `give`, room for `receive`)? Reason to refuse.
    public var swapCheck: (_ give: TradeOffer, _ receive: TradeOffer) -> String? = { _, _ in nil }
    /// Apply the committed swap to the local save.
    public var commit: (_ give: TradeOffer, _ receive: TradeOffer) -> Void = { _, _ in }
    public var onEvent: (Event) -> Void = { _ in }

    public init() {}

    public func canTrade(with peer: String) -> Bool { allowTrade() && live == nil && isPresent(peer) }

    /// Invite `peer`; opens our (waiting) window. Returns a refusal reason, nil on success.
    @discardableResult
    public func invite(_ peer: String) -> String? {
        guard allowTrade() else { return "Trading is switched off in this game." }
        guard live == nil else { return "You are already in a trade." }
        guard isPresent(peer) else { return "That player isn't in the game." }
        let name = partnerName(peer) ?? "Player"
        live = Live(partnerID: peer, partnerName: name, partnerJoined: false)
        onEvent(.opened(partnerID: peer, partnerName: name))
        send(.invite(fromName: localName()), peer)
        return nil
    }

    /// Answer the pending invite.
    public func respond(accept: Bool) {
        guard let inv = incoming else { return }
        incoming = nil
        guard accept, live == nil, allowTrade() else { send(.decline, inv.id); onEvent(.changed); return }
        live = Live(partnerID: inv.id, partnerName: inv.name, partnerJoined: true)
        send(.offer(TradeOffer()), inv.id)   // ack + initial (empty) offer
        onEvent(.opened(partnerID: inv.id, partnerName: inv.name))
    }

    /// Replace our offer. Returns a refusal reason (we don't hold it), nil on success.
    @discardableResult
    public func setOffer(_ offer: TradeOffer) -> String? {
        guard var t = live else { return "No trade is open." }
        let o = TradeRules.sanitized(offer)
        if let why = offerCheck(o) { return why }
        t.myOffer = o
        t.myAccepted = false
        t.theirAccepted = false
        live = t
        send(.offer(o), t.partnerID)
        onEvent(.changed)
        return nil
    }

    /// Toggle our acceptance; both accepted commits. Returns a refusal reason, nil on success.
    @discardableResult
    public func setAccepted(_ accepted: Bool) -> String? {
        guard var t = live else { return "No trade is open." }
        if accepted, !t.partnerJoined { return "Waiting for the other player to join the trade." }
        if accepted, let why = swapCheck(t.myOffer, t.theirOffer) { return why }
        t.myAccepted = accepted
        live = t
        send(.accept(accepted), t.partnerID)
        onEvent(.changed)
        commitIfReady()
        return nil
    }

    public func cancel() {
        if let t = live { send(.cancel, t.partnerID) }
        if let inv = incoming { send(.decline, inv.id) }
        live = nil
        incoming = nil
        onEvent(.changed)
    }

    /// Feed `NetSession.onTrade`.
    public func handle(_ signal: TradeSignal, from peer: String) {
        switch signal {
        case .invite(let name):
            if allowTrade(), live == nil, incoming == nil {
                let inv = Invite(id: peer, name: name)
                incoming = inv
                onEvent(.invited(inv))
            } else {
                send(.decline, peer)
            }
        case .decline:
            if live?.partnerID == peer { live = nil; onEvent(.declined(peer)) }
        case .offer(let o):
            guard var t = live, t.partnerID == peer else { return }
            t.theirOffer = TradeRules.sanitized(o)
            t.partnerJoined = true
            t.myAccepted = false
            t.theirAccepted = false
            live = t
            onEvent(.changed)
        case .accept(let a):
            guard var t = live, t.partnerID == peer else { return }
            t.theirAccepted = a
            live = t
            onEvent(.changed)
            commitIfReady()
        case .cancel:
            var hit = false
            if live?.partnerID == peer { live = nil; hit = true }
            if incoming?.id == peer { incoming = nil; hit = true }
            if hit { onEvent(.cancelled(peer)) }
        }
    }

    /// The session lost `peer`: drop their trade / invite.
    public func peerLeft(_ peer: String) {
        var hit = false
        if live?.partnerID == peer { live = nil; hit = true }
        if incoming?.id == peer { incoming = nil; hit = true }
        if hit { onEvent(.cancelled(peer)) }
    }

    /// Close everything without telling anyone (session ended).
    public func reset() { live = nil; incoming = nil }

    private func commitIfReady() {
        guard let t = live, t.myAccepted, t.theirAccepted else { return }
        // Re-check against the save as it is now: it may have changed since we accepted.
        if let why = swapCheck(t.myOffer, t.theirOffer) {
            send(.cancel, t.partnerID)
            live = nil
            onEvent(.failed(why))
            return
        }
        commit(t.myOffer, t.theirOffer)
        live = nil
        onEvent(.committed(give: t.myOffer, receive: t.theirOffer))
    }
}
