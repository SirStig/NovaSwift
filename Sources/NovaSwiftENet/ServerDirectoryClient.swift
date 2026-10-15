import Foundation
import NovaSwiftNet
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads and caches the community server list (`servers/servers.json` in SirStig/NovaSwift-Plugins),
/// the same file the Godot build reads (`godot/net/ServerDirectory.gd`): HTTPS only, cached with its `ETag`,
/// refreshed at most every 24 h (a revalidation answered `304` just renews the timestamp), and the cached copy is
/// shown when offline. The file is only a list of addresses; everything live comes from `ServerStatusQuery`.
public final class ServerDirectoryClient {
    public enum Status: Equatable, Sendable {
        case idle
        case loading
        case ok            // fresh from the network (or revalidated)
        case cached        // within the 24 h window, not re-fetched
        case offline(String)  // fetch failed, showing the saved copy
        case failed(String)   // fetch failed and nothing cached
    }

    public typealias Fetcher = (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void

    public static let maxAge: TimeInterval = 24 * 3600

    public let url: URL
    public private(set) var servers: [DirectoryServer] = []
    public private(set) var status: Status = .idle
    public private(set) var fetchedAt: Date?

    private let cacheURL: URL?
    private let fetch: Fetcher
    private var etag = ""
    private var body = Data()
    private var loading = false
    private let now: () -> Date

    public init(url: URL = CrossPlayProtocol.directoryURL, cacheURL: URL? = ServerDirectoryClient.defaultCacheURL,
                fetcher: Fetcher? = nil, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.cacheURL = cacheURL
        self.now = now
        self.fetch = fetcher ?? { req, done in
            var req = req
            req.timeoutInterval = 12
            Self.session.dataTask(with: req) { d, r, e in done(d, r as? HTTPURLResponse, e) }.resume()
        }
        loadCache()
    }

    /// Shared, never deallocated: a per-request URLSession can abort the process on Linux when it is freed
    /// ("_MultiHandle deallocated with non-zero retain count", swift-corelibs-foundation).
    private static let session = URLSession(configuration: .ephemeral)

    public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("novaswift_server_directory.json")
    }

    /// Load from cache and fetch when stale (or `force`). `completion` runs on whatever thread URLSession uses.
    public func refresh(force: Bool = false, completion: @escaping (Status, [DirectoryServer]) -> Void) {
        let age = fetchedAt.map { now().timeIntervalSince($0) } ?? .infinity
        if !force, age < Self.maxAge, !servers.isEmpty {
            status = .cached
            return completion(status, servers)
        }
        guard url.scheme == "https" else {
            status = .failed("The directory address must be https.")
            return completion(status, servers)
        }
        guard !loading else { return }
        loading = true
        status = .loading
        var req = URLRequest(url: url)
        req.setValue("NovaSwift", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !etag.isEmpty, !servers.isEmpty { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        fetch(req) { [self] data, resp, error in
            loading = false
            guard error == nil, let resp else { return fail("Couldn't reach the server directory.", completion) }
            if resp.statusCode == 304 {
                fetchedAt = now(); saveCache(); status = .ok
                return completion(status, servers)
            }
            guard resp.statusCode == 200, let data else { return fail("The server directory answered HTTP \(resp.statusCode).", completion) }
            switch ServerDirectory.parse(data) {
            case .failure(let e):
                return fail("The server directory is malformed (\(e)).", completion)
            case .success(let list):
                servers = list
                body = data
                etag = (resp.value(forHTTPHeaderField: "ETag")) ?? ""
                fetchedAt = now()
                saveCache()
                status = .ok
                completion(status, servers)
            }
        }
    }

    private func fail(_ msg: String, _ completion: (Status, [DirectoryServer]) -> Void) {
        status = servers.isEmpty ? .failed(msg) : .offline(msg + " Showing the saved copy.")
        completion(status, servers)
    }

    // MARK: Cache

    private struct CacheFile: Codable { var etag: String; var fetchedAt: Double; var body: String }

    private func loadCache() {
        guard let cacheURL, let d = try? Data(contentsOf: cacheURL), let f = try? JSONDecoder().decode(CacheFile.self, from: d),
              case .success(let list) = ServerDirectory.parse(Data(f.body.utf8)) else { return }
        servers = list; body = Data(f.body.utf8); etag = f.etag
        fetchedAt = Date(timeIntervalSince1970: f.fetchedAt)
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let f = CacheFile(etag: etag, fetchedAt: (fetchedAt ?? now()).timeIntervalSince1970, body: String(decoding: body, as: UTF8.self))
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: cacheURL, options: .atomic) }
    }
}
