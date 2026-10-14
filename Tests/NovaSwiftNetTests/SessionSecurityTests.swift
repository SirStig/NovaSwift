import XCTest
import Foundation
@testable import NovaSwiftNet

/// A transport whose peer "1" is the relay server (like ENet) and that lets a test inject packets "from" any peer.
final class FakeRelayTransport: Transport {
    let localPeerID: PeerID
    var connectedPeers: [PeerID] = ["1"]
    weak var delegate: TransportDelegate?
    var hostPeerID: PeerID? { "1" }
    var sent: [(Data, PeerID?)] = []
    init(local: PeerID) { localPeerID = local }
    func send(_ data: Data, to peer: PeerID, channel: NetChannel) { sent.append((data, peer)) }
    func broadcast(_ data: Data, channel: NetChannel) { sent.append((data, nil)) }
    func disconnect() {}
    func inject(_ m: NetMessage, from peer: PeerID) { delegate?.transport(self, didReceive: try! NetCodec.encode(m), from: peer) }
    func injectRaw(_ d: Data, from peer: PeerID) { delegate?.transport(self, didReceive: d, from: peer) }
}

final class SessionSecurityTests: XCTestCase {
    func make() -> (NetSession, FakeRelayTransport) {
        let t = FakeRelayTransport(local: "1000")
        let s = NetSession(transport: t, rules: .safe)
        s.updateLocalPresence(name: "Me", systemID: 5)
        return (s, t)
    }

