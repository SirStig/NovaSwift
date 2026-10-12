#if os(macOS)
import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine

// MARK: - Live preview (embeddable)
//
//     @StateObject var preview = EditorPreviewModel()
//     …
//     EditorLivePreviewView(model: preview)
//     …
//     // whenever the document's effective collection changes:
//     preview.update(collection: doc.effective, systemID: selectedSystem, base: doc.base)
//
// `update` is cheap to call on every edit: it debounces (~300 ms), rebuilds the
// game data off-main, and then reloads the system IN PLACE in the one live
// `GameScene` (`editorAdoptGalaxy` + `editorReloadSystem`), keeping the camera where
// the author left it. A fresh scene is built only for the first rebuild or when the
// camera ship's own data (shïp / shän) changed. HD/3D art comes from `EditorHD`. The view
// needs `AppModel` in the environment (settings / key bindings come from it).
//
// Interaction: drag = pan, scroll / pinch = zoom. The camera is an invisible,
// invulnerable player ship that never moves on its own.

@MainActor
final class EditorPreviewModel: ObservableObject {

    enum Status: Equatable {
        case idle
        case building
        case ready
        case failed(String)
    }

    @Published private(set) var host: GameHost?
    @Published private(set) var status: Status = .idle
    /// Wall-clock cost of the last rebuild (data build + scene construction), ms.
    @Published private(set) var lastRebuildMillis: Double = 0
    @Published private(set) var lastBuild: EditorBuild?
    @Published private(set) var systemID: Int?

    /// NPC traffic (ambient spawner + existing ships).
    @Published var showTraffic = true { didSet { applyTraffic() } }
    @Published var paused = false { didSet { applyPause() } }
    /// SpriteKit camera scale: >1 shows more of the system (zoomed out).
    @Published var zoom: Double = 1.0 { didSet { applyZoom() } }

    /// Debounce between the last `update` and the rebuild.
    var debounce: Duration = .milliseconds(300)

    private weak var app: AppModel?
    private var pending: (collection: ResourceCollection, systemID: Int, base: ResourceCollection?)?
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private var holdTimer: Timer?
    /// The camera (player) position to restore after a rebuild.
    private var cameraPose: Vec2?
    /// What the live scene's camera ship was built from (hull id + shïp/shän bytes). While it
    /// is unchanged a rebuild only reloads the system in place.
    private var playerKey: Int?
    /// How many rebuilds reused the scene vs built a new one (perf readout / tests).
    private(set) var reusedScenes = 0
    private(set) var freshScenes = 0

    init() {}

    deinit { holdTimer?.invalidate() }

    // MARK: Public API

