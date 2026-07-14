import XCTest
@testable import NovaSwiftNet

/// Trade handshake: signal delivery over the session, and codec fidelity for the
/// offer's Int-keyed item bundles (which JSON can't key as an object — Swift
/// encodes them as arrays, so round-tripping is worth pinning).
final class TradeTests: XCTestCase {

    private func makeSessions(_ ids: [String]) -> [NetSession] {
        let net = LoopbackNetwork()
        var transports: [LoopbackTransport] = []
        var sessions: [NetSession] = []
        for id in ids {
            let t = LoopbackTransport(peerID: id, network: net)
            sessions.append(NetSession(transport: t))
            transports.append(t)
        }
        for t in transports { t.connect() }
        return sessions
    }

    func testTradeOfferRoundTrips() throws {
        let offer = TradeOffer(credits: 5000, cargo: [128: 3, 130: 7], outfits: [200: 1])
        let data = try NetCodec.encode(.trade(.offer(offer)))
        let decoded = try NetCodec.decode(data)
        guard case let .trade(.offer(back)) = decoded else { return XCTFail("wrong case") }
        XCTAssertEqual(back, offer)
        XCTAssertEqual(back.cargo[128], 3)
        XCTAssertEqual(back.cargo[130], 7)
        XCTAssertEqual(back.outfits[200], 1)
        XCTAssertEqual(back.credits, 5000)
    }

    func testTradeSignalsReachTheTargetedPeer() {
        let s = makeSessions(["a", "b"])
        var received: [(TradeSignal, PeerID)] = []
        s[1].onTrade = { sig, peer in received.append((sig, peer)) }

        s[0].sendTrade(.invite(fromName: "Ari"), to: "b")
        s[0].sendTrade(.offer(TradeOffer(credits: 100)), to: "b")
        s[0].sendTrade(.accept(true), to: "b")
        s[0].sendTrade(.cancel, to: "b")

        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received.map(\.1), ["a", "a", "a", "a"])
        guard case .invite(let name) = received[0].0 else { return XCTFail() }
        XCTAssertEqual(name, "Ari")
        guard case .accept(let ok) = received[2].0 else { return XCTFail() }
        XCTAssertTrue(ok)
    }

    func testEmptyOfferIsEmpty() {
        XCTAssertTrue(TradeOffer().isEmpty)
        XCTAssertFalse(TradeOffer(credits: 1).isEmpty)
        XCTAssertFalse(TradeOffer(cargo: [1: 1]).isEmpty)
    }
}
