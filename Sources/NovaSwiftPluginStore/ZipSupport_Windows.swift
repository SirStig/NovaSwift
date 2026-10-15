#if os(Windows)
import Foundation

// ZIPFoundation links a system zlib and doesn't build on Windows, so Windows uses the bsdtar that ships in
// System32 (tar.exe reads and writes .zip). Same call shapes as ZIPFoundation's FileManager extensions.

enum WindowsTar {
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:/Windows") + "/System32/tar.exe")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Drain both pipes before waiting so a large listing can't fill the buffer and stall tar.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "NovaSwift.tar", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self)])
        }
        return String(decoding: outData, as: UTF8.self)
    }
}

enum ZipCompressionMethod { case none, deflate }

extension FileManager {
    func unzipItem(at archive: URL, to destination: URL) throws {
        _ = try WindowsTar.run(["-xf", archive.path, "-C", destination.path])
    }

    func zipItem(at directory: URL, to archive: URL, shouldKeepParent: Bool, compressionMethod: ZipCompressionMethod) throws {
        _ = try WindowsTar.run(["-a", "-cf", archive.path, "-C", directory.path, "."])
    }
}

extension PluginInstaller {
    static func validateZipWindows(at url: URL) throws {
        guard let listing = try? WindowsTar.run(["-tvf", url.path]) else { throw PluginInstallError.unsupportedArchive }
        var count = 0
        var total: UInt64 = 0
        for line in listing.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            // "-rw-rw-rw-  0 0 0  1234 Jan  1  2020 dir/file": mode, links, uid, gid, size, date (3 fields), path.
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9 else { continue }
            let path = f[8...].joined(separator: " ")
            count += 1
            total &+= UInt64(f[4]) ?? 0
            let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            if path.hasPrefix("/") || path.hasPrefix("\\") || parts.contains("..") || path.contains("\0")
                || (path.count >= 2 && path.dropFirst().first == ":") {
                throw PluginInstallError.unsafeArchive("it contains a path that leaves the plug-in folder (\(path.prefix(60))).")
            }
            if line.hasPrefix("l") { throw PluginInstallError.unsafeArchive("it contains a symbolic link.") }
            if count > maxZipEntries { throw PluginInstallError.unsafeArchive("it contains too many files.") }
            if total > maxZipUncompressed { throw PluginInstallError.unsafeArchive("it would unpack to more than \(maxZipUncompressed >> 30) GB.") }
        }
    }
}
#endif
