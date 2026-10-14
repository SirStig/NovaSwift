import Foundation
import NovaSwiftNet

/// Append-only record of what administrators did (panel and console): who, what, from where. `logs/audit.log`,
/// rotated at 1 MB. Never records passwords or other secrets.
public final class AuditLog {
    public struct Entry: Equatable {
        public var time: Date
        public var actor: String
        public var action: String
        public var detail: String
    }

    private let lock = NSLock()
    private var recent: [Entry] = []
    private var handle: FileHandle?
    private var url: URL?
    private var bytes = 0

    public init(file: URL? = nil) {
        guard let file else { return }
        url = file
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        #if !os(Windows)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        bytes = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
    }

    /// Strip anything that could forge a second log line.
    static func clean(_ s: String, _ limit: Int) -> String {
        String(String(String.UnicodeScalarView(s.unicodeScalars.filter { !CrossPlayProtocol.isInvisibleScalar($0) })).prefix(limit))
    }

    public func record(actor: String, _ action: String, _ detail: String = "") {
        let e = Entry(time: Date(), actor: Self.clean(actor, 64), action: Self.clean(action, 48), detail: Self.clean(detail, 300))
        lock.lock(); defer { lock.unlock() }
        recent.append(e)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        guard let handle else { return }
        let f = ISO8601DateFormatter()
        let line = Data("\(f.string(from: e.time)) \(e.actor) \(e.action) \(e.detail)\n".utf8)
        try? handle.write(contentsOf: line)
        bytes += line.count
        if bytes > 1_000_000, let url {
            try? handle.close(); self.handle = nil
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: url); bytes = 0
        }
    }

    public func entries(limit: Int = 200) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(recent.suffix(limit))
    }
}

/// Chat vetting and vote-kick bookkeeping for the dedicated server. Pure state + decisions (no sockets), so it is unit
/// tested directly; `GameServer` applies the outcomes. Not thread-safe: use on the server's core queue.
public final class ModerationCenter {
    public struct Config: Equatable {
        public var voteKick = true
        public var voteKickPercent = 51
        public var wordFilter: [String] = []
        public var mutes: [String: String] = [:]
    }

    public enum Outcome: Equatable {
        case nothing
        /// Send this private line to the player who typed the command.
        case reply(String)
        /// A vote passed: remove `target`.
        case kick(target: Int, reason: String)
        /// A report was filed (already logged); `reply` thanks the reporter.
        case report(target: Int, reason: String, detail: String, reply: String)
    }

    public var config = Config()
    private var votes: [Int: (voters: Set<Int>, started: Double)] = [:]
    private var lastVoteStart: [Int: Double] = [:]
    private var recentLines: [Int: [(text: String, at: Double)]] = [:]
    private var reports: [Int: [(reporter: Int, at: Double)]] = [:]
    private var invalidReports: [Int: Int] = [:]
    public static let voteWindow = 60.0

    public init() {}

    // MARK: Mutes

    public func isMuted(id: Int, name: String, ip: String) -> Bool {
        config.mutes["ip:\(ip)"] != nil || config.mutes["name:\(name.lowercased())"] != nil
    }

    // MARK: Chat vetting

    /// Final check of a chat line: word filter and duplicate-spam. nil = drop it.
    public func vet(id: Int, text: String, now: Double) -> String? {
        var list = (recentLines[id] ?? []).filter { now - $0.at < 10 }
        if list.filter({ $0.text == text }).count >= 2 { recentLines[id] = list; return nil }
        list.append((text, now))
        recentLines[id] = list
        return Self.filtered(text, words: config.wordFilter)
    }

