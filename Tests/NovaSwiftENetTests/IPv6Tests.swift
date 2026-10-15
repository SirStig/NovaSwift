import XCTest
@testable import NovaSwiftENet
import NovaSwiftNet
import CENet

/// Dual-stack networking: address text helpers, the C address helpers, a dual-stack host reached over `127.0.0.1`
/// and `::1`, and the IPv6 `NSQ1` status query.
final class IPv6Tests: XCTestCase {
    static var nextPort = 55300

    // MARK: Text helpers

    func testNormalizeCollapsesIPv4Mapped() {
        XCTAssertEqual(IPAddressTools.normalize("::ffff:1.2.3.4"), "1.2.3.4")
        XCTAssertEqual(IPAddressTools.normalize("::FFFF:102:304"), "1.2.3.4")
        XCTAssertEqual(IPAddressTools.normalize("1.2.3.4"), "1.2.3.4")
        XCTAssertEqual(IPAddressTools.normalize("2001:0DB8:0:0:0:0:0:1"), "2001:db8::1")
        XCTAssertEqual(IPAddressTools.normalize("[::1]".trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), "::1")
        XCTAssertEqual(IPAddressTools.normalize("fe80::1%en0"), "fe80::1")
        XCTAssertEqual(IPAddressTools.normalize("Play.Example.COM"), "play.example.com")
        XCTAssertFalse(IPAddressTools.isValid("1.2.3"))
        XCTAssertFalse(IPAddressTools.isValid("2001:db8:::1"))
        XCTAssertFalse(IPAddressTools.isValid("1.2.3.256"))
        XCTAssertTrue(IPAddressTools.isValid("64:ff9b::1.2.3.4"))
    }

    func testIPv6GroupsByPrefix64() {
        let a = "2001:db8:1:2:aaaa:bbbb:cccc:dddd", b = "2001:db8:1:2::1", c = "2001:db8:1:3::1"
        XCTAssertEqual(IPAddressTools.groupKey(a), "2001:db8:1:2::/64")
        XCTAssertEqual(IPAddressTools.groupKey(a), IPAddressTools.groupKey(b))
        XCTAssertNotEqual(IPAddressTools.groupKey(a), IPAddressTools.groupKey(c))
        XCTAssertEqual(IPAddressTools.groupKey("2001:db8:1:2::/64"), "2001:db8:1:2::/64", "idempotent")
        // IPv4 (and IPv4-mapped) stay per-address so existing ban lists / limits keep working.
        XCTAssertEqual(IPAddressTools.groupKey("203.0.113.7"), "203.0.113.7")
        XCTAssertEqual(IPAddressTools.groupKey("::ffff:203.0.113.7"), "203.0.113.7")
        XCTAssertTrue(IPAddressTools.matches(entry: "203.0.113.7", ip: "::ffff:203.0.113.7"))
        XCTAssertFalse(IPAddressTools.matches(entry: "203.0.113.7", ip: "203.0.113.8"))
        XCTAssertTrue(IPAddressTools.matches(entry: "2001:db8:1:2::/64", ip: a))
        XCTAssertTrue(IPAddressTools.matches(entry: "2001:db8:1:2::5", ip: a), "a single v6 address bans its /64")
        XCTAssertFalse(IPAddressTools.matches(entry: "2001:db8:1:2::/64", ip: c))
    }

    func testLoopbackAndPrivate() {
        XCTAssertTrue(IPAddressTools.isLoopback("::1")); XCTAssertTrue(IPAddressTools.isLoopback("127.0.0.1"))
        XCTAssertTrue(IPAddressTools.isLoopback("::ffff:127.0.0.1")); XCTAssertFalse(IPAddressTools.isLoopback("::2"))
        XCTAssertTrue(IPAddressTools.isPrivate("fd00::1")); XCTAssertTrue(IPAddressTools.isPrivate("fe80::1"))
        XCTAssertFalse(IPAddressTools.isPrivate("2001:db8::1")); XCTAssertTrue(IPAddressTools.isPrivate("192.168.1.2"))
    }

