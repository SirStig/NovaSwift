import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads catalog artwork once and keeps it: in memory for the session and
/// on disk between launches. Concurrent requests for one URL share a download.
public actor RemoteImageCache {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let shared = RemoteImageCache()

    private let directory: URL
    private let fetch: Fetch
    private var memory: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public init(directory: URL? = nil, fetch: @escaping Fetch = RemoteImageCache.defaultFetch) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NovaSwift/PluginImages", isDirectory: true)
        self.fetch = fetch
    }

    public static let defaultFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PluginCatalogError.badStatus(http.statusCode)
        }
        return data
    }

    private func diskFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    public func data(for url: URL) async throws -> Data {
        if let hit = memory[url] { return hit }
        let file = diskFile(for: url)
        if let disk = try? Data(contentsOf: file), !disk.isEmpty {
            memory[url] = disk
            return disk
        }
        if let task = inFlight[url] { return try await task.value }
        let fetch = self.fetch
        let task = Task<Data, Error> { try await fetch(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        memory[url] = data
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    public func removeAll() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
