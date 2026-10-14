import XCTest
import Foundation
@testable import NovaSwiftNet

/// Security rules shared by every frontend: the NSQ1 amplification guard, string safety, receiver-side validation and
/// the parsers' behaviour on hostile input. See docs/SECURITY.md.
final class SecurityTests: XCTestCase {

    // MARK: NSQ1 anti-amplification

    func testPaddedQueryIsBigEnoughAndRecognised() {
        let q = ServerBeacon.queryPacket
        XCTAssertEqual(q.count, QueryGuard.requestSize)
        XCTAssertEqual(QueryGuard.classify(q), .padded)
        XCTAssertEqual(QueryGuard.classify(ServerBeacon.legacyQueryPacket), .legacy)
        XCTAssertTrue(ServerBeacon.isQuery(q))
    }

    func testGarbageAndShortQueriesAreNotQueries() {
        XCTAssertEqual(QueryGuard.classify(Data()), .invalid)
        XCTAssertEqual(QueryGuard.classify(Data("NSQ".utf8)), .invalid)
        XCTAssertEqual(QueryGuard.classify(Data("NSQ1x".utf8)), .invalid, "a short request that isn't the bare legacy one")
        XCTAssertEqual(QueryGuard.classify(Data("NSQ1".utf8) + Data([2]) + Data(count: 100)), .invalid, "padded requests must be >= 512 bytes")
        XCTAssertEqual(QueryGuard.classify(Data("NSQ1".utf8) + Data([9]) + Data(count: 600)), .invalid, "unknown version byte")
        XCTAssertEqual(QueryGuard.classify(Data("NSQ1".utf8) + Data([1]) + Data(count: 1195)), .padded, "the status prober's 1200-byte version-1 request")
        XCTAssertEqual(QueryGuard.classify(Data(repeating: 0x41, count: 1200)), .invalid)
        XCTAssertEqual(QueryGuard.classify(Data("NSQ1".utf8) + Data([2]) + Data(count: 5000)), .invalid, "oversize")
    }

    func testReplyNeverLargerThanRequest() {
        var now = 0.0
        let g = QueryGuard(clock: { now })
        let q = ServerBeacon.queryPacket
        guard case .reply(let maxBytes) = g.decide(q, from: "198.51.100.1") else { return XCTFail() }
        XCTAssertLessThanOrEqual(maxBytes, q.count)
        XCTAssertLessThanOrEqual(maxBytes, QueryGuard.maxReply)
        // The smallest accepted request (512) caps the reply at 512.
        let small = Data("NSQ1".utf8) + Data([2]) + Data(count: 507)
        guard case .reply(let m2) = g.decide(small, from: "198.51.100.2") else { return XCTFail() }
        XCTAssertEqual(m2, 512)
        now += 1
    }

    func testBeaconEncodeHonoursTheCap() {
        let many = (0..<60).map { PluginRequirement(id: "plugin-\($0)", name: "Plug-in number \($0)", contentHash: String(repeating: "ab", count: 16)) }
        let b = ServerBeacon(name: "Big", players: 1, max: 8, requirements: PluginRequirements(plugins: many))
        XCTAssertGreaterThan(b.encode().count, 1200)
        let capped = b.encode(maxBytes: 1200)
        XCTAssertLessThanOrEqual(capped.count, 1200)
        let decoded = ServerBeacon.decode(capped)
        XCTAssertEqual(decoded?.name, "Big")
        XCTAssertEqual(decoded?.pluginCount, 60, "the compact form still carries the plug-in count and signature")
        XCTAssertFalse(decoded?.pluginSignature.isEmpty ?? true)
        XCTAssertTrue(String(decoding: capped, as: UTF8.self).contains("\"truncated\":true"))
    }