    func testHostPortParsingRoundTrips() throws {
        func parse(_ s: String) throws -> CrossPlayAddress { try CrossPlayAddress.parse(s).get() }
        XCTAssertEqual(try parse("[::1]:53735"), CrossPlayAddress(host: "::1", port: 53735))
        XCTAssertEqual(try parse("[2001:db8::7]:4000"), CrossPlayAddress(host: "2001:db8::7", port: 4000))
        XCTAssertEqual(try parse("::1"), CrossPlayAddress(host: "::1", port: CrossPlayProtocol.defaultPort))
        XCTAssertEqual(try parse("2001:db8::7"), CrossPlayAddress(host: "2001:db8::7", port: CrossPlayProtocol.defaultPort))
        XCTAssertEqual(try parse("203.0.113.9:1234"), CrossPlayAddress(host: "203.0.113.9", port: 1234))
        XCTAssertEqual(try parse("play.example.com"), CrossPlayAddress(host: "play.example.com", port: CrossPlayProtocol.defaultPort))
        for text in ["[::1]:4000", "[2001:db8::7]", "203.0.113.9:1234", "play.example.com:99"] {
            let a = try parse(text)
            XCTAssertEqual(try parse(a.formatted), a, "\(text) -> \(a.formatted)")
        }
        XCTAssertEqual(IPAddressTools.joinHostPort("::1", 53735), "[::1]:53735")
        XCTAssertEqual(IPAddressTools.splitHostPort("[::1]:53735").host, "::1")
        XCTAssertEqual(IPAddressTools.splitHostPort("[::1]:53735").port, 53735)
        XCTAssertEqual(IPAddressTools.splitHostPort("host:12").port, 12)
        XCTAssertNil(IPAddressTools.splitHostPort("::1").port)
    }

    // MARK: C address helpers

    private func hostIP(_ a: ENetAddress) -> String {
        var a = a; var buf = [CChar](repeating: 0, count: 64)
        XCTAssertEqual(enet_address_get_host_ip(&a, &buf, 64), 0)
        return String(cString: buf)
    }

    func testENetAddressFormatAndParse() {
        var a = ENetAddress()
        XCTAssertEqual(enet_address_set_host_ip(&a, "::ffff:1.2.3.4"), 0)
        XCTAssertEqual(enet_address_is_ipv4_mapped(&a), 1)
        XCTAssertEqual(hostIP(a), "1.2.3.4", "IPv4-mapped prints as a plain dotted quad")
        var v4: UInt32 = 0
        XCTAssertEqual(enet_address_get_ipv4(&a, &v4), 0)
        XCTAssertEqual(UInt32(bigEndian: v4), 0x01020304)

        XCTAssertEqual(enet_address_set_host_ip(&a, "10.0.0.5"), 0); XCTAssertEqual(hostIP(a), "10.0.0.5")
        XCTAssertEqual(enet_address_set_host_ip(&a, "2001:db8::42"), 0)
        XCTAssertEqual(enet_address_is_ipv4_mapped(&a), 0); XCTAssertEqual(hostIP(a), "2001:db8::42")
        XCTAssertEqual(enet_address_get_ipv4(&a, &v4), -1)
        XCTAssertEqual(enet_address_set_host_ip(&a, "not an ip"), -1)

        enet_address_set_host_ipv4(&a, UInt32(0x0A000001).bigEndian)
        XCTAssertEqual(hostIP(a), "10.0.0.1")
        enet_address_set_host_broadcast(&a); XCTAssertEqual(enet_address_is_broadcast(&a), 1); XCTAssertEqual(hostIP(a), "255.255.255.255")
        enet_address_set_host_any(&a); XCTAssertEqual(enet_address_is_any(&a), 1)

        // Hostnames resolve (getaddrinfo, AF_UNSPEC); localhost is loopback in whichever family comes back.
        XCTAssertEqual(enet_address_set_host(&a, "localhost"), 0)
        XCTAssertEqual(enet_address_is_loopback(&a), 1, "localhost -> \(hostIP(a))")
        XCTAssertEqual(enet_address_set_host(&a, "127.0.0.1"), 0); XCTAssertEqual(hostIP(a), "127.0.0.1")
        XCTAssertEqual(enet_address_set_host(&a, "::1"), enet_socket_ipv6_available() == 1 ? 0 : -1)
    }

    // MARK: Dual-stack loopback

