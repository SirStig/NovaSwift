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
    /// Fires when the browser reports its whole batch is uploaded (`POST
    /// /done`). The returned text goes back to the uploader's page — the
    /// owner reloads the game data and answers with "all set" or what's
    /// still missing, so the person at the computer sees the verdict too.
    var onBatchComplete: () async -> String = { "" }

    /// Where uploads land. Set before `start()`.
    private var destinationDir: URL
    private var listener: NWListener?
    /// Strong refs to in-flight connections (dropped on close).
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// `start()` has been called and `stop()` hasn't: a failed bind (port
    /// briefly held by a predecessor — SwiftUI rebuild, quick app relaunch,
    /// TIME_WAIT) keeps retrying while this is set, instead of dying with
    /// "Starting the Wi-Fi receiver…" on screen forever.
    private var wantsRunning = false
    private var retryTask: Task<Void, Never>?

    static let port: UInt16 = 8017

    /// Everything an EV Nova install legitimately ships that the importer
    /// knows what to do with (resource files, soundtrack, fonts, videos) —
    /// plus .zip, which unpacks into the same set (the whole game folder in
    /// one drop).
    private static let allowedExtensions: Set<String> = [
        "ndat", "rez", "zip", "mp3", "m4a", "aiff", "wav", "ttf", "otf", "mov", "mp4", "m4v",
    ]

    init(destinationDir: URL) {
        self.destinationDir = destinationDir
    }

    func start() {
        wantsRunning = true
        startListener()
    }

    private func startListener() {
        guard wantsRunning, listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener,
                          // A stale handler from a superseded listener must
                          // not clobber the live one's published state.
                          self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let host = Self.localIPv4Address()
                        self.displayAddress = host.map { "http://\($0):\(Self.port)" }
                    case .failed(let error):
                        // Usually "address in use": the previous listener's
                        // socket hasn't been released yet. Drop this one and
                        // try again shortly — the port frees within a beat.
                        Log.data.notice("web import: listener failed (\(String(describing: error), privacy: .public)) — retrying")
                        self.isRunning = false
                        self.listener = nil
                        listener.cancel()
                        self.scheduleRetry()
                    case .cancelled:
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
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard wantsRunning, retryTask == nil else { return }
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            retryTask = nil
            startListener()
        }
    }

    func stop() {
        wantsRunning = false
        retryTask?.cancel()
        retryTask = nil
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
    /// has arrived, then route it. The header is located and its
    /// Content-Length read exactly once (`expectedTotal` rides the recursion);
    /// after that each chunk is a plain byte-count check — re-scanning the
    /// whole growing buffer per 64 KB chunk was quadratic, real CPU pain on
    /// an Apple TV receiving a 15 MB .rez.
    private func receive(on connection: NWConnection, buffer: Data, expectedTotal: Int? = nil) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }

                var expectedTotal = expectedTotal
                if expectedTotal == nil,
                   // A real browser request's header block arrives in the first
                   // chunk or two — no need to search beyond it.
                   let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8),
                                                in: 0..<min(buffer.count, 1 << 16)) {
                    expectedTotal = headerEnd.upperBound + Self.contentLength(inHeader: buffer[..<headerEnd.lowerBound])
                }

                if let total = expectedTotal, buffer.count >= total {
                    if let request = HTTPRequest(raw: buffer) {
                        self.route(request, on: connection)
                    } else {
                        connection.cancel()
                    }
                } else if isComplete {
                    connection.cancel()
                } else if buffer.count > 600_000_000 {
                    // Runaway request — nothing in an EV Nova install is this big.
                    self.send(status: "413 Payload Too Large", body: "Too large", on: connection)
                } else {
                    self.receive(on: connection, buffer: buffer, expectedTotal: expectedTotal)
                }
            }
        }
    }

    /// Content-Length from a raw header block (0 when absent).
    private static func contentLength(inHeader head: Data) -> Int {
        guard let text = String(data: head, encoding: .utf8) else { return 0 }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            send(status: "200 OK", body: Self.uploadPageHTML, contentType: "text/html; charset=utf-8", on: connection)
        case ("POST", let path) where path.hasPrefix("/upload"):
            handleUpload(request, on: connection)
        case ("POST", let path) where path.hasPrefix("/done"):
            // The uploader's page says its batch is finished — let the owner
            // reload + validate, and relay the verdict to the browser.
            Task { @MainActor in
                let verdict = await self.onBatchComplete()
                self.send(status: "200 OK", body: verdict, on: connection)
            }
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
        if ext == "zip" {
            handleZipUpload(request.body, name: name, on: connection)
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

    /// A .zip lands as a temp file and unpacks through the same
    /// discover-and-copy path a picked folder uses (`DataImporter`), so the
    /// player can drop one zipped game folder instead of hand-picking files.
    /// The unzip runs off the main actor — a full install is ~100 MB.
    private func handleZipUpload(_ body: Data, name: String, on connection: NWConnection) {
        let dest = destinationDir
        Task { @MainActor in
            let tmpZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("novaswift-upload-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: tmpZip) }
            do {
                try body.write(to: tmpZip)
                let count = try await Task.detached(priority: .userInitiated) {
                    try DataImporter.importBase(from: tmpZip, into: dest)
                }.value
                guard count > 0 else {
                    self.send(status: "415 Unsupported Media Type",
                              body: "No EV Nova data files found inside \(name)", on: connection)
                    return
                }
                let entry = "\(name) (\(count) file\(count == 1 ? "" : "s"))"
                if !self.receivedFiles.contains(entry) { self.receivedFiles.append(entry) }
                self.onFileReceived()
                self.send(status: "200 OK", body: "OK", on: connection)
            } catch {
                self.send(status: "500 Internal Server Error",
                          body: error.localizedDescription, on: connection)
            }
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
    /// pick files, pick (or drop) a whole folder, or drop a .zip — each file
    /// is POSTed raw to `/upload?name=<file>`, and when the batch finishes
    /// the page POSTs `/done` and shows the device's verdict (all set, or
    /// which pieces are still missing). A sticky header carries an overall
    /// progress bar; junk files are filtered client-side and reported as one
    /// count, not a wall of rows; a network error retries once and then
    /// aborts the batch with a clear "lost the connection" message instead of
    /// marking every remaining file failed.
    private static let uploadPageHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>NovaSwift — Send Nova Files</title>
    <style>
      * { box-sizing:border-box; }
      body { background:#0a0a0f; color:#eee; margin:0;
             font:16px -apple-system, system-ui, sans-serif; }
      .wrap { max-width:560px; margin:0 auto; padding:0 16px 48px; }
      header { position:sticky; top:0; z-index:2; background:#0a0a0fee;
               -webkit-backdrop-filter:blur(8px); backdrop-filter:blur(8px);
               border-bottom:1px solid #222; padding:14px 0 12px; }
      h1 { color:#ffb43c; font-size:20px; margin:0 0 6px; }
      #verdict { font-size:14px; font-weight:600; color:#aaa; min-height:1.3em; }
      #verdict.good { color:#7cd97c; }
      #verdict.warn { color:#ffb43c; }
      #verdict.bad  { color:#e07a7a; }
      #barwrap { display:none; height:5px; background:#222; border-radius:99px;
                 overflow:hidden; margin-top:9px; }
      #bar { height:100%; width:0%; background:#ffb43c; border-radius:99px;
             transition:width .25s ease; }
      p.hint { color:#aaa; font-size:14px; line-height:1.45; margin:16px 0 0; }
      #drop { border:2px dashed #ffb43c88; border-radius:14px; padding:34px 20px;
              margin:16px 0 12px; text-align:center; cursor:pointer;
              color:#ddd; font-weight:500; }
      #drop.hover { background:#ffb43c14; border-color:#ffb43c; }
      #drop small { display:block; color:#888; font-weight:400; margin-top:5px; }
      .row { display:flex; gap:10px; }
      button { background:#ffb43c; border:0; border-radius:999px; color:#000; font-weight:600;
               padding:10px 18px; cursor:pointer; font-size:14px; }
      button.alt { background:#2c2c33; color:#eee; }
      ul { list-style:none; padding:0; margin:18px 0 0; }
      li { display:flex; justify-content:space-between; gap:12px; padding:7px 10px;
           border-bottom:1px solid #1c1c22; font-size:14px; color:#ccc; }
      li .st { white-space:nowrap; color:#888; }
      li.ok .st   { color:#7cd97c; }
      li.fail     { background:#e07a7a14; }
      li.fail .st { color:#e07a7a; }
      #skipped { color:#777; font-size:13px; margin-top:10px; }
    </style></head><body>
    <div class="wrap">
    <header>
      <h1>Send your Nova Files to NovaSwift</h1>
      <div id="verdict">Waiting for your files…</div>
      <div id="barwrap"><div id="bar"></div></div>
    </header>
    <p class="hint">Drop your whole <b>Nova Files</b> folder — or a .zip of the game — below.
       The data files (.ndat / .rez) plus the optional soundtrack, fonts and race videos are
       picked out automatically; everything else is ignored. Files go straight to your
       Apple TV over your network — nothing touches the internet.</p>
    <div id="drop">Drop your game folder, files or .zip here
      <small>or use the buttons below</small></div>
    <div class="row">
      <button id="pickFolderBtn">Choose Folder…</button>
      <button id="pickFilesBtn" class="alt">Choose Files…</button>
    </div>
    <input id="pickFiles" type="file" multiple style="display:none">
    <input id="pickFolder" type="file" webkitdirectory style="display:none">
    <ul id="log"></ul>
    <div id="skipped"></div>
    </div>
    <script>
    const drop = document.getElementById('drop'), log = document.getElementById('log'),
          verdict = document.getElementById('verdict'), bar = document.getElementById('bar'),
          barwrap = document.getElementById('barwrap'),
          skippedLine = document.getElementById('skipped'),
          pickFiles = document.getElementById('pickFiles'),
          pickFolder = document.getElementById('pickFolder');
    const allowed = new Set(['ndat','rez','zip','mp3','m4a','aiff','wav','ttf','otf','mov','mp4','m4v']);
    const extOf = n => n.includes('.') ? n.split('.').pop().toLowerCase() : '';
    const sleep = ms => new Promise(res => setTimeout(res, ms));
    document.getElementById('pickFolderBtn').onclick = () => pickFolder.click();
    document.getElementById('pickFilesBtn').onclick = () => pickFiles.click();
    drop.onclick = () => pickFolder.click();
    pickFiles.onchange = () => { sendAll([...pickFiles.files]); pickFiles.value = ''; };
    pickFolder.onchange = () => { sendAll([...pickFolder.files]); pickFolder.value = ''; };
    drop.ondragover = e => { e.preventDefault(); drop.classList.add('hover'); };
    drop.ondragleave = () => drop.classList.remove('hover');
    drop.ondrop = e => {
      e.preventDefault(); drop.classList.remove('hover');
      // Directory entries must be grabbed synchronously, before this handler
      // yields — afterwards the DataTransfer items are gone.
      const entries = [...e.dataTransfer.items].map(i => i.webkitGetAsEntry ? i.webkitGetAsEntry() : null);
      const plain = [...e.dataTransfer.files];
      collect(entries, plain).then(sendAll);
    };
    // Depth-first expansion of dropped folders into their files; falls back
    // to the flat file list on browsers without the entry API.
    async function collect(entries, fallback) {
      if (!entries.some(x => x)) return fallback;
      const out = [];
      async function walk(entry) {
        if (!entry) return;
        if (entry.isFile) {
          try { out.push(await new Promise((res, rej) => entry.file(res, rej))); } catch {}
        } else if (entry.isDirectory) {
          const reader = entry.createReader();
          let batch;
          do {
            batch = await new Promise((res, rej) => reader.readEntries(res, rej));
            for (const child of batch) await walk(child);
          } while (batch.length > 0);
        }
      }
      for (const entry of entries) await walk(entry);
      return out;
    }
    function setVerdict(text, cls) { verdict.textContent = text; verdict.className = cls; }
    function addLine(name) {
      const li = document.createElement('li');
      const nm = document.createElement('span'); nm.textContent = name;
      const st = document.createElement('span'); st.className = 'st'; st.textContent = '…';
      li.append(nm, st); log.prepend(li);
      return { li, st };
    }
    async function post(f) {
      const r = await fetch('/upload?name=' + encodeURIComponent(f.name), { method:'POST', body:f });
      return r.ok ? 'ok' : (r.status === 415 ? 'skip' : 'fail');
    }
    let busy = false;
    async function sendAll(files) {
      if (busy) return;
      // Filter up front: junk becomes one count, not a wall of rows.
      const wanted = files.filter(f => !f.name.startsWith('.') && allowed.has(extOf(f.name)));
      const skipped = files.length - wanted.length;
      skippedLine.textContent = skipped > 0
        ? skipped + ' other file' + (skipped === 1 ? '' : 's') + ' ignored (not game data)' : '';
      if (!wanted.length) {
        setVerdict('Nothing sendable in that selection — pick the game folder, its .ndat/.rez files, or a .zip.', 'warn');
        return;
      }
      busy = true;
      barwrap.style.display = 'block';
      // Big data files first: the important stuff lands even if the batch is cut short.
      wanted.sort((a, b) => b.size - a.size);
      let sent = 0, failed = 0, lost = false;
      for (let i = 0; i < wanted.length; i++) {
        const f = wanted[i];
        setVerdict('Sending ' + (i + 1) + ' of ' + wanted.length + ' — ' + f.name, '');
        bar.style.width = (i / wanted.length * 100) + '%';
        const { li, st } = addLine(f.name);
        let outcome;
        try { outcome = await post(f); }
        catch {
          // Network error (server unreachable) — settle and retry once
          // before declaring the connection dead.
          await sleep(800);
          try { outcome = await post(f); } catch { outcome = 'lost'; }
        }
        if (outcome === 'lost') {
          li.className = 'fail'; st.textContent = '✕ connection lost';
          lost = true;
          break;
        }
        li.className = outcome;
        st.textContent = outcome === 'ok' ? '✓ sent' : (outcome === 'skip' ? 'skipped' : '✕ failed');
        if (outcome === 'ok') sent++;
        if (outcome === 'fail') failed++;
      }
      bar.style.width = '100%';
      if (lost) {
        setVerdict('Lost the connection to your Apple TV after ' + sent + ' file' + (sent === 1 ? '' : 's')
                   + '. Check that its import screen is still open, then send the folder again — '
                   + 'files already sent are kept.', 'bad');
        busy = false;
        return;
      }
      setVerdict('Checking the data on your Apple TV…', '');
      try {
        const r = await fetch('/done', { method:'POST' });
        const text = await r.text();
        setVerdict(text, text.startsWith('✓') ? 'good' : 'warn');
      } catch {
        setVerdict('Sent ' + sent + ' file' + (sent === 1 ? '' : 's') + (failed ? ', ' + failed + ' failed' : '')
                   + ' — check your Apple TV for the result.', 'warn');
      }
      busy = false;
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
