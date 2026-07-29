import Foundation

/// A reference to a live ship or a system stellar (planet/station/gate), used
/// throughout the dev console/debug tooling to link a log line, a right-click,
/// or a "cycle through everything" step back to a concrete in-game thing —
/// `entityID` for a `Ship` (`World.shipByID`), `id` for a `spöb`
/// (`SpobRes`/`PlanetVisual`).
enum DevEntityRef: Hashable, Sendable {
    case ship(id: Int, name: String)
    case spob(id: Int, name: String)

    var id: Int {
        switch self {
        case let .ship(id, _): return id
        case let .spob(id, _): return id
        }
    }

    var name: String {
        switch self {
        case let .ship(_, name): return name
        case let .spob(_, name): return name
        }
    }

    var systemImage: String {
        switch self {
        case .ship: return "airplane"
        case .spob: return "globe.americas.fill"
        }
    }

    /// The console-command token for this ref — every command that takes an
    /// entity accepts `selected` (the live selection) or a bare id, so a log
    /// line's clickable chip can select it without needing a dedicated verb.
    var commandArg: String { "\(id)" }

    /// Round-trips through a `devent://<kind>/<id>?name=<name>` URL so a
    /// clickable log chip can be represented as an `AttributedString` link
    /// (SwiftUI's `Text` only renders inline tap targets via `.link`, so this
    /// is how `ConsolePane` recovers the tapped ref from `openURL`).
    var linkURL: URL {
        var components = URLComponents()
        components.scheme = "devent"
        switch self {
        case .ship: components.host = "ship"
        case .spob: components.host = "spob"
        }
        components.path = "/\(id)"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url!
    }

    init?(linkURL url: URL) {
        guard url.scheme == "devent", let host = url.host,
              let idString = url.pathComponents.dropFirst().first, let id = Int(idString) else { return nil }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "name" })?.value ?? ""
        switch host {
        case "ship": self = .ship(id: id, name: name)
        case "spob": self = .spob(id: id, name: name)
        default: return nil
        }
    }
}

/// Parses the `«ship:<id>:<name>»` / `«spob:<id>:<name>»` markers that log
/// call sites embed to tag a specific entity (see `Log.<category>` call
/// sites in `NovaSwiftEngine`/`NovaSwiftStory`) into clickable console
/// segments. Plain string scanning rather than `NSRegularExpression` — the
/// marker characters (`«»`) are distinctive and never appear in ordinary log
/// text, so a linear scan is both simpler and cheaper than a regex here.
enum DevLogLinking {
    enum Segment: Sendable {
        case text(String)
        case entity(DevEntityRef)
    }

    static func segments(in text: String) -> [Segment] {
        var result: [Segment] = []
        var plain = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«") {
            plain += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "»"),
                  let ref = parseTag(rest[afterOpen..<close]) else {
                // Unterminated/malformed marker — treat the `«` as plain text
                // and keep scanning past it rather than dropping the rest of
                // the line.
                plain.append("«")
                rest = rest[afterOpen...]
                continue
            }
            if !plain.isEmpty { result.append(.text(plain)); plain = "" }
            result.append(.entity(ref))
            rest = rest[rest.index(after: close)...]
        }
        plain += rest
        if !plain.isEmpty { result.append(.text(plain)) }
        return result
    }

    private static func parseTag(_ tag: Substring) -> DevEntityRef? {
        let parts = tag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let id = Int(parts[1]) else { return nil }
        let name = String(parts[2])
        switch parts[0] {
        case "ship": return .ship(id: id, name: name)
        case "spob": return .spob(id: id, name: name)
        default: return nil
        }
    }
}