    private func ipv6Loopback() throws {
        try XCTSkipUnless(enet_socket_ipv6_available() == 1, "AF_INET6 sockets aren't available here")
        // Probe: can a datagram socket bind ::1 at all? (IPv6 loopback can be absent in odd sandboxes.)
        guard let fd = UDP.makeSocket(bindPort: nil, broadcast: false, shared: false, family: Int32(AF_INET6)) else {
            throw XCTSkip("can't create an IPv6 UDP socket")
        }
        UDP.closeSocket(fd)
        var a = ENetAddress()
        guard enet_address_set_host(&a, "::1") == 0, let h = enet_host_create(&a, 1, 0, 0, 0) else {
            throw XCTSkip("IPv6 loopback (::1) isn't usable here")
        }
        enet_host_destroy(h)
    }

    func testDualStackHostAcceptsIPv4AndIPv6Clients() throws {
        try ipv6Loopback()
        Self.nextPort += 4
        let port = Self.nextPort
        let host = ENetHostTransport(config: .init(port: port, maxPlayers: 8, serverName: "Dual", hostName: "Hosty", rulesJSON: "{}", rulesName: "safe"))
        try host.start()
        defer { host.disconnect() }

        func client(_ addr: String, _ name: String) -> ENetTransport {
            ENetTransport(config: .init(host: addr, port: port, displayName: name, password: "", gameVersion: CrossPlayProtocol.appVersion, manifestJSON: ""))
        }
        let c4 = client("127.0.0.1", "four"), c6 = client("::1", "six"), c6b = client("[::1]", "sixb")
        for c in [c4, c6, c6b] { try c.connect() }
        let end = Date().addingTimeInterval(5)
        while Date() < end, ![c4, c6, c6b].allSatisfy({ $0.state == .connected }) {
            host.service(); [c4, c6, c6b].forEach { $0.service() }
            Thread.sleep(forTimeInterval: 0.004)
        }
        XCTAssertEqual(c4.state, .connected, "IPv4 client on the dual-stack socket")
        XCTAssertEqual(c6.state, .connected, "IPv6 client")
        XCTAssertEqual(c6b.state, .connected, "bracketed IPv6 literal")
        let ips = Dictionary(uniqueKeysWithValues: host.clients.map { ($0.name, $0.ip) })
        XCTAssertEqual(ips["four"], "127.0.0.1", "IPv4-mapped peers are reported as dotted quads")
        XCTAssertEqual(ips["six"], "::1")
        [c4, c6, c6b].forEach { $0.disconnect() }
    }

    func testStatusQueryOverIPv6() throws {
        try ipv6Loopback()
        Self.nextPort += 4
        let port = Self.nextPort
        let host = ENetHostTransport(config: .init(port: port, maxPlayers: 4, serverName: "Dual", hostName: "Hosty", rulesJSON: "{}", rulesName: "safe"))
        try host.start()
        defer { host.disconnect() }
        let svc = LANBeaconService(listenPort: port + 1000)
        defer { svc.stop() }
        XCTAssertTrue(svc.startAnnouncing(gamePort: port, provider: { host.beacon() }))
        let v6 = ServerStatusQuery.query(host: "::1", gamePort: port, timeout: 3)
        XCTAssertEqual(v6?.beacon.name, "Dual", "NSQ1 over IPv6")
        let v4 = ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3)
        XCTAssertEqual(v4?.beacon.name, "Dual", "NSQ1 over IPv4 still works")
    }

    func testLoopbackOnlyHostStillServesIPv4() throws {
        Self.nextPort += 4
        let port = Self.nextPort
        let host = ENetHostTransport(config: .init(port: port, maxPlayers: 4, serverName: "L", hostName: "H", rulesJSON: "{}", rulesName: "safe", loopbackOnly: true))
        try host.start()
        defer { host.disconnect() }
        let c = ENetTransport(config: .init(host: "127.0.0.1", port: port, displayName: "x", password: "", gameVersion: CrossPlayProtocol.appVersion, manifestJSON: ""))
        try c.connect()
        let end = Date().addingTimeInterval(4)
        while Date() < end, c.state != .connected { host.service(); c.service(); Thread.sleep(forTimeInterval: 0.004) }
        XCTAssertEqual(c.state, .connected)
    }
}
