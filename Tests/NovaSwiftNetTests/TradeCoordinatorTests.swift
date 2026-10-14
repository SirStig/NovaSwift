import XCTest
@testable import NovaSwiftNet

final class TradeCoordinatorTests: XCTestCase {
    /// Two coordinators wired back to back (synchronous delivery).
    private func pair() -> (TradeCoordinator, TradeCoordinator, () -> [String]) {
        let a = TradeCoordinator(), b = TradeCoordinator()
        var log: [String] = []
        a.send = { s, _ in log.append("a>\(s)"); b.handle(s, from: "a") }
        b.send = { s, _ in log.append("b>\(s)"); a.handle(s, from: "b") }
        a.localName = { "Ari" }; b.localName = { "Bo" }
        return (a, b, { log })
    }

    func testFullRoundTripCommitsOnBothSides() {
        let (a, b, _) = pair()
        var aCommit: (TradeOffer, TradeOffer)?, bCommit: (TradeOffer, TradeOffer)?
        a.commit = { aCommit = ($0, $1) }
        b.commit = { bCommit = ($0, $1) }
        XCTAssertNil(a.invite("b"))
        XCTAssertEqual(b.incoming?.name, "Ari")
        b.respond(accept: true)
        XCTAssertTrue(a.live?.partnerJoined ?? false)
        let ao = TradeOffer(credits: 500), bo = TradeOffer(cargo: [128: 3], outfits: [200: 1])
        XCTAssertNil(a.setOffer(ao))
        XCTAssertNil(b.setOffer(bo))
        XCTAssertEqual(a.live?.theirOffer, bo)
        XCTAssertNil(a.setAccepted(true))
        XCTAssertNil(b.setAccepted(true))
        XCTAssertEqual(aCommit?.0, ao); XCTAssertEqual(aCommit?.1, bo)
        XCTAssertEqual(bCommit?.0, bo); XCTAssertEqual(bCommit?.1, ao)
        XCTAssertNil(a.live); XCTAssertNil(b.live)
    }

    func testChangingAnOfferResetsAcceptances() {
        let (a, b, _) = pair()
        a.invite("b"); b.respond(accept: true)
        a.setOffer(TradeOffer(credits: 1))
        a.setAccepted(true)
        b.setOffer(TradeOffer(credits: 2))
        XCTAssertEqual(a.live?.myAccepted, false)
        XCTAssertEqual(b.live?.theirAccepted, false)
    }

    func testDeclineAndDisallowed() {
        let (a, b, _) = pair()
        a.invite("b"); b.respond(accept: false)
        XCTAssertNil(a.live)
        b.allowTrade = { false }
        a.invite("b")
        XCTAssertNil(a.live, "declined at once")
        a.allowTrade = { false }
        XCTAssertNotNil(a.invite("b"))
    }

    func testRefusesOfferItDoesNotHoldAndNegativeWireOffers() {
        let (a, b, _) = pair()
        a.offerCheck = { TradeRules.covers($0, credits: 10, cargo: [:], outfits: [:]) ? nil : "no" }
        a.invite("b"); b.respond(accept: true)
        XCTAssertNotNil(a.setOffer(TradeOffer(credits: 11)))
        // a hostile peer's negative entries are stripped
        a.handle(.offer(TradeOffer(credits: -999, cargo: [1: -5], outfits: [2: 0])), from: "b")
        XCTAssertTrue(a.live?.theirOffer.isEmpty ?? false)
    }

    func testFailedRecheckCancelsBothSides() {
        let (a, b, _) = pair()
        var bCommitted = false
        b.commit = { _, _ in bCommitted = true }
        a.invite("b"); b.respond(accept: true)
        var okNow = true
        a.swapCheck = { _, _ in okNow ? nil : "hold changed" }
        a.setAccepted(true)
        okNow = false
        b.setAccepted(true)
        XCTAssertNil(a.live); XCTAssertNil(b.live)
        XCTAssertFalse(bCommitted == false && b.live != nil)
    }

    func testPartnerLeavingClosesTrade() {
        let (a, b, _) = pair()
        a.invite("b"); b.respond(accept: true)
        a.peerLeft("b")
        XCTAssertNil(a.live)
    }

    func testRulesApply() {
        var credits = 100, cargo = [1: 5], outfits = [7: 2]
        TradeRules.apply(give: TradeOffer(credits: 40, cargo: [1: 5], outfits: [7: 1]),
                         receive: TradeOffer(credits: 10, cargo: [2: 3], outfits: [9: 1]),
                         credits: &credits, cargo: &cargo, outfits: &outfits)
        XCTAssertEqual(credits, 70)
        XCTAssertEqual(cargo, [2: 3])
        XCTAssertEqual(outfits, [7: 1, 9: 1])
    }
}