    /// Request a (debounced) rebuild showing `systemID` of `collection`.
    /// `base` (the unmodified base game) lets the sprite cache re-decode only
    /// changed rlëD resources; pass it whenever you have it.
    func update(collection: ResourceCollection, systemID: Int, base: ResourceCollection? = nil) {
        pending = (collection, systemID, base)
        debounceTask?.cancel()
        guard app != nil else { return }   // runs on `bind`
        let wait: Duration = (host == nil && status != .building) ? .zero : debounce
        debounceTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// Rebuild immediately with the last `update` arguments.
    func rebuildNow() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in await self?.rebuild() }
    }

    /// Centre the camera on a point in system coordinates (`sÿst`/`spöb` X,Y:
    /// +y is DOWN, like the authored data).
    func center(onSystemX x: Double, y: Double) {
        guard let ship = host?.scene.playerShip else { return }
        ship.position = Vec2(x, -y)
        host?.scene.camera?.position = CGPoint(x: x, y: -y)
        cameraPose = ship.position
    }

    /// Centre on the system origin.
    func resetCamera() { center(onSystemX: 0, y: 0) }

    /// Release the scene (call when the preview goes away).
    func teardown() {
        debounceTask?.cancel()
        holdTimer?.invalidate(); holdTimer = nil
        host = nil
        playerKey = nil
        status = .idle
        EditorHD.shared.release(self, app: app)
    }

    // MARK: Internals (view-facing)

    func bind(_ app: AppModel) {
        let first = self.app == nil
        self.app = app
        // First appearance, or re-appearance after `teardown`: build the last request.
        if (first || host == nil), let p = pending { update(collection: p.collection, systemID: p.systemID, base: p.base) }
    }

    func pan(viewDX: Double, viewDY: Double) {
        guard let ship = host?.scene.playerShip else { return }
        let z = zoom
        ship.position = ship.position + Vec2(-viewDX * z, viewDY * z)
        ship.velocity = Vec2()
        cameraPose = ship.position
        if paused {   // the scene isn't updating: move the camera directly
            host?.scene.camera?.position = CGPoint(x: ship.position.x, y: ship.position.y)
        }
    }

    func zoomBy(_ factor: Double) {
        zoom = min(8, max(0.2, zoom * factor))
    }

    private func rebuild() async {
        guard let app, let p = pending else { return }
        generation += 1
        let gen = generation
        status = .building
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sameSystem = host != nil && systemID == p.systemID
        if let ship = host?.scene.playerShip { cameraPose = ship.position }

        // Nothing heavy on main: the default ship is resolved inside the off-main build
        // (`shipID: nil` = scenario default, returned as `build.defaultStart`). HD art is
        // installed/prepared there too, so the scene below picks it up when it builds sprites.
        EditorHD.shared.acquire(self)
        let result = await EditorGameFactory.build(
            collection: p.collection, base: p.base,
            flightTuning: FlightTuning(enhancements: app.settings.enhancements),
            systemID: p.systemID, shipID: nil,
            hd: EditorHD.inputs(app: app, base: p.base))
        guard gen == generation, !Task.isCancelled else { return }   // superseded
        // Let the loading state / refresh strip paint before the main-actor scene construction.
        await Task.yield()
        guard gen == generation, !Task.isCancelled else { return }

        switch result {
        case .failure(let err):
            status = .failed(err.localizedDescription)   // keep showing the last good scene
        case .success(let build):
            guard let shipID = build.defaultStart?.shipID else {
                status = .failed("No ship available to host the preview."); return
            }
            let key = Self.playerKey(shipID: shipID, in: p.collection)

            // Same camera ship, system still exists: keep the scene and its view, adopt the new
            // catalog and reload the system in place (cheap on main; no SKView scene swap).
            if let host, playerKey == key, build.game.system(p.systemID) != nil {
                host.scene.editorAdoptGalaxy(build.galaxy)
                host.scene.editorReloadSystem(to: p.systemID)
                if let ship = host.scene.playerShip {
                    if sameSystem, let pose = cameraPose { ship.position = pose }
                    else { ship.position = Vec2() }
                    ship.velocity = Vec2()
                    host.scene.camera?.position = CGPoint(x: ship.position.x, y: ship.position.y)
                    cameraPose = ship.position
                }
                systemID = host.scene.editorSystemID
                lastBuild = build
                reusedScenes += 1
                applyAll()
                lastRebuildMillis = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                status = .ready
                Log.scene.info("EditorPreviewModel: reloaded system \(p.systemID, privacy: .public) in place in \(self.lastRebuildMillis, format: .fixed(precision: 1), privacy: .public) ms")
                return
            }

            var opts = EditorHostOptions(systemID: p.systemID, shipID: shipID)
            opts.invulnerable = true
            opts.muted = true
            opts.hidePlayer = true
            // Same system: keep the author's camera. A new one opens on its centre
            // (matching the in-place path above), not the arrival spawn point.
            opts.position = sameSystem ? (cameraPose ?? Vec2()) : Vec2()
            guard let newHost = GameHost.makeEditorHost(model: app, build: build, options: opts) else {
                status = .failed("Couldn't build system #\(p.systemID)."); return
            }
            host = newHost
            playerKey = key
            freshScenes += 1
            systemID = newHost.scene.editorSystemID
            lastBuild = build
            cameraPose = newHost.scene.playerShip?.position
            applyAll()
            startHoldTimer()
            lastRebuildMillis = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            status = .ready
            Log.scene.info("EditorPreviewModel: rebuilt system \(p.systemID, privacy: .public) in \(self.lastRebuildMillis, format: .fixed(precision: 1), privacy: .public) ms")
        }
    }

    /// Identity of the data the camera ship was built from: the hull id plus its shïp and
    /// shän records. (Its sprite is hidden, so sprite edits don't matter.)
    private static func playerKey(shipID: Int, in c: ResourceCollection) -> Int {
        var h = Hasher()
        h.combine(shipID)
        h.combine(c.resource(NovaType.ship, shipID)?.data)
        h.combine(c.resource(NovaType.shan, shipID)?.data)
        return h.finalize()
    }

    private func applyAll() {
        applyZoom(); applyTraffic(); applyPause()
    }

    private func applyZoom() {
        guard let app, let scene = host?.scene else { return }
        var s = app.settings
        s.cameraZoom = zoom
        s.showPlanetLabels = true
        s.mouseAiming = false
        scene.applyDisplaySettings(s)
    }

    private func applyTraffic() {
        guard let world = host?.scene.editorWorld else { return }
        if showTraffic {
            if world.spawner == nil { /* re-enabled on the next rebuild */ }
        } else {
            world.spawner = nil
            world.removeAllNPCs()
        }
    }

    private func applyPause() {
        host?.scene.isPaused = paused
    }

    /// The camera ship must never drift (gravity wells, entry overspeed): pin
    /// its velocity at 20 Hz.
    private func startHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let ship = self?.host?.scene.playerShip else { return }
                ship.velocity = Vec2()
                ship.shield = ship.maxShield
                ship.armor = ship.maxArmor
            }
        }
    }
}