    func testPresenceMustBeAnnouncedByItsOwner() {
        let (s, t) = make()
        var reports: [(PeerID, String)] = []
        s.onMisbehavior = { p, w, _ in reports.append((p, w)) }
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 5)), from: "2000")
        XCTAssertEqual(s.presence["2000"]?.name, "Eve")
        // Eve claims Bob is in her system: refused.
        t.inject(.presence(PlayerPresence(playerID: "3000", name: "Bob", currentSystemID: 5)), from: "2000")
        XCTAssertNil(s.presence["3000"])
        XCTAssertEqual(reports.first?.0, "2000")
        // Out-of-range system ids and BBCode names are rejected / neutralised.
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: -7)), from: "2000")
        XCTAssertEqual(s.presence["2000"]?.currentSystemID, 5)
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "[color=red]Eve[/color]\u{202E}", currentSystemID: 5)), from: "2000")
        XCTAssertEqual(s.presence["2000"]?.name, "color=redEve/color")
    }

    func testChatSenderIsForcedAndSanitised() {
        let (s, t) = make()
        var got: [ChatMessage] = []
        s.onChat = { got.append($0) }
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 9)), from: "2000")
        // Forged sender id: dropped.
        t.inject(.chat(ChatMessage(playerID: "3000", senderName: "Bob", text: "hi")), from: "2000")
        XCTAssertTrue(got.isEmpty)
        // A lying name is replaced by the presence name; control characters go; length is capped.
        t.inject(.chat(ChatMessage(playerID: "2000", senderName: "[Server]", text: "hello\u{202E}\n" + String(repeating: "z", count: 500))), from: "2000")
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].senderName, "Eve")
        XCTAssertLessThanOrEqual(got[0].text.count, CrossPlayProtocol.maxChatLength)
        XCTAssertFalse(got[0].text.contains("\u{202E}"))
    }

    func testServerLabelSurvivesOnlyFromTheHost() {
        let (s, t) = make()
        var got: [ChatMessage] = []
        s.onChat = { got.append($0) }
        t.inject(.chat(ChatMessage(playerID: "1", senderName: "[Server]", text: "welcome")), from: "1")
        XCTAssertEqual(got.first?.senderName, "[Server]")
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 9)), from: "2000")
        t.inject(.chat(ChatMessage(playerID: "2000", senderName: "[Server]", text: "I am the server")), from: "2000")
        XCTAssertEqual(got.last?.senderName, "Eve")
    }

    func testChatFloodIsRateLimitedAndReported() {
        let (s, t) = make()
        var now = 0.0
        s.setClock { now }
        var got = 0, strikes = 0
        s.onChat = { _ in got += 1 }
        s.onMisbehavior = { _, _, n in strikes = n }
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 9)), from: "2000")
        for i in 0..<100 { t.inject(.chat(ChatMessage(playerID: "2000", senderName: "Eve", text: "spam \(i)")), from: "2000") }
        XCTAssertEqual(got, Int(NetLimits.chatBurst))
        XCTAssertGreaterThan(strikes, 10)
        now += 10
        t.inject(.chat(ChatMessage(playerID: "2000", senderName: "Eve", text: "later")), from: "2000")
        XCTAssertEqual(got, Int(NetLimits.chatBurst) + 1)
    }

    func testBlockedPlayersAreMuted() {
        let (s, t) = make()
        var got: [String] = []
        s.onChat = { got.append($0.text) }
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 9)), from: "2000")
        s.block("2000")
        t.inject(.chat(ChatMessage(playerID: "2000", senderName: "Eve", text: "you suck")), from: "2000")
        XCTAssertTrue(got.isEmpty)
        s.unblock("2000")
        t.inject(.chat(ChatMessage(playerID: "2000", senderName: "Eve", text: "sorry")), from: "2000")
        XCTAssertEqual(got, ["sorry"])
    }

    func testRulesAndKicksOnlyFromTheHost() {
        let (s, t) = make()
        var kicked = false
        s.onKicked = { kicked = true }
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 9)), from: "2000")
        t.inject(.sessionRules(.fullStakes), from: "2000")
        XCTAssertEqual(s.sessionRules, .safe)
        t.inject(.kick("1000"), from: "2000")
        XCTAssertFalse(kicked)
        t.inject(.sessionRules(.fullStakes), from: "1")
        XCTAssertEqual(s.sessionRules, .fullStakes)
        t.inject(.kick("1000"), from: "1")
        XCTAssertTrue(kicked)
        // Absurd game speeds are refused even from the host.
        var bad = SessionRules.safe; bad.gameSpeedMultiplier = 100
        t.inject(.sessionRules(bad), from: "1")
        XCTAssertEqual(s.sessionRules, .fullStakes)
    }

    func testStoryBitsOnlyFromTheSystemAuthority() {
        let (s, t) = make()   // we are 1000 in system 5
        var received: [[Int]] = []
        s.onNCB = { bits, _ in received.append(bits) }
        // (ids compare as strings) 2000 > 1000, so WE are the authority: nobody may push bits at us.
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 5)), from: "2000")
        t.inject(.ncb(NCBUpdate(setBits: [1, 2])), from: "2000")
        XCTAssertTrue(received.isEmpty)
        // 100 joins with a smaller id: it is the authority now.
        t.inject(.presence(PlayerPresence(playerID: "100", name: "Cap", currentSystemID: 5)), from: "100")
        t.inject(.ncb(NCBUpdate(setBits: [1, -4, 100_000, 7, 7])), from: "100")
        XCTAssertEqual(received, [[1, 7]])
        // A player in another system can't either.
        t.inject(.presence(PlayerPresence(playerID: "60", name: "Far", currentSystemID: 77)), from: "60")
        t.inject(.ncb(NCBUpdate(setBits: [3])), from: "60")
        XCTAssertEqual(received.count, 1)
    }

    func testTradeFromStrangersAndHostileOffersAreDropped() {
        let (s, t) = make()
        var signals: [TradeSignal] = []
        s.onTrade = { sig, _ in signals.append(sig) }
        t.inject(.trade(.invite(fromName: "x")), from: "9999")
        XCTAssertTrue(signals.isEmpty, "no presence, no trade")
        t.inject(.presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 5)), from: "2000")
        t.inject(.trade(.offer(TradeOffer(credits: -100))), from: "2000")
        XCTAssertTrue(signals.isEmpty)
        t.inject(.trade(.offer(TradeOffer(credits: 100, cargo: [1: -3, 2: 4]))), from: "2000")
        XCTAssertEqual(signals, [.offer(TradeOffer(credits: 100, cargo: [2: 4]))])
        t.inject(.trade(.invite(fromName: "[Server]")), from: "2000")
        if case .invite(let n)? = signals.last { XCTAssertNotEqual(n, "[Server]") } else { XCTFail() }
    }

    func testOversizedAndGarbageMessagesAreDroppedAndCounted() {
        let (s, t) = make()
        var failures = 0
        s.onDecodeFailure = { _ in failures += 1 }
        t.injectRaw(Data(repeating: 0x7b, count: NetLimits.maxData + 1), from: "2000")
        t.injectRaw(Data("not json".utf8), from: "2000")
        t.injectRaw(Data(#"{"presence":"wrong type"}"#.utf8), from: "2000")
        XCTAssertEqual(failures, 2, "the oversize packet is refused before decoding")
        XCTAssertEqual(s.rejectedCount, 3)
    }

    func testPluginManifestSizeCap() {
        let (s, t) = make()
        var got = 0
        s.onPluginManifest = { _, _ in got += 1 }
        t.inject(.pluginManifest(PluginManifest((0..<300).map { PluginRequirement(id: "p\($0)", name: "n", contentHash: "h") })), from: "1")
        XCTAssertEqual(got, 0)
        t.inject(.pluginManifest(PluginManifest([PluginRequirement(id: "ok", name: "n", contentHash: "h")])), from: "1")
        XCTAssertEqual(got, 1)
    }

    // MARK: Fuzz

    struct SplitMix: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }

    func testFuzzedPacketsNeverCrashTheSession() {
        let (s, t) = make()
        var rng = SplitMix(s: 0xC0FFEE)
        let seeds: [NetMessage] = [
            .presence(PlayerPresence(playerID: "2000", name: "Eve", currentSystemID: 5, shipTypeHint: 3)),
            .chat(ChatMessage(playerID: "2000", senderName: "Eve", text: "hi")),
            .ncb(NCBUpdate(setBits: [1, 2, 3])), .kick("1000"), .trade(.offer(TradeOffer(credits: 5, cargo: [1: 2]))),
            .sessionRules(.safe), .pluginManifest(.empty), .presenceRequest,
            .snapshot(WorldSnapshot(tick: 1, ackInputSeq: 1, ships: [ShipNetState(id: 1, name: "n", x: 1, y: 2, vx: 3, vy: 4, angle: 0, shield: 1, armor: 1, control: .ai)])),
            .input(InputFrame(tick: 1, seq: 1, intent: NetIntent())),
        ]
        let encoded = seeds.map { [UInt8](try! NetCodec.encode($0)) }
        for i in 0..<6000 {
            var bytes: [UInt8]
            switch i % 4 {
            case 0: bytes = (0..<Int.random(in: 0...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            case 1:   // a valid message with a few bytes flipped
                bytes = encoded[Int.random(in: 0..<encoded.count, using: &rng)]
                for _ in 0..<Int.random(in: 1...4, using: &rng) where !bytes.isEmpty { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            case 2:   // truncated
                let b = encoded[Int.random(in: 0..<encoded.count, using: &rng)]
                bytes = Array(b.prefix(Int.random(in: 0...b.count, using: &rng)))
            default:  // JSON with extreme numbers
                bytes = Array(#"{"snapshot":{"tick":1,"ackInputSeq":1,"ships":[{"id":1e999,"x":1e308,"y":-1e308}],"shots":[],"beams":[],"effects":[]}}"#.utf8)
            }
            t.injectRaw(Data(bytes), from: ["2000", "3000", "1"][i % 3])
        }
        // Still functional afterwards.
        t.inject(.presence(PlayerPresence(playerID: "4000", name: "Zed", currentSystemID: 1)), from: "4000")
        XCTAssertEqual(s.presence["4000"]?.name, "Zed")
    }
}
