import XCTest
import Foundation
import NovaSwiftKit
@testable import NovaSwiftServerCore

enum TestSupport {
    static var nextPort = 55200

    static func tempRoot(_ name: String = #function) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("nss-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Two free-ish ports in a private range (game + query).
    static func ports() -> (game: Int, admin: Int) { nextPort += 4; return (nextPort, nextPort + 2) }

    /// Write `plugins/<id>/<id>.rez` with the given resources.
    @discardableResult
    static func makePlugin(_ id: String, in pluginsDir: URL, resources: [(type: String, id: Int, bytes: [UInt8])]) throws -> URL {
        var col = ResourceCollection()
        for r in resources {
            col.add(Resource(type: FourCharCode(r.type)!, id: r.id, name: "r\(r.id)", data: Data(r.bytes)))
        }
        let dir = pluginsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RezWriter.write(col).write(to: dir.appendingPathComponent("\(id).rez"))
        return dir
    }

    struct Rig {
        let root: URL
        let paths: ServerPaths
        let store: ConfigStore
        let log: ServerLog
        let plugins: PluginManager
        let server: GameServer
        let admin: AdminService
    }

    static func rig(configure: (inout ServerConfig) -> Void = { _ in }) throws -> Rig {
        let root = tempRoot()
        let paths = ServerPaths(root: root)
        let store = try ConfigStore(paths: paths)
        let p = ports()
        try store.update { $0.port = p.game; $0.adminPort = p.admin; $0.name = "Test Server"; $0.adminPasswordHash = AdminPassword.hash("hunter22hunter") }
        try store.update(configure)
        let log = ServerLog(); log.echoToConsole = false
        let plugins = PluginManager(paths: paths, log: log)
        let server = GameServer(store: store, log: log, plugins: plugins)
        let admin = AdminService(server: server, updates: UpdateChecker(log: log))
        return Rig(root: root, paths: paths, store: store, log: log, plugins: plugins, server: server, admin: admin)
    }
}
