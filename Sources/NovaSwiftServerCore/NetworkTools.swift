import Foundation
import NovaSwiftENet
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// "Can players reach me?" helpers: this machine's addresses, the public IP, and a UPnP port-forward attempt.
public enum NetworkTools {

    public struct LocalAddress: Equatable {
        public var interface: String
        public var ip: String
        public var kind: String   // "lan", "tailscale", "other"
    }

    /// IPv4 addresses of this machine (loopback skipped).
    public static func localAddresses() -> [LocalAddress] {
        var out: [LocalAddress] = []
        #if os(Windows)
        // Per-interface names aren't enumerated on Windows; list the addresses the host name resolves to.
        for ip in Sock.localIPv4() { out.append(LocalAddress(interface: "network", ip: ip, kind: classify(ip: ip, interface: "network"))) }
        return out
        #else
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return out }
        defer { freeifaddrs(list) }
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let flags = Int(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & Int(IFF_UP) != 0, flags & Int(IFF_LOOPBACK) == 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            let name = String(cString: p.pointee.ifa_name)
            out.append(LocalAddress(interface: name, ip: ip, kind: classify(ip: ip, interface: name)))
        }
        return out
        #endif
    }

    static func classify(ip: String, interface: String) -> String {
        if isCGNAT(ip) { return "tailscale" }   // 100.64.0.0/10 is Tailscale's range (and carrier-grade NAT)
        if isPrivate(ip) { return "lan" }
        return "other"
    }

    /// A valid IPv4 or IPv6 address, or an IPv6 `/64` group written `prefix::/64` (how IPv6 bans are stored).
    public static func isIP(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("/64") { t.removeLast(3) }
        return IPAddressTools.isValid(t)
    }

    public static func octets(_ ip: String) -> [Int]? {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p.allSatisfy({ (0...255).contains($0) }) ? p : nil
    }

    public static func isPrivate(_ ip: String) -> Bool {
        guard let o = octets(ip) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }

    /// 100.64.0.0/10: shared address space used by carrier-grade NAT (and by Tailscale).
    public static func isCGNAT(_ ip: String) -> Bool {
        guard let o = octets(ip) else { return false }
        return o[0] == 100 && (64...127).contains(o[1])
    }

    // MARK: Public IP

    /// The address the internet sees, via a plain HTTPS text lookup. nil when offline. Blocking (<= ~6 s).
    public static func publicIP(timeout: TimeInterval = 4) -> String? {
        for url in ["https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"] {
            if let data = httpGet(URL(string: url)!, timeout: timeout),
               let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               isIP(s) { return IPAddressTools.normalize(s) }
        }
        return nil
    }

    static func httpGet(_ url: URL, timeout: TimeInterval, headers: [String: String] = [:]) -> Data? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("NovaSwiftServer", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return send(req, timeout: timeout)
    }

    /// One long-lived session. On Linux, deallocating a URLSession (swift-corelibs-foundation) can trip
    /// "_MultiHandle deallocated with non-zero retain count" and abort the process, so never make one per request.
    private static let session = URLSession(configuration: .ephemeral)

    static func send(_ req: URLRequest, timeout: TimeInterval) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var req = req
        req.timeoutInterval = timeout
        let task = session.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode) { result = d }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel() }
        return result
    }

    // MARK: UPnP

    public struct UPnPResult: Equatable {
        public var ok: Bool
        public var message: String
        public var externalIP: String?
        public var routerBehindNAT: Bool
    }

    /// Ask the router to forward `ports` (UDP) to this machine. Many routers have UPnP off and some ISPs put you behind
    /// carrier-grade NAT, where forwarding is impossible; the message says which. Blocking (a few seconds).
    public static func tryUPnP(ports: [Int], description: String = "NovaSwift Server") -> UPnPResult {
        guard let local = localAddresses().first(where: { $0.kind == "lan" || $0.kind == "other" }) else {
            return UPnPResult(ok: false, message: "No network connection found on this computer.", externalIP: nil, routerBehindNAT: false)
        }
        guard let location = ssdpDiscover() else {
            return UPnPResult(ok: false, message: "No router answered the automatic port-forwarding request (UPnP is probably switched off on your router). Forward UDP \(ports.map(String.init).joined(separator: " and ")) by hand - see the instructions below.", externalIP: nil, routerBehindNAT: false)
        }
        guard let desc = httpGet(location, timeout: 4), let xml = String(data: desc, encoding: .utf8),
              let (service, control) = findWANService(xml: xml, base: location) else {
            return UPnPResult(ok: false, message: "Your router answered but doesn't offer port forwarding. Forward the ports by hand.", externalIP: nil, routerBehindNAT: false)
        }
        var added = 0
        for port in ports {
            let body = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:AddPortMapping xmlns:u="\(service)"><NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>UDP</NewProtocol><NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(local.ip)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>\(description)</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration></u:AddPortMapping></s:Body></s:Envelope>
            """
            if soap(control, service: service, action: "AddPortMapping", body: body) != nil { added += 1 }
        }
        var external: String?
        let ipBody = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetExternalIPAddress xmlns:u="\(service)"></u:GetExternalIPAddress></s:Body></s:Envelope>
        """
        if let r = soap(control, service: service, action: "GetExternalIPAddress", body: ipBody),
           let ip = tag("NewExternalIPAddress", in: r), octets(ip) != nil { external = ip }   // UPnP IGD gives the IPv4 WAN address
        let behindNAT = external.map { isPrivate($0) || isCGNAT($0) } ?? false
        if added == ports.count {
            var msg = "Your router agreed to forward UDP \(ports.map(String.init).joined(separator: " and ")) to this computer."
            if behindNAT { msg += " But the router's own address (\(external ?? "?")) is not a public one, so your internet provider is sharing one address between customers (CGNAT). Players outside your home still can't connect - use a VPS or Tailscale." }
            return UPnPResult(ok: !behindNAT, message: msg, externalIP: external, routerBehindNAT: behindNAT)
        }
        return UPnPResult(ok: false, message: "Your router refused to forward the port automatically. Forward UDP \(ports.map(String.init).joined(separator: " and ")) by hand.", externalIP: external, routerBehindNAT: behindNAT)
    }

    static func ssdpDiscover() -> URL? {
        guard let fd = Sock.udp() else { return nil }
        defer { Sock.close(fd) }
        Sock.setReceiveTimeout(fd, seconds: 1.5)
        let targets = ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2", "upnp:rootdevice"]
        for st in targets {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n"
            Sock.sendTo(fd, msg, ip: "239.255.255.250", port: 1900)
            var buf = [UInt8](repeating: 0, count: 2048)
            let deadline = Date().addingTimeInterval(1.6)
            while Date() < deadline {
                let n = Sock.recv(fd, &buf, max: buf.count)
                if n <= 0 { break }
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                    let v = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                    if let u = URL(string: v) { return u }
                }
            }
        }
        return nil
    }

    static func findWANService(xml: String, base: URL) -> (service: String, control: URL)? {
        for type in ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1",
                     "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            guard let r = xml.range(of: type) else { continue }
            let rest = xml[r.upperBound...]
            if let ctl = tag("controlURL", in: String(rest)) {
                let url = ctl.hasPrefix("http") ? URL(string: ctl) : URL(string: ctl, relativeTo: base)?.absoluteURL
                if let url { return (type, url) }
            }
        }
        return nil
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(name)>"), let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return String(xml[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func soap(_ url: URL, service: String, action: String, body: String) -> String? {
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(body.utf8)
        return send(req, timeout: 4).flatMap { String(data: $0, encoding: .utf8) }
    }
}