    func testPerSourceRateLimitAndRecovery() {
        var now = 100.0
        let g = QueryGuard(burst: 5, refillPerSecond: 2, clock: { now })
        let q = ServerBeacon.queryPacket
        var answered = 0
        for _ in 0..<50 { if case .reply = g.decide(q, from: "203.0.113.5") { answered += 1 } }
        XCTAssertEqual(answered, 5, "burst of 5, then dropped")
        // Another source is unaffected.
        if case .drop = g.decide(q, from: "203.0.113.6") { XCTFail("other sources have their own budget") }
        now += 2   // two seconds: four tokens back
        answered = 0
        for _ in 0..<50 { if case .reply = g.decide(q, from: "203.0.113.5") { answered += 1 } }
        XCTAssertEqual(answered, 4)
    }

    func testLegacyQueriesAreCompactAndRare() {
        var now = 10.0
        let g = QueryGuard(clock: { now })
        let l = ServerBeacon.legacyQueryPacket
        XCTAssertEqual(g.decide(l, from: "192.0.2.1"), .upgradeNotice)
        XCTAssertLessThanOrEqual(QueryGuard.upgradeNotice.count, 64)
        XCTAssertEqual(g.decide(l, from: "192.0.2.1"), .drop, "one legacy answer per address per 5 s")
        now += 5.1
        XCTAssertEqual(g.decide(l, from: "192.0.2.1"), .upgradeNotice, "allowed again after 5 s")
        // Globally limited: 20 per second across all sources.
        var ok = 0
        for i in 0..<200 { if case .upgradeNotice = g.decide(l, from: "10.0.\(i / 250).\(i % 250)") { ok += 1 } }
        XCTAssertLessThanOrEqual(ok, 21)
    }

    func testSourceTableIsBounded() {
        var now = 0.0
        let g = QueryGuard(clock: { now })
        let q = ServerBeacon.queryPacket
        for i in 0..<(QueryGuard.maxSources + 500) {
            _ = g.decide(q, from: "10.\(i >> 16 & 255).\(i >> 8 & 255).\(i & 255)")
            now += 0.0001
        }
        // Still answers an address it already tracks, and doesn't crash or grow without limit.
        _ = g.decide(q, from: "10.0.0.1")
    }

    // MARK: Strings

    func testInvisibleAndBidiCharactersAreStripped() {
        XCTAssertEqual(CrossPlayProtocol.cleanName("Al\u{200B}ice\u{202E}"), "Alice")
        XCTAssertEqual(CrossPlayProtocol.cleanName("A\u{0000}B\u{0007}C\u{0085}D"), "ABCD")
        XCTAssertEqual(CrossPlayProtocol.cleanName("   many    spaces   here  "), "many spaces here")
        XCTAssertEqual(CrossPlayProtocol.cleanName(String(repeating: "x", count: 100)).count, CrossPlayProtocol.maxNameLength)
        XCTAssertEqual(CrossPlayProtocol.cleanName("\u{200B}\u{200C}", fallback: "Pilot"), "Pilot")
    }