// MARK: - View

struct EditorLivePreviewView: View {
    @ObservedObject var model: EditorPreviewModel
    @EnvironmentObject private var app: AppModel
    /// Show the compact control strip along the bottom.
    var showsToolbar = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let host = model.host {
                PreviewSKViewRepresentable(
                    scene: host.scene,
                    onPan: { model.pan(viewDX: $0, viewDY: $1) },
                    onZoom: { model.zoomBy($0) })
            }
            statusOverlay
            VStack(spacing: 0) {
                EditorRefreshStrip(active: model.status == .building && model.host != nil)
                Spacer(minLength: 0)
            }
            if showsToolbar { toolbar }
        }
        .clipped()
        .onAppear { model.bind(app) }
        .onDisappear { model.teardown() }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch model.status {
        case .building where model.host == nil:
            EditorLoadingOverlay(label: "Starting preview\u{2026}")
        case .failed(let msg):
            VStack {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }.padding(8).frame(maxHeight: .infinity, alignment: .top)
        case .idle where model.host == nil:
            // Idle only happens before the first `update` lands (the request is
            // deferred one tick after the tool opens) — still "starting".
            EditorLoadingOverlay(label: "Starting preview\u{2026}")
        default:
            EmptyView()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $model.showTraffic) { Image(systemName: "airplane") }
                .toggleStyle(.button).help("NPC traffic")
            Toggle(isOn: $model.paused) { Image(systemName: "pause.fill") }
                .toggleStyle(.button).help("Pause")
            Button { model.resetCamera() } label: { Image(systemName: "scope") }
                .help("Centre on system origin")
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log2(model.zoom) }, set: { model.zoom = pow(2, $0) }),
                   in: -2...3).frame(width: 90)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.status == .building { ProgressView().controlSize(.mini) }
            if model.lastRebuildMillis > 0 {
                Text(String(format: "%.0f ms", model.lastRebuildMillis))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .tint(novaAmber)
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.65))
        .foregroundStyle(novaAmber)
    }
}

// MARK: - SKView host with pan / zoom input

/// An `SKView` that turns drag / scroll / pinch into camera moves, and ignores
/// clicks (the preview is look-only, so the scene's ship-selection stays idle).
final class EditorPreviewSKView: SKView {
    var onPan: (Double, Double) -> Void = { _, _ in }
    var onZoom: (Double) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onPan(Double(event.deltaX), Double(event.deltaY)) }
    override func rightMouseDragged(with event: NSEvent) { onPan(Double(event.deltaX), Double(event.deltaY)) }
    override func otherMouseDragged(with event: NSEvent) { onPan(Double(event.deltaX), Double(event.deltaY)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            onZoom(exp(-Double(event.scrollingDeltaY) * 0.02))
        } else {
            // Two-finger scroll pans (natural direction: content follows fingers).
            onPan(Double(event.scrollingDeltaX), -Double(event.scrollingDeltaY))
        }
    }
    override func magnify(with event: NSEvent) { onZoom(1 / (1 + Double(event.magnification))) }
}

private struct PreviewSKViewRepresentable: NSViewRepresentable {
    let scene: SKScene
    var onPan: (Double, Double) -> Void
    var onZoom: (Double) -> Void

    func makeNSView(context: Context) -> EditorPreviewSKView {
        let v = EditorPreviewSKView()
        v.ignoresSiblingOrder = true
        v.preferredFramesPerSecond = 60
        v.onPan = onPan; v.onZoom = onZoom
        v.presentScene(scene)
        return v
    }

    func updateNSView(_ v: EditorPreviewSKView, context: Context) {
        v.onPan = onPan; v.onZoom = onZoom
        if v.scene !== scene { v.presentScene(scene) }   // same view, new scene: no flash
    }

    static func dismantleNSView(_ v: EditorPreviewSKView, coordinator: ()) {
        v.presentScene(nil)
    }
}
#endif
