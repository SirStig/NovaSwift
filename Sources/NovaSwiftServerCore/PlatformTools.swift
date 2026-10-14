import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Small OS helpers: run a program, open the browser, start-with-the-computer, self-update.
public enum PlatformTools {

    public static var platformName: String {
        #if os(macOS)
        return "macos"
        #elseif os(Windows)
        return "windows"
        #else
        return "linux"
        #endif
    }

    public static var archName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// `NovaSwiftServer-linux-x86_64.tar.gz` etc.
    public static var releaseAssetName: String {
        let ext = platformName == "linux" ? "tar.gz" : "zip"
        return "NovaSwiftServer-\(platformName)-\(archName).\(ext)"
    }

    public static var executableURL: URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "NovaSwiftServer").resolvingSymlinksInPath().standardizedFileURL
    }

    /// Running under systemd / Docker / launchd: something will restart the program if it exits.
    public static var isSupervised: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["INVOCATION_ID"] != nil || env["NOVASWIFT_SUPERVISED"] == "1" || FileManager.default.fileExists(atPath: "/.dockerenv")
    }

    public static var hasDesktop: Bool {
        #if os(macOS) || os(Windows)
        return true
        #else
        let env = ProcessInfo.processInfo.environment
        return (env["DISPLAY"] ?? "").isEmpty == false || (env["WAYLAND_DISPLAY"] ?? "").isEmpty == false
        #endif
    }

    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()
        let reader = DispatchQueue(label: "run.reader")
        let group = DispatchGroup()
        group.enter()
        reader.async { out = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        _ = group.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    static func which(_ tool: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: Browser

    @discardableResult
    public static func openBrowser(_ url: String) -> Bool {
        #if os(macOS)
        return run("/usr/bin/open", [url]).status == 0
        #elseif os(Windows)
        return run("C:\\Windows\\System32\\cmd.exe", ["/c", "start", "", url]).status == 0
        #else
        guard hasDesktop, let x = which("xdg-open") else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: x); p.arguments = [url]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil
        #endif
    }

    // MARK: Start with the computer

    public struct AutostartStatus: Equatable {
        public var supported: Bool
        public var enabled: Bool
        public var method: String
        public var note: String
    }

    public static func autostartStatus(paths: ServerPaths) -> AutostartStatus {
        #if os(macOS)
        let plist = launchAgentURL()
        return AutostartStatus(supported: true, enabled: FileManager.default.fileExists(atPath: plist.path),
                               method: "launchd", note: "Starts when you log in to this Mac.")
        #elseif os(Windows)
        let r = run("C:\\Windows\\System32\\schtasks.exe", ["/Query", "/TN", "NovaSwift Server"])
        return AutostartStatus(supported: true, enabled: r.status == 0, method: "Scheduled task", note: "Starts when you sign in to Windows.")
        #else
        if FileManager.default.fileExists(atPath: "/etc/systemd/system/novaswift-server.service") {
            return AutostartStatus(supported: false, enabled: true, method: "systemd",
                                   note: "Installed as a system service: it already starts on boot and restarts if it stops.")
        }
        let unit = systemdUserUnitURL()
        return AutostartStatus(supported: which("systemctl") != nil, enabled: FileManager.default.fileExists(atPath: unit.path),
                               method: "systemd (user)", note: "Starts when you log in. For a server that should always run, use the Linux install script instead.")
        #endif
    }

    @discardableResult
    public static func setAutostart(_ on: Bool, paths: ServerPaths) -> (ok: Bool, message: String) {
        let exe = executableURL.path
        #if os(macOS)
        let plist = launchAgentURL()
        if on {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.novaswift.server</string>
              <key>ProgramArguments</key><array><string>\(exe)</string><string>--no-browser</string><string>--no-stdin</string><string>--data</string><string>\(paths.root.path)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
              <key>StandardOutPath</key><string>\(paths.logsDir.path)/launchd.out.log</string>
              <key>StandardErrorPath</key><string>\(paths.logsDir.path)/launchd.err.log</string>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try xml.write(to: plist, atomically: true, encoding: .utf8) } catch { return (false, "Couldn't write \(plist.path): \(error.localizedDescription)") }
            // Not loaded now: this very process is already running; it starts at the next login.
            return (true, "The server will start automatically when you log in.")
        } else {
            _ = run("/bin/launchctl", ["unload", plist.path])
            try? FileManager.default.removeItem(at: plist)
            return (true, "The server will no longer start automatically.")
        }
        #elseif os(Windows)
        if on {
            let r = run("C:\\Windows\\System32\\schtasks.exe", ["/Create", "/TN", "NovaSwift Server", "/TR", "\"\(exe)\" --no-browser --data \"\(paths.root.path)\"", "/SC", "ONLOGON", "/RL", "LIMITED", "/F"])
            return r.status == 0 ? (true, "The server will start when you sign in to Windows.") : (false, "Windows refused to create the startup task: \(r.output)")
        } else {
            let r = run("C:\\Windows\\System32\\schtasks.exe", ["/Delete", "/TN", "NovaSwift Server", "/F"])
            return r.status == 0 ? (true, "The server will no longer start automatically.") : (false, r.output)
        }
        #else
        if FileManager.default.fileExists(atPath: "/etc/systemd/system/novaswift-server.service") {
            return (false, "This server is installed as a system service and already starts on boot.")
        }
        guard let sc = which("systemctl") else { return (false, "systemd isn't available here. Add the server to your init system or cron @reboot.") }
        let unit = systemdUserUnitURL()
        if on {
            let text = """
            [Unit]
            Description=NovaSwift Dedicated Server
            After=network-online.target

            [Service]
            ExecStart=\(exe) --no-browser --no-stdin --data \(paths.root.path)
            Restart=always
            RestartSec=5

            [Install]
            WantedBy=default.target
            """
            try? FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try text.write(to: unit, atomically: true, encoding: .utf8) } catch { return (false, "Couldn't write \(unit.path): \(error.localizedDescription)") }
            _ = run(sc, ["--user", "daemon-reload"])
            let r = run(sc, ["--user", "enable", "novaswift-server.service"])
            return r.status == 0 ? (true, "The server will start when you log in.") : (false, "systemd said: \(r.output)")
        } else {
            _ = run(sc, ["--user", "disable", "novaswift-server.service"])
            try? FileManager.default.removeItem(at: unit)
            return (true, "The server will no longer start automatically.")
        }
        #endif
    }

    static func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.novaswift.server.plist")
    }
    static func systemdUserUnitURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/systemd/user/novaswift-server.service")
    }
}

