import Foundation
import Network

/// A tiny local-Wi-Fi upload server for platforms with no file picker —
/// tvOS first and foremost. While the Data Setup wizard's Apple TV import
/// step is on screen, this serves a one-page uploader at
/// `http://<device-ip>:8017/`; the player opens that address in any browser
/// on their Mac/PC/phone (same network) and drops their **Nova Files** in.
/// Each file is streamed straight into the destination directory (the app's
/// base-data folder), then the wizard reloads the game data.
///
/// Scope is deliberately tiny: two routes (GET the page, POST a file), one
/// request per connection (`Connection: close`), an allow-list of EV Nova
/// file extensions, and it only runs while the import screen is up.
@MainActor
final class WebImportServer: ObservableObject {
    /// Files received this session (last path components), newest last.
    @Published private(set) var receivedFiles: [String] = []
    @Published private(set) var isRunning = false
    /// Human-typeable address for the wizard to display, e.g.
    /// "http://192.168.1.23:8017" — nil until the listener is up or when no
    /// LAN address could be determined (then show the port + "your TV's IP").
    @Published private(set) var displayAddress: String?
    /// Fires after every completed upload so the owner can reload game data.
    var onFileReceived: () -> Void = {}

    /// Where uploads land. Set before `start()`.
    private var destinationDir: URL
    private var listener: NWListener?
    /// Strong refs to in-flight connections (dropped on close).
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    static let port: UInt16 = 8017

    /// Everything an EV Nova install legitimately ships that the importer
    /// knows what to do with (resource files, soundtrack, fonts, videos).
    private static let allowedExtensions: Set<String> = [
        "ndat", "rez", "mp3", "m4a", "aiff", "wav", "ttf", "otf", "mov", "mp4", "m4v",
    ]

    init(destinationDir: URL) {
        self.destinationDir = destinationDir
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let host = Self.localIPv4Address()
                        self.displayAddress = host.map { "http://\($0):\(Self.port)" }
                    case .failed, .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        isRunning = false
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state {} else if case .cancelled = state {} else { return }
            Task { @MainActor in
                guard let self, let connection else { return }
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Accumulate bytes until the full request (headers + Content-Length body)
    /// has arrived, then route it.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }

                if let request = HTTPRequest(raw: buffer) {
                    self.route(request, on: connection)
                } else if isComplete {
                    connection.cancel()
                } else if buffer.count > 600_000_000 {
                    // Runaway request — nothing in an EV Nova install is this big.
                    self.send(status: "413 Payload Too Large", body: "Too large", on: connection)
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            send(status: "200 OK", body: Self.uploadPageHTML, contentType: "text/html; charset=utf-8", on: connection)
        case ("POST", let path) where path.hasPrefix("/upload"):
            handleUpload(request, on: connection)
        default:
            send(status: "404 Not Found", body: "Not found", on: connection)
        }
    }

    private func handleUpload(_ request: HTTPRequest, on connection: NWConnection) {
        guard let rawName = request.queryItem("name"),
              let decoded = rawName.removingPercentEncoding else {
            send(status: "400 Bad Request", body: "Missing name", on: connection)
            return
        }
        // Sanitize: last path component only, and only known EV Nova file types.
        let name = (decoded as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard !name.isEmpty, !name.hasPrefix("."), Self.allowedExtensions.contains(ext) else {
            send(status: "415 Unsupported Media Type",
                 body: "Skipped \(name): not an EV Nova data/media file", on: connection)
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let dest = destinationDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try request.body.write(to: dest)
            if !receivedFiles.contains(name) { receivedFiles.append(name) }
            onFileReceived()
            send(status: "200 OK", body: "OK", on: connection)
        } catch {
            send(status: "500 Internal Server Error", body: error.localizedDescription, on: connection)
        }
    }

    private func send(status: String, body: String, contentType: String = "text/plain; charset=utf-8",
                      on connection: NWConnection) {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: LAN address

    /// The device's IPv4 address on Wi-Fi/Ethernet (en0/en1), for display.
    static func localIPv4Address() -> String? {
        var best: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(cString: host)
                if name == "en0" { return addr }   // primary interface wins
                if best == nil { best = addr }
            }
        }
        return best
    }

    // MARK: Upload page

    /// The single-page uploader served at `/`. Plain HTML+JS, no dependencies:
    /// pick files (or a whole folder) and each is POSTed raw to
    /// `/upload?name=<file>`; per-file status is shown inline.
    private static let uploadPageHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>NovaSwift — Send Nova Files</title>
    <style>
      body { background:#0a0a0f; color:#eee; font:16px -apple-system, system-ui, sans-serif;
             display:flex; flex-direction:column; align-items:center; padding:40px 16px; }
      h1 { color:#ffb43c; font-size:22px; }
      p  { color:#aaa; max-width:34em; text-align:center; }
      #drop { border:2px dashed #ffb43c88; border-radius:14px; padding:40px 60px; margin:24px 0;
              text-align:center; cursor:pointer; }
      #drop.hover { background:#ffb43c14; border-color:#ffb43c; }
      ul { list-style:none; padding:0; max-width:34em; width:100%; }
      li { padding:6px 10px; border-bottom:1px solid #222; font-size:14px; }
      .ok::after   { content:" ✓ sent"; color:#7cd97c; }
      .fail::after { content:" ✕ failed"; color:#e07a7a; }
      .skip::after { content:" — skipped"; color:#999; }
    </style></head><body>
    <h1>Send your Nova Files to NovaSwift</h1>
    <p>Drop your <b>Nova Files</b> folder (or the .ndat / .rez files inside it) here.
       Including the soundtrack (.mp3) and fonts (.ttf) is optional but recommended.
       Files go straight to this device over your network — nothing is uploaded to the internet.</p>
    <div id="drop">Drop files here<br>or click to choose</div>
    <input id="pick" type="file" multiple style="display:none">
    <ul id="log"></ul>
    <script>
    const drop = document.getElementById('drop'), pick = document.getElementById('pick'),
          log = document.getElementById('log');
    drop.onclick = () => pick.click();
    drop.ondragover = e => { e.preventDefault(); drop.classList.add('hover'); };
    drop.ondragleave = () => drop.classList.remove('hover');
    drop.ondrop = e => { e.preventDefault(); drop.classList.remove('hover'); sendAll(e.dataTransfer.files); };
    pick.onchange = () => sendAll(pick.files);
    async function sendAll(files) {
      for (const f of files) {
        const li = document.createElement('li');
        li.textContent = f.name; log.appendChild(li);
        try {
          const r = await fetch('/upload?name=' + encodeURIComponent(f.name), { method:'POST', body:f });
          li.className = r.ok ? 'ok' : (r.status === 415 ? 'skip' : 'fail');
        } catch { li.className = 'fail'; }
      }
    }
    </script></body></html>
    """
}

/// Just enough HTTP/1.1 parsing for the two routes above: request line,
/// headers (only Content-Length matters), and a fully buffered body.
/// `init` returns nil until the complete request has arrived.
private struct HTTPRequest {
    let method: String
    let path: String
    let query: String
    let body: Data

    init?(raw: Data) {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: raw[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard raw.count - bodyStart >= contentLength else { return nil }   // body still arriving

        self.method = parts[0]
        let target = parts[1]
        if let q = target.firstIndex(of: "?") {
            self.path = String(target[..<q])
            self.query = String(target[target.index(after: q)...])
        } else {
            self.path = target
            self.query = ""
        }
        self.body = raw.subdata(in: bodyStart..<(bodyStart + contentLength))
    }

    /// Value of a query item, still percent-encoded.
    func queryItem(_ name: String) -> String? {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }
}