    public static func filtered(_ text: String, words: [String]) -> String {
        guard !words.isEmpty else { return text }
        var out = text
        for w in words where !w.isEmpty {
            var from = out.startIndex
            while from < out.endIndex, let r = out.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: from..<out.endIndex) {
                let start = out.distance(from: out.startIndex, to: r.lowerBound)
                let n = max(1, out.distance(from: r.lowerBound, to: r.upperBound))
                out.replaceSubrange(r, with: String(repeating: "*", count: n))
                from = out.index(out.startIndex, offsetBy: start + n)
            }
        }
        return out
    }

    // MARK: Commands

    public static let helpText = "Commands: /votekick <player>, /report <player> [why], /votes, /help"

    /// Handle "/command args" typed by `from`. `players` = current (id, name) roster.
    public func command(_ text: String, from: Int, players: [(id: Int, name: String)], now: Double) -> Outcome {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return .reply(Self.helpText) }
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        expireVotes(now: now)
        switch cmd {
        case "help", "?": return .reply(Self.helpText)
        case "votes":
            if votes.isEmpty { return .reply("No vote in progress.") }
            let lines = votes.map { t, v -> String in
                let n = players.first { $0.id == t }?.name ?? "#\(t)"
                return "Vote to remove \(n): \(v.voters.count)/\(needed(players.count)) (\(Int(max(0, Self.voteWindow - (now - v.started)))) s left)"
            }
            return .reply(lines.joined(separator: " | "))
        case "votekick":
            guard config.voteKick else { return .reply("Vote-kick is switched off on this server.") }
            guard players.count >= 3 else { return .reply("Vote-kick needs at least 3 players online.") }
            guard let target = Self.resolve(arg, players: players) else { return .reply("No player matches \"\(arg)\". Use their name or id.") }
            guard target.id != from else { return .reply("You can't vote against yourself.") }
            var v = votes[target.id] ?? (Set<Int>(), now)
            if votes[target.id] == nil {
                if let last = lastVoteStart[from], now - last < 120 { return .reply("Wait a couple of minutes before starting another vote.") }
                lastVoteStart[from] = now
            }
            if v.voters.contains(from) { return .reply("You already voted (\(v.voters.count)/\(needed(players.count)))." ) }
            v.voters.insert(from)
            votes[target.id] = v
            if v.voters.count >= needed(players.count) {
                votes[target.id] = nil
                return .kick(target: target.id, reason: "Removed by a vote of the other players.")
            }
            return .reply("Vote to remove \(target.name): \(v.voters.count)/\(needed(players.count)). Others type /votekick \(target.name) to agree.")
        case "report":
            let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = words.first, let target = Self.resolve(key, players: players) else { return .reply("Usage: /report <player> [why]") }
            guard target.id != from else { return .reply("You can't report yourself.") }
            var list = (reports[target.id] ?? []).filter { now - $0.at < 60 }
            if list.contains(where: { $0.reporter == from }) { return .reply("You already reported \(target.name).") }
            list.append((from, now))
            reports[target.id] = list
            let detail = words.count > 1 ? String(words[1].prefix(120)) : ""
            return .report(target: target.id, reason: "player report", detail: detail, reply: "Thanks, \(target.name) was reported to the server admin.")
        default:
            return .reply("Unknown command. " + Self.helpText)
        }
    }

    /// Votes needed to remove somebody.
    public func needed(_ online: Int) -> Int {
        max(2, Int((Double(online) * Double(config.voteKickPercent) / 100.0).rounded(.up)))
    }

    private func expireVotes(now: Double) {
        votes = votes.filter { now - $0.value.started < Self.voteWindow }
    }

    public func forget(id: Int) {
        votes[id] = nil; recentLines[id] = nil; reports[id] = nil; invalidReports[id] = nil
        for (t, var v) in votes where v.voters.contains(id) { v.voters.remove(id); votes[t] = v }
    }

    /// Distinct reporters of `target` in the last minute (reports from the panel's players count once each).
    public func reportCount(target: Int, now: Double) -> Int {
        Set((reports[target] ?? []).filter { now - $0.at < 60 }.map(\.reporter)).count
    }

    /// A client noticed invalid data from `target`; true once five such reports have piled up.
    public func noteInvalidReport(target: Int) -> Bool {
        invalidReports[target, default: 0] += 1
        return invalidReports[target]! >= 5
    }

    /// Record a non-command report (K_REPORT control packet); returns the number of distinct reporters in the last minute.
    public func noteReport(target: Int, reporter: Int, now: Double) -> Int {
        var list = (reports[target] ?? []).filter { now - $0.at < 60 }
        if !list.contains(where: { $0.reporter == reporter }) { list.append((reporter, now)) }
        reports[target] = list
        return Set(list.map(\.reporter)).count
    }

    static func resolve(_ key: String, players: [(id: Int, name: String)]) -> (id: Int, name: String)? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        if let n = Int(k), let p = players.first(where: { $0.id == n }) { return p }
        return players.first { $0.name.lowercased() == k } ?? players.first { $0.name.lowercased().hasPrefix(k) }
    }
}

