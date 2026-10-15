import Foundation

/// IPv4 / IPv6 address text helpers for the multiplayer stack. Every address the transports and the dedicated
/// server expose as a `String` goes through `normalize`, so IPv4-mapped IPv6 (`::ffff:1.2.3.4`, what a dual-stack
/// socket reports for an IPv4 peer) shows up as the plain dotted quad `1.2.3.4` and existing ban lists, allow lists,
/// configs and per-IP limits keep working unchanged.
///
/// IPv6 note: one host normally owns a whole /64 (or larger) and can cycle through billions of addresses in it, so
/// per-address limits and bans would be trivially dodged. `groupKey` therefore collapses an IPv6 address to its /64
/// prefix (`2001:db8:1:2::/64`); IPv4 stays per-address. Rate limits, connection caps, temp-bans and `banned`
/// matching all use the group key.
public enum IPAddressTools {

    /// Parsed address bytes: 4 (IPv4) or 16 (IPv6). Pure Swift (no libc) so it behaves the same on every platform.
    static func bytes(_ text: String) -> [UInt8]? {
        let t = stripZone(text.trimmingCharacters(in: .whitespaces))
        if let v4 = parseV4(t) { return v4 }
        return parseV6(t)
    }

    private static func stripZone(_ s: String) -> String {
        if let i = s.firstIndex(of: "%") { return String(s[..<i]) }
        return s
    }

    private static func parseV4(_ t: String) -> [UInt8]? {
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt8(p) else { return nil }
            out.append(n)
        }
        return out
    }

    private static func parseV6(_ t: String) -> [UInt8]? {
        guard t.contains(":"), !t.contains(":::") else { return nil }
        var head = t, tail = ""
        var compressed = false
        if let r = t.range(of: "::") {
            compressed = true
            head = String(t[..<r.lowerBound]); tail = String(t[r.upperBound...])
            if tail.contains("::") { return nil }
        }
        func groups(_ s: String, last: Bool) -> [UInt16]? {
            if s.isEmpty { return [] }
            var out: [UInt16] = []
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            for (i, p) in parts.enumerated() {
                if p.contains(".") {                     // embedded IPv4 tail (::ffff:1.2.3.4)
                    guard last, i == parts.count - 1, let v4 = parseV4(String(p)) else { return nil }
                    out.append(UInt16(v4[0]) << 8 | UInt16(v4[1])); out.append(UInt16(v4[2]) << 8 | UInt16(v4[3]))
                } else {
                    guard !p.isEmpty, p.count <= 4, let n = UInt16(p, radix: 16) else { return nil }
                    out.append(n)
                }
            }
            return out
        }
        guard let h = groups(head, last: !compressed), let tl = groups(tail, last: true) else { return nil }
        let total = h.count + tl.count
        if compressed { guard total <= 7 else { return nil } } else { guard total == 8 else { return nil } }
        let all = h + [UInt16](repeating: 0, count: 8 - total) + tl
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    private static func isMapped(_ b: [UInt8]) -> Bool {
        b.count == 16 && b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
    }

    private static func text(v4 b: ArraySlice<UInt8>) -> String { b.map(String.init).joined(separator: ".") }

    /// RFC 5952 text of 16 bytes: lower-case hex, longest run (>= 2) of zero groups compressed.
    private static func text(v6 b: [UInt8]) -> String {
        let g = (0..<8).map { UInt16(b[2 * $0]) << 8 | UInt16(b[2 * $0 + 1]) }
        var bestStart = -1, bestLen = 0, i = 0
        while i < 8 {
            if g[i] == 0 {
                var j = i; while j < 8, g[j] == 0 { j += 1 }
                if j - i > bestLen { bestStart = i; bestLen = j - i }
                i = j
            } else { i += 1 }
        }
        if bestLen < 2 { bestStart = -1 }
        var out = ""
        i = 0
        while i < 8 {
            if i == bestStart { out += "::"; i += bestLen; continue }
            if !out.isEmpty, !out.hasSuffix(":") { out += ":" }
            out += String(g[i], radix: 16); i += 1
        }
        return out
    }

    /// Text of raw address bytes (4 or 16), IPv4-mapped IPv6 collapsed to the dotted quad.
    static func format(bytes b: [UInt8]) -> String {
        if b.count == 4 { return text(v4: b[0..<4]) }
        guard b.count == 16 else { return "" }
        if isMapped(b) { return text(v4: b[12..<16]) }
        return text(v6: b)
    }

    /// True for any valid IPv4 or IPv6 literal.
    public static func isValid(_ text: String) -> Bool { bytes(text) != nil }

    public static func isIPv6(_ text: String) -> Bool { (bytes(text)?.count ?? 0) == 16 && !isMapped(bytes(text)!) }

    /// Canonical text: IPv4 dotted quad (IPv4-mapped IPv6 collapses to it), IPv6 lower-case compressed, zone id
    /// dropped. Text that isn't an IP literal is returned trimmed and lower-cased (hostnames).
    public static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let b = bytes(trimmed) else { return trimmed.lowercased() }
        if b.count == 4 { return Self.text(v4: b[0..<4]) }
        if isMapped(b) { return Self.text(v4: b[12..<16]) }
        return Self.text(v6: b)
    }

    /// The key limits and bans are tracked under: IPv4 = the address; IPv6 = its /64 as `prefix::/64`.
    public static func groupKey(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("/64") { text.removeLast(3) }       // already a group key
        guard let b = bytes(text) else { return text.trimmingCharacters(in: .whitespaces).lowercased() }
        if b.count == 4 { return Self.text(v4: b[0..<4]) }
        if isMapped(b) { return Self.text(v4: b[12..<16]) }
        var p = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { p[i] = b[i] }
        return Self.text(v6: p) + "/64"
    }

    /// True if `stored` (a ban/allow-list entry) covers `ip`. IPv4 entries match that address exactly; an IPv6 entry
    /// (with or without the `/64` suffix) covers the whole /64 it sits in, matching how limits and bans are tracked.
    public static func matches(entry stored: String, ip: String) -> Bool {
        var e = stored.trimmingCharacters(in: .whitespaces)
        if e.hasSuffix("/64") { e.removeLast(3) }
        return groupKey(e) == groupKey(ip)
    }

    public static func isLoopback(_ text: String) -> Bool {
        guard let b = bytes(text) else { return false }
        if b.count == 4 { return b[0] == 127 }
        if isMapped(b) { return b[12] == 127 }
        return b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
    }

    /// Private / link-local / unique-local (LAN-ish) address of either family.
    public static func isPrivate(_ text: String) -> Bool {
        guard let b0 = bytes(text) else { return false }
        let b = isMapped(b0) ? Array(b0[12..<16]) : b0
        if b.count == 4 {
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        return (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)   // fc00::/7, fe80::/10
    }

    // MARK: Host:port text

    /// Splits "host", "host:port", "[v6]", "[v6]:port" or a bare IPv6 literal. Port is nil when absent/invalid.
    public static func splitHostPort(_ text: String) -> (host: String, port: Int?) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()), (1...65535).contains(p) { return (host, p) }
            return (host, nil)
        }
        if s.filter({ $0 == ":" }).count == 1, let i = s.lastIndex(of: ":") {
            let p = Int(s[s.index(after: i)...])
            return (String(s[..<i]), (p.map { (1...65535).contains($0) } ?? false) ? p : nil)
        }
        return (s, nil)
    }

    /// "host:port" with IPv6 literals bracketed (`[::1]:53735`).
    public static func joinHostPort(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
