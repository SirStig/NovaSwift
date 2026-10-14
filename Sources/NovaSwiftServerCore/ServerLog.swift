import Foundation

/// Console + file + in-memory ring buffer (what the panel's Logs page tails).
public final class ServerLog {
    public enum Level: String { case info, warn, error }

    public struct Line: Equatable {
        public var seq: Int
        public var time: Date
        public var level: Level
        public var text: String
    }

    private let lock = NSLock()
    private var lines: [Line] = []
    private var nextSeq = 1
    private let capacity = 2000
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var fileBytes = 0
    public var echoToConsole = true
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    public init() {}

    public func attachFile(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        fileURL = url
        openFileLocked()
    }

    private func openFileLocked() {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileBytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        _ = try? fileHandle?.seekToEnd()
    }

    public func info(_ s: String) { add(.info, s) }
    public func warn(_ s: String) { add(.warn, s) }
    public func error(_ s: String) { add(.error, s) }

    public func add(_ level: Level, _ text: String) {
        lock.lock()
        let line = Line(seq: nextSeq, time: Date(), level: level, text: text)
        nextSeq += 1
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        let formatted = Self.format(line)
        if let fh = fileHandle {
            let data = Data((formatted + "\n").utf8)
            try? fh.write(contentsOf: data)
            fileBytes += data.count
            if fileBytes > 2_000_000, let url = fileURL { rotateLocked(url) }
        }
        let echo = echoToConsole
        lock.unlock()
        if echo { FileHandle.standardOutput.write(Data((formatted + "\n").utf8)) }
    }

    private func rotateLocked(_ url: URL) {
        try? fileHandle?.close(); fileHandle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        openFileLocked()
    }

    /// Lines with `seq > after`, at most `limit` (newest).
    public func lines(after: Int = 0, limit: Int = 500) -> [Line] {
        lock.lock(); defer { lock.unlock() }
        let out = lines.filter { $0.seq > after }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }

    public static func format(_ l: Line) -> String {
        let tag = l.level == .info ? "" : (l.level == .warn ? "WARN  " : "ERROR ")
        return "[\(stamp.string(from: l.time))] \(tag)\(l.text)"
    }
}
