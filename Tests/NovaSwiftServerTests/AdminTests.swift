import XCTest
import Foundation
@testable import NovaSwiftServerCore

final class AdminTests: XCTestCase {
    func req(_ method: String, _ path: String, body: [String: Any]? = nil, cookie: String? = nil, admin: Bool = true, ip: String = "127.0.0.1", query: [String: String] = [:]) -> HTTPRequest {
        var h: [String: String] = [:]
        if admin { h["x-ns-admin"] = "1" }
        if let cookie { h["cookie"] = "nsadmin=\(cookie)" }
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPRequest(method: method, path: path, query: query, headers: h, body: data, remoteIP: ip)
    }
    func json(_ r: HTTPResponse) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]) ?? [:] }
    func cookie(_ r: HTTPResponse) -> String? {
        r.headers["Set-Cookie"]?.split(separator: ";").first.map(String.init)?.replacingOccurrences(of: "nsadmin=", with: "")
    }
    func login(_ a: AdminService) -> String {
        let r = a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"]))
        XCTAssertEqual(r.status, 200)
        return cookie(r) ?? ""
    }

    func testStaticPagesAreServedWithoutLogin() throws {
        let a = try TestSupport.rig().admin
        for (path, type) in [("/", "text/html"), ("/app.js", "javascript"), ("/app.css", "text/css"), ("/favicon.svg", "svg")] {
            let r = a.handle(req("GET", path, admin: false))
            XCTAssertEqual(r.status, 200, path)
            XCTAssertTrue((r.headers["Content-Type"] ?? "").contains(type), path)
            XCTAssertGreaterThan(r.body.count, 100, path)
        }
        XCTAssertEqual(a.handle(req("GET", "/nope", admin: false)).status, 404)
        XCTAssertEqual(a.handle(req("GET", "/api/nope")).status, 401, "unknown API routes need a login too")
    }

    func testLoginRequiredAndWrongPasswordRejected() throws {
        let a = try TestSupport.rig().admin
        XCTAssertEqual(a.handle(req("GET", "/api/status")).status, 401)
        XCTAssertEqual(a.handle(req("GET", "/api/settings", cookie: "forged")).status, 401)
        let bad = a.handle(req("POST", "/api/login", body: ["password": "nope"]))
        XCTAssertEqual(bad.status, 401)
        XCTAssertTrue((json(bad)["error"] as? String ?? "").contains("password"))
        let c = login(a)
        XCTAssertFalse(c.isEmpty)
        let s = a.handle(req("GET", "/api/status", cookie: c))
        XCTAssertEqual(s.status, 200)
        XCTAssertEqual(json(s)["version"] as? String, ServerVersion.current)
        XCTAssertTrue(a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"])).headers["Set-Cookie"]!.contains("HttpOnly"))
    }

    func testCSRFHeaderRequiredForWrites() throws {
        let a = try TestSupport.rig().admin
        let c = login(a)
        XCTAssertEqual(a.handle(req("POST", "/api/settings", body: ["name": "X"], cookie: c, admin: false)).status, 403)
    }

    func testLoginLockoutAfterRepeatedFailures() throws {
        let a = try TestSupport.rig().admin
        for _ in 0..<5 { XCTAssertEqual(a.handle(req("POST", "/api/login", body: ["password": "x"], ip: "203.0.113.9")).status, 401) }
        let locked = a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"], ip: "203.0.113.9"))
        XCTAssertEqual(locked.status, 429)
        // Another address is unaffected.
        XCTAssertEqual(a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"], ip: "203.0.113.10")).status, 200)
    }

    func testSetupLinkOnlyWorksFromThisComputerAndOnlyBeforeSetupIsDone() throws {
        let r = try TestSupport.rig()
        let a = r.admin
        let code = try XCTUnwrap(a.setupCode)
        XCTAssertEqual(a.handle(req("POST", "/api/setup-login", body: ["code": code], ip: "198.51.100.4")).status, 401)
        XCTAssertEqual(a.handle(req("POST", "/api/setup-login", body: ["code": "wrong"])).status, 401)
        let ok = a.handle(req("POST", "/api/setup-login", body: ["code": code]))
        XCTAssertEqual(ok.status, 200)
        let c = try XCTUnwrap(cookie(ok))
        XCTAssertEqual(a.handle(req("POST", "/api/setup/complete", body: [:], cookie: c)).status, 200)
        XCTAssertTrue(r.store.config.setupDone)
        XCTAssertEqual(a.handle(req("POST", "/api/setup-login", body: ["code": code])).status, 401)
    }

    func testSettingsRoundTripValidationAndPersistence() throws {
        let r = try TestSupport.rig()
        let c = login(r.admin)
        var s = json(r.admin.handle(req("GET", "/api/settings", cookie: c)))
        XCTAssertEqual(s["name"] as? String, "Test Server")
        let save = r.admin.handle(req("POST", "/api/settings", body: ["name": "Renamed", "maxPlayers": 5, "rulesPreset": "full", "motd": "hi", "password": "pw1"], cookie: c))
        XCTAssertEqual(save.status, 200, String(decoding: save.body, as: UTF8.self))
        s = json(r.admin.handle(req("GET", "/api/settings", cookie: c)))
        XCTAssertEqual(s["name"] as? String, "Renamed"); XCTAssertEqual(s["maxPlayers"] as? Int, 5); XCTAssertEqual(s["rulesPreset"] as? String, "full")
        // Saved to disk
        let onDisk = ServerConfig.parse(try String(contentsOf: r.paths.configFile, encoding: .utf8)).config
        XCTAssertEqual(onDisk.name, "Renamed"); XCTAssertEqual(onDisk.password, "pw1")
        // Invalid values are refused in plain language and change nothing.
        let bad = r.admin.handle(req("POST", "/api/settings", body: ["port": 80], cookie: c))
        XCTAssertEqual(bad.status, 400)
        XCTAssertTrue((json(bad)["error"] as? String ?? "").contains("game port"))
        XCTAssertEqual(r.store.config.port, onDisk.port)
        let clash = r.admin.handle(req("POST", "/api/settings", body: ["adminPort": r.store.config.port + 1], cookie: c))
        XCTAssertEqual(clash.status, 400)
    }

    func testAdminPasswordChange() throws {
        let r = try TestSupport.rig()
        let c = login(r.admin)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/admin-password", body: ["current": "wrong", "new": "longenough1"], cookie: c)).status, 403)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/admin-password", body: ["current": "hunter22hunter", "new": "short"], cookie: c)).status, 400)
        let ok = r.admin.handle(req("POST", "/api/admin-password", body: ["current": "hunter22hunter", "new": "Brand-new-pass7"], cookie: c))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"])).status, 401)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/login", body: ["password": "Brand-new-pass7"])).status, 200)
        XCTAssertEqual(r.admin.handle(req("GET", "/api/status", cookie: c)).status, 401, "old sessions end")
    }

    func testPluginsPageListsEnabledAndHandlesUnknownIds() throws {
        let r = try TestSupport.rig()
        try TestSupport.makePlugin("mine", in: r.paths.pluginsDir, resources: [("shïp", 128, [1])])
        let c = login(r.admin)
        let on = r.admin.handle(req("POST", "/api/plugins/enable", body: ["id": "mine", "enabled": true], cookie: c))
        XCTAssertEqual(on.status, 200)
        let enabled = json(on)["enabled"] as? [[String: Any]]
        XCTAssertEqual(enabled?.first?["role"] as? String, "required")
        XCTAssertEqual(r.server.manifest.requirements.plugins.map(\.id), ["mine"])
        XCTAssertEqual(r.admin.handle(req("POST", "/api/plugins/install", body: ["id": "ghost"], cookie: c)).status, 404)
        let off = r.admin.handle(req("POST", "/api/plugins/enable", body: ["id": "mine", "enabled": false], cookie: c))
        XCTAssertEqual((json(off)["enabled"] as? [Any])?.count, 0)
    }

    func testPublicListingEntry() throws {
        let r = try TestSupport.rig { $0.publicAddress = "play.example.com"; $0.ownerName = "Jane"; $0.ownerContact = "j#1"; $0.region = "eu"; $0.description = "d"; $0.website = "https://x.example" }
        let c = login(r.admin)
        let p = json(r.admin.handle(req("GET", "/api/public", cookie: c)))
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((p["entry"] as? String ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(entry["host"] as? String, "play.example.com"); XCTAssertEqual(entry["port"] as? Int, r.store.config.port)
        XCTAssertEqual(entry["id"] as? String, "test-server"); XCTAssertEqual(entry["region"] as? String, "eu")
        XCTAssertEqual((entry["owner"] as? [String: String])?["name"], "Jane")
        XCTAssertNotNil(entry["added"])
        XCTAssertEqual(PublicListing.slug("Ünïcode!! Server  #1"), "n-code-server-1")
        XCTAssertTrue((p["editURL"] as? String ?? "").contains("NovaSwift-Plugins"))
    }

    func testBansAndLogs() throws {
        let r = try TestSupport.rig()
        let c = login(r.admin)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/bans/add", body: ["ip": "not-an-ip"], cookie: c)).status, 400)
        XCTAssertEqual(r.admin.handle(req("POST", "/api/bans/add", body: ["ip": "203.0.113.7", "note": "grief"], cookie: c)).status, 200)
        XCTAssertEqual(r.store.config.bans["203.0.113.7"], "grief")
        XCTAssertEqual((json(r.admin.handle(req("GET", "/api/bans", cookie: c)))["bans"] as? [Any])?.count, 1)
        r.admin.handle(req("POST", "/api/bans/remove", body: ["ip": "203.0.113.7"], cookie: c))
        XCTAssertTrue(r.store.config.bans.isEmpty)
        let logs = json(r.admin.handle(req("GET", "/api/logs", cookie: c, query: ["after": "0"])))
        XCTAssertGreaterThan((logs["lines"] as? [Any])?.count ?? 0, 0)
    }
}

final class HTTPServerTests: XCTestCase {
    func fetch(_ url: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) -> (Int, Data, HTTPURLResponse?) {
        var rq = URLRequest(url: URL(string: url)!); rq.httpMethod = method; rq.httpBody = body
        for (k, v) in headers { rq.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0); var out: (Int, Data, HTTPURLResponse?) = (0, Data(), nil)
        URLSession.shared.dataTask(with: rq) { d, r, _ in out = ((r as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data(), r as? HTTPURLResponse); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return out
    }

    func testRoutingBodiesAndLimitsOverRealSockets() throws {
        var seen: [HTTPRequest] = []
        let lock = NSLock()
        let srv = HTTPServer(bind: "127.0.0.1", port: 0) { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.path == "/big" { return .json(["bytes": req.bodyFile.flatMap { try? Data(contentsOf: $0).count } ?? req.body.count]) }
            return .json(["path": req.path, "q": req.query["a"] ?? "", "method": req.method])
        }
        srv.maxMemoryBody = 1000; srv.maxUploadBody = 50_000; srv.uploadPaths = ["/big"]; srv.tempDirectory = TestSupport.tempRoot()
        try srv.start(); defer { srv.stop() }
        let base = "http://127.0.0.1:\(srv.boundPort)"
        let (st, data, resp) = fetch(base + "/hello%20x?a=1%202&b=3")
        XCTAssertEqual(st, 200)
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(o?["path"] as? String, "/hello x"); XCTAssertEqual(o?["q"] as? String, "1 2")
        XCTAssertEqual(resp?.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        XCTAssertEqual(fetch(base + "/p", method: "POST", body: Data(repeating: 1, count: 500)).0, 200)
        XCTAssertEqual(fetch(base + "/p", method: "POST", body: Data(repeating: 1, count: 5000)).0, 413, "ordinary bodies are capped")
        let big = fetch(base + "/big", method: "POST", body: Data(repeating: 2, count: 20_000))
        XCTAssertEqual(big.0, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: big.1) as? [String: Any])?["bytes"] as? Int, 20_000, "large uploads are spooled to disk")
        XCTAssertEqual(fetch(base + "/big", method: "POST", body: Data(repeating: 2, count: 60_000)).0, 413)
        // spooled temp files are cleaned up
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: srv.tempDirectory.path))?.count ?? 0, 0)
    }

    func testPortInUseGivesAPlainError() throws {
        let a = HTTPServer(bind: "127.0.0.1", port: 0) { _ in .text("a") }
        try a.start(); defer { a.stop() }
        let b = HTTPServer(bind: "127.0.0.1", port: a.boundPort) { _ in .text("b") }
        XCTAssertThrowsError(try b.start()) { XCTAssertEqual($0 as? HTTPServer.StartError, .inUse(a.boundPort)) }
    }

    func testAdminPanelEndToEndOverHTTP() throws {
        let r = try TestSupport.rig()
        let srv = HTTPServer(bind: "127.0.0.1", port: 0) { r.admin.handle($0) }
        try srv.start(); defer { srv.stop() }
        let base = "http://127.0.0.1:\(srv.boundPort)"
        let page = fetch(base + "/")
        XCTAssertTrue(String(decoding: page.1, as: UTF8.self).contains("app.js"))
        let s = fetch(base + "/api/session", headers: ["X-NS-Admin": "1"])
        XCTAssertEqual(s.0, 200)
        XCTAssertEqual(fetch(base + "/api/status", headers: ["X-NS-Admin": "1"]).0, 401)
    }
}
