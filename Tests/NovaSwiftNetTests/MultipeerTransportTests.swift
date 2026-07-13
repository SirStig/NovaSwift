#if canImport(MultipeerConnectivity)
import XCTest
@testable import NovaSwiftNet

/// Smoke tests: construction + `Transport` conformance without starting live
/// networking (which needs local-network permission and real peers). Live
/// device-to-device behavior is validated by hand on two devices.
final class MultipeerTransportTests: XCTestCase {

    func testConstructsAndConformsToTransport() {
        let t: Transport = MultipeerTransport(playerID: "device-A")
        XCTAssertEqual(t.localPeerID, "device-A")
        XCTAssertTrue(t.connectedPeers.isEmpty)
    }

    func testSendAndBroadcastAreNoOpsWithoutPeers() {
        // Should not throw or crash when there is nobody connected.
        let t = MultipeerTransport(playerID: "device-A")
        t.send(Data("x".utf8), to: "nobody", channel: .reliable)
        t.broadcast(Data("y".utf8), channel: .unreliable)
        XCTAssertTrue(t.connectedPeers.isEmpty)
    }

    func testDrivesANetSession() {
        // NetSession must accept it as a Transport (delegate wiring compiles/runs).
        let t = MultipeerTransport(playerID: "device-A")
        let session = NetSession(transport: t)
        session.updateLocalPresence(name: "Ari", systemID: 100)
        XCTAssertEqual(session.presence["device-A"]?.currentSystemID, 100)
    }
}
#endif