    func testPlayerNamesLoseBracketsAndReservedNamesFallBack() {
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("[b]Bob[/b]"), "bBob/b")
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("[url=x]click[/url]"), "url=xclick/url")
        for bad in ["[Server]", "Server", "SERVER", "S3rver", "Adm1n", "admin", "A d m i n", "a-d-m-i-n", "Administrator", "M0derator", "Server2", "Admin01"] {
            let n = CrossPlayProtocol.cleanPlayerName(bad, fallback: "Pilot 7")
            if CrossPlayProtocol.isReservedName(n) { XCTFail("\(bad) -> \(n) is still reserved") }
        }
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("[Server]", fallback: "Pilot 7"), "Pilot 7")
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("S3rver", fallback: "Pilot 7"), "Pilot 7")
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("Adm1n", fallback: "Pilot 7"), "Pilot 7")
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("Captain Kirk"), "Captain Kirk")
        XCTAssertEqual(CrossPlayProtocol.cleanPlayerName("Serverino"), "Serverino", "only the exact look-alikes are reserved")
    }

    func testChatIsCleanedAndCapped() {
        XCTAssertEqual(CrossPlayProtocol.cleanChat("hello\nworld\u{202E}!"), "hello world!")
        XCTAssertEqual(CrossPlayProtocol.cleanChat(String(repeating: "a", count: 1000)).count, CrossPlayProtocol.maxChatLength)
        XCTAssertEqual(CrossPlayProtocol.cleanChat("  \u{200B} \n "), "")
        XCTAssertEqual(CrossPlayProtocol.cleanChat("[b]markup[/b] stays text"), "[b]markup[/b] stays text", "escaping is the display layer's job")
    }

    // MARK: Parsers

    func testBeaconDecodeClampsFields() {
        let json = #"{"name":"\#(String(repeating: "N", count: 500))","players":999999999999,"max":-5,"ver":"\#(String(repeating: "v", count: 500))","port":53735,"rules":"safe","plugins":[{"id":"a","name":"A","hash":"1"}],"proto":1}"#
        var d = Data("NSB1".utf8); d.append(Data(json.utf8))
        let b = ServerBeacon.decode(d)
        XCTAssertNotNil(b)
        XCTAssertLessThanOrEqual(b!.name.count, CrossPlayProtocol.maxServerNameLength)
        XCTAssertLessThanOrEqual(b!.ver.count, 32)
        XCTAssertLessThanOrEqual(b!.players, 1_000_000)
        XCTAssertGreaterThanOrEqual(b!.max, 0)
        XCTAssertNil(ServerBeacon.decode(Data("NSB1[1,2,3]".utf8)))
        XCTAssertNil(ServerBeacon.decode(Data("NSB1".utf8) + Data(repeating: 0x7b, count: 7000)))
        XCTAssertNil(ServerBeacon.decode(Data("NSB1{\"port\":0}".utf8)))
    }

    func testBeaconPluginListIsCapped() {
        let entries = (0..<500).map { #"{"id":"p\#($0)","name":"n","hash":"ab"}"# }.joined(separator: ",")
        let d = Data("NSB1".utf8) + Data(#"{"port":53735,"plugins":[\#(entries)]}"#.utf8)
        // 500 entries is over the packet cap anyway; build one that fits the cap but exceeds the entry cap.
        let few = (0..<150).map { #"{"id":"p\#($0)"}"# }.joined(separator: ",")
        let d2 = Data("NSB1".utf8) + Data(#"{"port":53735,"plugins":[\#(few)]}"#.utf8)
        XCTAssertNil(ServerBeacon.decode(d))
        XCTAssertLessThanOrEqual(ServerBeacon.decode(d2)?.requirements?.plugins.count ?? 0, PluginRequirements.maxEntries)
    }

    func testDirectoryParseSurvivesGarbage() {
        XCTAssertEqual(ServerDirectory.parse(Data("[1,2".utf8)), .failure(.notAServerList))
        XCTAssertEqual(ServerDirectory.parse(Data(repeating: 0x20, count: ServerDirectory.maxBytes + 1)), .failure(.tooLarge))
        let r = ServerDirectory.parse(Data(#"{"servers":[1,"x",null,{"host":"","port":1},{"host":"ok.example","port":70000},{"host":"good.example","name":"[b]n[/b]"}]}"#.utf8))
        guard case .success(let list) = r else { return XCTFail() }
        XCTAssertEqual(list.map(\.host), ["good.example"])
    }

    // MARK: Receiver-side validation

    func testSnapshotSanitizingDropsImpossibleShips() {
        func ship(_ id: Int, x: Double = 0, vx: Double = 0, type: Int = 128, name: String = "ok") -> ShipNetState {
            ShipNetState(id: id, shipTypeID: type, name: name, x: x, y: 0, vx: vx, vy: 0, angle: 0, shield: 10, armor: 10, control: .ai)
        }
        let snap = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
            ship(1), ship(2, x: .nan), ship(3, x: .infinity), ship(4, x: 1e12), ship(5, vx: 1e9), ship(6, type: 9_999_999),
            ship(7, name: "Evil\u{202E}Name"),
        ])
        let s = NetValidation.sanitized(snap)
        XCTAssertEqual(s.ships.map(\.id), [1, 7])
        XCTAssertEqual(s.ships.last?.name, "EvilName")
        let known = NetValidation.sanitized(WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [ship(1, type: 128), ship(2, type: 700)]), knownShipTypes: [128])
        XCTAssertEqual(known.ships.map(\.id), [1])
    }

    func testSnapshotListsAreCapped() {
        let ships = (0..<1000).map { ShipNetState(id: $0, name: "s", x: 0, y: 0, vx: 0, vy: 0, angle: 0, shield: 1, armor: 1, control: .ai) }
        let shots = (0..<5000).map { _ in ProjectileNetState(ownerID: 1, x: 0, y: 0, vx: 0, vy: 0, facing: 0, life: 1, weaponID: 1, graphicSpinID: nil, spinShots: false, translucentShots: false) }
        let s = NetValidation.sanitized(WorldSnapshot(tick: 1, ackInputSeq: 0, ships: ships, shots: shots))
        XCTAssertEqual(s.ships.count, NetValidation.maxShips)
        XCTAssertEqual(s.shots.count, NetValidation.maxShots)
    }

    func testTeleportDetection() {
        func s(_ x: Double) -> ShipNetState { ShipNetState(id: 1, name: "a", x: x, y: 0, vx: 0, vy: 0, angle: 0, shield: 1, armor: 1, control: .remote) }
        XCTAssertTrue(NetValidation.plausibleMove(from: s(0), to: s(300), dt: 0.05))
        XCTAssertFalse(NetValidation.plausibleMove(from: s(0), to: s(900_000), dt: 0.05))
        XCTAssertTrue(NetValidation.plausibleMove(from: s(0), to: s(9_000), dt: 1))
    }

    func testNCBBitsAreRangeLimitedAndDeduplicated() {
        let bits = NetValidation.sanitizedNCB([-1, 0, 5, 5, 100_000, 9_999, Int.max, 12])
        XCTAssertEqual(bits, [0, 5, 9_999, 12])
        XCTAssertEqual(NetValidation.sanitizedNCB(Array(0..<500)).count, NetValidation.maxNCBBitsPerMessage)
    }

    func testTradeOfferValidationAndRules() {
        XCTAssertFalse(NetValidation.valid(TradeOffer(credits: -5)))
        XCTAssertFalse(NetValidation.valid(TradeOffer(credits: Int.max)))
        XCTAssertFalse(NetValidation.valid(TradeOffer(cargo: Dictionary(uniqueKeysWithValues: (0..<500).map { ($0, 1) }))))
        XCTAssertTrue(NetValidation.valid(TradeOffer(credits: 1000, cargo: [1: 3], outfits: [128: 1])))
        // TradeRules: a negative or absent holding can't be "given".
        let hostile = TradeOffer(credits: -1_000_000, cargo: [1: -50], outfits: [2: 0])
        XCTAssertEqual(TradeRules.sanitized(hostile), TradeOffer())
        XCTAssertFalse(TradeRules.covers(TradeOffer(credits: 10, outfits: [128: 2]), credits: 100, cargo: [:], outfits: [128: 1]), "can't give what you don't own")
        var credits = 100; var cargo: [Int: Int] = [:]; var outfits: [Int: Int] = [128: 1]
        TradeRules.apply(give: TradeOffer(), receive: TradeOffer(credits: -999_999), credits: &credits, cargo: &cargo, outfits: &outfits)
        XCTAssertEqual(credits, 100, "a negative offer from the partner can't take credits")
    }

    func testMisbehaviorTrackerWindow() {
        var t = MisbehaviorTracker(threshold: 3, window: 10)
        XCTAssertEqual(t.strike("a", now: 0), 1)
        XCTAssertEqual(t.strike("a", now: 5), 2)
        XCTAssertEqual(t.strike("a", now: 20), 1, "old strikes expire")
        XCTAssertEqual(t.strike("b", now: 20), 1)
    }

    func testTokenBucket() {
        var b = TokenBucket(burst: 3, perSecond: 1, now: 0)
        XCTAssertTrue(b.take(now: 0)); XCTAssertTrue(b.take(now: 0)); XCTAssertTrue(b.take(now: 0))
        XCTAssertFalse(b.take(now: 0))
        XCTAssertTrue(b.take(now: 1.0))
        XCTAssertFalse(b.take(now: 1.1))
    }
}
