import SwiftUI
import NovaSwiftStory

// Shared look + small pure helpers for the Story Guide (kept in one place so the
// sidebar, hero, timeline and cards read as one system — mirrors the Godot
// Story Guide's palette and wording).

extension EVTheme {
    static let card = Color(white: 0.105)
    static let side = Color(white: 0.075)
    static let dim = Color(red: 0.62, green: 0.64, blue: 0.70)
    static let done = Color(red: 0.30, green: 0.85, blue: 0.40)
    static let active = Color(red: 0.25, green: 0.85, blue: 0.95)
    static let avail = Color(red: 0.98, green: 0.85, blue: 0.25)
    static let lock = Color(red: 0.55, green: 0.57, blue: 0.62)
    static let fail = Color(red: 1.0, green: 0.40, blue: 0.35)
    static let purple = Color(red: 0.72, green: 0.55, blue: 0.98)
    static let focusRing = Color(red: 1.0, green: 0.90, blue: 0.55)
}

// MARK: - Storyline-level state

/// A storyline's overall state for the sidebar / hero badge.
enum StoryLaneState {
    case complete, active, available, locked

    var label: String {
        switch self {
        case .complete: return "Complete"
        case .active: return "Active"
        case .available: return "Available"
        case .locked: return "Locked"
        }
    }
    var tint: Color {
        switch self {
        case .complete: return EVTheme.done
        case .active: return EVTheme.active
        case .available: return EVTheme.avail
        case .locked: return EVTheme.lock
        }
    }
    var symbol: String {
        switch self {
        case .complete: return "checkmark.seal.fill"
        case .active: return "target"
        case .available: return "sparkles"
        case .locked: return "lock.fill"
        }
    }
}

extension StoryGuideModel {
    /// The lane's "you are here" node (first not-completed step), nil once finished.
    func currentNode(forKey key: String) -> StoryMapNode? {
        guard let id = currentStepID(forKey: key) else { return nil }
        return storyMap.nodes.first { $0.id == id }
    }

    func laneState(_ lane: StoryMapLane) -> StoryLaneState {
        if lane.isComplete { return .complete }
        let status = currentNode(forKey: lane.key)?.step.status
        if status == .active || lane.completedCount > 0 { return .active }
        if status == .available { return .available }
        return .locked
    }
}

// MARK: - Mission-text wildcards

/// Mission-text wildcards (`<RST>`, `<DST>`, …) shown as small amber token chips
/// with a readable name instead of raw angle brackets. Same table as the Godot
/// Story Guide (MissionTextResolver's tag list).
enum StoryTokens {
    static let names: [String: String] = [
        "DST": "destination", "DSY": "destination system", "RST": "return planet",
        "RSY": "return system", "CT": "cargo", "CQ": "cargo amount", "SN": "ship name",
        "DL": "deadline", "PN": "your name", "PNN": "your nickname", "PSN": "your ship",
        "PST": "your ship type", "OSN": "other ship", "PRK": "your rank", "SRK": "your rank",
        "RRK": "recent rank", "PAY": "payment", "REG": "region",
    ]

    private static let pattern = "<([A-Za-z]{2,4})([0-9]{0,4})>"

    private static func name(_ ns: NSString, _ m: NSTextCheckingResult) -> String {
        let tag = ns.substring(with: m.range(at: 1)).uppercased()
        return names[tag] ?? tag.lowercased()
    }

    /// Plain-text version for chips / tooltips: wildcards as "(return planet)".
    static func plain(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += "(\(name(ns, m)))"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Styled version: each wildcard becomes an amber chip run.
    static func attributed(_ text: String, tint: Color = EVTheme.accent) -> AttributedString {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return AttributedString(text) }
        let ns = text as NSString
        var out = AttributedString()
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            var chip = AttributedString("\u{00A0}\(name(ns, m))\u{00A0}")
            chip.foregroundColor = tint
            chip.backgroundColor = tint.opacity(0.2)
            out += chip
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        return out
    }
}

/// Text that renders mission-text wildcards as chips.
struct TokenText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(StoryTokens.attributed(text)) }
}

// MARK: - Small shared components

/// A static tinted capsule: optional icon + text.
struct StoryPill: View {
    let text: String
    let tint: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            if !text.isEmpty { Text(text).novaFont(.caption, weight: .bold).lineLimit(1) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.16)))
    }
}

/// A capsule progress bar (track + rounded fill).
struct StoryCapsuleBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if fraction > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
        }
        .frame(height: height)
    }
}

/// A circular progress ring with the percentage (or a check) in the middle.
struct StoryProgressRing: View {
    let fraction: Double
    let tint: Color
    let complete: Bool
    var thickness: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.10), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(tint, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if complete {
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(tint)
            } else {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(EVTheme.text)
            }
        }
        .padding(thickness / 2)
    }
}

/// A soft pulsing halo behind the "you are here" node.
struct StoryPulseHalo: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(pulse ? 0.10 : 0.26))
                .frame(width: pulse ? 38 : 30, height: pulse ? 38 : 30)
            Circle().strokeBorder(tint.opacity(0.9), lineWidth: 2).frame(width: 30, height: 30)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