/// Inspects the game bytes a client relays to others (a JSON `NetMessage`, whose first key names the case) so a
/// malicious client cannot speak as someone else, announce another player's presence, or issue host-only messages.
/// Everything else passes through untouched; the receivers validate it again.
public final class RelayInspector {
    public struct Context {
        public var name: String
        public var ip: String
    }
    /// Roster lookup (core queue).
    public var context: (Int) -> Context? = { _ in nil }
    /// Chat from the relay path, already cleaned: return the final text or nil to drop it.
    public var chat: (Int, Context, String) -> String? = { _, _, t in t }
    /// A "/command" typed as chat.
    public var command: (Int, Context, String) -> Void = { _, _, _ in }
    /// Something forbidden was sent (for the abuse counters).
    public var violation: (Int, String) -> Void = { _, _ in }

    public init() {}

    public func inspect(from id: Int, payload: [UInt8]) -> [UInt8]? {
        guard payload.count > 4, payload.count <= NetLimits.maxData, payload[0] == UInt8(ascii: "{"), payload[1] == UInt8(ascii: "\"") else {
            violation(id, "sent a malformed message"); return nil
        }
        // The key of the single-entry object, e.g. {"chat":{...}} / {"presenceRequest":{}}
        guard let end = payload[2...min(payload.count - 1, 40)].firstIndex(of: UInt8(ascii: "\"")) else {
            violation(id, "sent a malformed message"); return nil
        }
        let key = String(decoding: payload[2..<end], as: UTF8.self)
        switch key {
        case "snapshot", "input", "ncb", "trade", "presenceRequest", "pluginManifest":
            return payload
        case "presence":
            guard let ctx = context(id), case .presence(var p)? = try? NetCodec.decode(Data(payload)) else {
                violation(id, "sent a malformed message"); return nil
            }
            if p.playerID != String(id) { violation(id, "announced another player"); return nil }
            p.name = ctx.name                  // the server knows the real (sanitised, unique) name
            guard NetValidation.valid(p), let out = try? NetCodec.encode(.presence(p)) else {
                violation(id, "sent an invalid presence"); return nil
            }
            return [UInt8](out)
        case "chat":
            guard let ctx = context(id), case .chat(let m)? = try? NetCodec.decode(Data(payload)) else {
                violation(id, "sent a malformed message"); return nil
            }
            if m.playerID != String(id) { violation(id, "chatted as another player"); return nil }
            let text = CrossPlayProtocol.cleanChat(m.text)
            guard !text.isEmpty else { return nil }
            if text.hasPrefix("/") { command(id, ctx, text); return nil }
            guard let final = chat(id, ctx, text) else { return nil }
            let msg = ChatMessage(playerID: String(id), senderName: ctx.name, text: final)
            return (try? NetCodec.encode(.chat(msg))).map { [UInt8]($0) }
        default:
            // "sessionRules" and "kick" are the server's alone; anything else is not a message this protocol has.
            violation(id, "sent a host-only or unknown message (\(key.prefix(16)))")
            return nil
        }
    }
}