// MARK: - Updates

/// Looks for newer server releases on GitHub (tags `server-v<version>`) and, only if the admin asks (or opted in to
/// automatic updates), replaces the program file. Nothing is ever downloaded without a visible setting or click.
public final class UpdateChecker {
    public struct Info: Equatable {
        public var current: String
        public var latest: String?
        public var available: Bool
        public var pageURL: String
        public var assetURL: String?
        public var notes: String
        public var checkedAt: Date?
        public var error: String?
    }

    private let lock = NSLock()
    private var info: Info
    private let log: ServerLog
    var fetch: (URL) -> Data? = { NetworkTools.httpGet($0, timeout: 8, headers: ["Accept": "application/vnd.github+json"]) }

    public init(log: ServerLog) {
        self.log = log
        info = Info(current: ServerVersion.current, latest: nil, available: false,
                    pageURL: ServerVersion.releasesPage.absoluteString, assetURL: nil, notes: "", checkedAt: nil, error: nil)
    }

    public var current: Info { lock.lock(); defer { lock.unlock() }; return info }

    /// Numeric dotted compare: "0.10.0" > "0.9.2".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    @discardableResult
    public func check() -> Info {
        var next = current
        next.checkedAt = Date()
        guard let data = fetch(ServerVersion.releasesAPI),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            next.error = "Couldn't check for updates (no internet connection, or GitHub is busy)."
            set(next); return next
        }
        next.error = nil
        let releases = list.compactMap { r -> (version: String, release: [String: Any])? in
            guard let tag = r["tag_name"] as? String, tag.hasPrefix(ServerVersion.tagPrefix), (r["draft"] as? Bool) != true else { return nil }
            return (String(tag.dropFirst(ServerVersion.tagPrefix.count)), r)
        }
        guard let best = releases.max(by: { !Self.isNewer($0.version, than: $1.version) && $0.version != $1.version }) else {
            next.latest = nil; next.available = false; set(next); return next
        }
        next.latest = best.version
        next.available = Self.isNewer(best.version, than: ServerVersion.current)
        next.pageURL = (best.release["html_url"] as? String) ?? ServerVersion.releasesPage.absoluteString
        next.notes = String(((best.release["body"] as? String) ?? "").prefix(1500))
        let assets = (best.release["assets"] as? [[String: Any]]) ?? []
        next.assetURL = assets.first { ($0["name"] as? String) == PlatformTools.releaseAssetName }?["browser_download_url"] as? String
        set(next)
        if next.available { log.info("A new server version is available: \(best.version) (you have \(ServerVersion.current)).") }
        return next
    }

    private func set(_ i: Info) { lock.lock(); info = i; lock.unlock() }

    /// Download the release for this platform and replace the program file. The new version runs after a restart.
    public func apply() -> (ok: Bool, message: String) {
        let i = current
        guard i.available, let asset = i.assetURL, let url = URL(string: asset), url.scheme == "https" else {
            return (false, "There's no update file for this system in the latest release. Download it from the releases page.")
        }
        guard let data = NetworkTools.httpGet(url, timeout: 120) else { return (false, "The download failed. Try again, or download it from the releases page.") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("novaswift-update-\(UUID().uuidString)")
        let archive = tmp.appendingPathComponent(PlatformTools.releaseAssetName)
        let stage = tmp.appendingPathComponent("stage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try data.write(to: archive)
        } catch { return (false, "Couldn't save the download: \(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ok: Bool
        if archive.pathExtension == "gz" { ok = PlatformTools.run("/usr/bin/env", ["tar", "-xzf", archive.path, "-C", stage.path], timeout: 60).status == 0 }
        else if PlatformTools.platformName == "windows" { ok = PlatformTools.run("C:\\Windows\\System32\\tar.exe", ["-xf", archive.path, "-C", stage.path], timeout: 60).status == 0 }
        else { ok = PlatformTools.run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", stage.path], timeout: 60).status == 0 }
        guard ok else { return (false, "The downloaded file couldn't be unpacked.") }
        let binaryName = PlatformTools.platformName == "windows" ? "NovaSwiftServer.exe" : "NovaSwiftServer"
        var found: URL?
        if let en = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.lastPathComponent == binaryName { found = u; break }
        }
        guard let newBinary = found else { return (false, "The update didn't contain the server program.") }
        let exe = PlatformTools.executableURL
        let staged = exe.appendingPathExtension("new")
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: newBinary, to: staged)
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            _ = try FileManager.default.replaceItemAt(exe, withItemAt: staged)
            #else
            let old = exe.appendingPathExtension("old")
            try? FileManager.default.removeItem(at: old)
            try FileManager.default.moveItem(at: exe, to: old)
            try FileManager.default.moveItem(at: staged, to: exe)
            #endif
        } catch {
            return (false, "Couldn't replace the program file (\(error.localizedDescription)). Download the update by hand.")
        }
        log.info("Updated the server program to \(i.latest ?? "?"). Restart the server to run it.")
        return (true, "Updated to \(i.latest ?? "the new version"). Restart the server to start using it.")
    }
}
