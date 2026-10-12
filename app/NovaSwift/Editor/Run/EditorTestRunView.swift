#if os(macOS)
import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine

/// A full-window test game on a `ResourceCollection` (base ⊕ the author's
/// plugin layer): real flight controls, real HUD, landing (a stub dock screen
/// with Take Off — no spaceport services), galaxy map + hyperjump inside the
/// edited galaxy, and a collapsible right-hand debug panel.
///
///     EditorTestRunView(collection: doc.effective, base: doc.base,
///                       startSystem: 128, startShip: 128,
///                       onExit: { editor.endTest() })
///
/// Sandbox guarantee: the session owns a throwaway pilot that is never saved;
/// no pilot-store callbacks are wired; the live roster/autosave is untouched.
/// Needs `AppModel` in the environment (settings, key bindings, audio).
struct EditorTestRunView: View {
    let collection: ResourceCollection
    var base: ResourceCollection? = nil
    var startSystem: Int? = nil
    var startShip: Int? = nil
    /// Called once the session is running (used by inspectors to equip / spawn a target).
    var onReady: ((EditorTestSession) -> Void)? = nil
    var onExit: () -> Void

    @EnvironmentObject private var model: AppModel
    @StateObject private var holder = SessionHolder()
    @State private var panelOpen = true
    @FocusState private var focused: Bool

    /// Creates the session lazily so `@StateObject` doesn't rebuild it per view init.
    @MainActor final class SessionHolder: ObservableObject {
        var session: EditorTestSession?
    }

    var body: some View {
        Group {
            if let session = holder.session {
                content(session)
            } else {
                loadingView
            }
        }
        .preferredColorScheme(.dark)
        // `.task` (not `.onAppear`): the loading state paints first, then the
        // session (PilotStore init etc.) is created and started.
        .task {
            guard holder.session == nil else { return }
            await Task.yield()
            let s = EditorTestSession(collection: collection, base: base,
                                      startSystem: startSystem, startShip: startShip)
            holder.session = s
            holder.objectWillChange.send()
            await s.start(app: model)
            if s.phase == .running { onReady?(s) }
        }
        .onDisappear { holder.session?.shutdown() }
    }

    /// Shown the instant the test run is requested, before any session exists.
    private var loadingView: some View {
        TestRunLoadingView(label: Self.loadingLabel(collection: collection, system: startSystem, ship: startShip))
    }

    fileprivate static func loadingLabel(collection: ResourceCollection, system: Int?, ship: Int?) -> String {
        var parts: [String] = []
        if let system {
            let n = collection.resource(NovaType.syst, system)?.name ?? ""
            parts.append(n.isEmpty ? "System #\(system)" : n)
        }
        if let ship {
            let n = collection.resource(NovaType.ship, ship)?.name ?? ""
            parts.append(n.isEmpty ? "Ship #\(ship)" : n)
        }
        return parts.isEmpty ? "Building test game\u{2026}" : "Building test game\u{2026}\n" + parts.joined(separator: " \u{2022} ")
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ session: EditorTestSession) -> some View {
        HStack(spacing: 0) {
            GameArea(session: session, focused: $focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if !panelOpen {
                        Button { panelOpen = true } label: {
                            Image(systemName: "ladybug.fill").padding(8)
                                .background(.black.opacity(0.7), in: Circle()).foregroundStyle(novaAmber)
                        }
                        .buttonStyle(.plain).padding(10).help("Show debug panel")
                    }
                }
            if panelOpen {
                Rectangle().fill(novaAmber.opacity(0.25)).frame(width: 1)
                EditorDebugPanel(session: session, onExit: { finish(session) },
                                 onCollapse: { panelOpen = false; focused = true })
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: panelOpen)
        .environmentObject(session.pilot)   // sandbox pilot shadows the real one in this subtree
    }

    private func finish(_ session: EditorTestSession) {
        session.shutdown()
        onExit()
    }
}

/// Dark canvas + the shared editor loading overlay (spinner, label, system / ship name).
private struct TestRunLoadingView: View {
    let label: String
    var body: some View {
        ZStack {
            Color(white: 0.04)
            EditorLoadingOverlay(label: label).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The game viewport + HUD + overlays

private struct GameArea: View {
    @ObservedObject var session: EditorTestSession
    var focused: FocusState<Bool>.Binding
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var nav: NavigationModel

    init(session: EditorTestSession, focused: FocusState<Bool>.Binding) {
        self.session = session
        self.focused = focused
        self._nav = ObservedObject(wrappedValue: session.nav)
    }

    private var hudStyle: AuthenticHUDStyle? { model.settings.modernHUD ? nil : session.host?.hudStyle }

    var body: some View {
        ZStack {
            Color.black
            switch session.phase {
            case .loading:
                TestRunLoadingView(label: EditorTestRunView.loadingLabel(collection: session.collection, system: session.startSystemID,
                                                                          ship: session.startShipID))
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text("Couldn't start the test run").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40)
            case .running:
                if let host = session.host {
                    sceneLayer(host)
                    hudLayer(host)
                    GeometryReader { geo in
                        ContextualActionsView(hud: host.hud, landOnly: true,
                                              onAction: { if $0 == .land { session.landKeyPressed() } },
                                              rightInset: sidebarWidth(geo.size, hudStyle))
                    }
                    MessageLogView(hud: host.hud)
                    if nav.showingMap {
                        GalaxyMapView(nav: nav, pilot: session.pilot,
                                      onJump: { _ = session.attemptJump() },
                                      onClose: { nav.showingMap = false },
                                      fullscreen: model.settings.fullscreenGalaxyMap)
                            .transition(.opacity)
                    }
                    if let spob = session.landedSpobID {
                        LandedStub(session: session, spobID: spob)
                    }
                    hint
                }
            }
        }
        .onChange(of: nav.showingMap) { _, _ in session.refreshPause(); if !nav.showingMap { focused.wrappedValue = true } }
    }

    private var hint: some View {
        VStack {
            Spacer()
            Text("Test run — sandbox pilot, nothing is saved.  Click the game to fly · M map · J jump · L land")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 4)
        }.allowsHitTesting(false)
    }

    @ViewBuilder
    private func sceneLayer(_ host: GameHost) -> some View {
        GeometryReader { geo in
            let sidebar = sidebarWidth(geo.size, hudStyle)
            let playWidth = max(0, geo.size.width - sidebar)
            SpriteView(scene: host.scene,
                       preferredFramesPerSecond: model.settings.frameRateCap.fps ?? 120,
                       options: [.ignoresSiblingOrder])
                .frame(width: playWidth, height: geo.size.height)
                .position(x: playWidth / 2, y: geo.size.height / 2)
                .id(ObjectIdentifier(host.scene))
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        session.cursorViewPoint = p
                        session.playViewSize = CGSize(width: playWidth, height: geo.size.height)
                    }
                }
        }
        .ignoresSafeArea()
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        .simultaneousGesture(TapGesture().onEnded { focused.wrappedValue = true })
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
        .onAppear { grabFocus() }
    }

    @ViewBuilder
    private func hudLayer(_ host: GameHost) -> some View {
        if let style = hudStyle {
            GeometryReader { geo in
                AuthenticHUDView(model: host.hud, style: style, showRadar: model.settings.showRadar,
                                 targetSprite: { host.targetSilhouette(shipType: $0) })
                    .frame(width: sidebarWidth(geo.size, style), height: geo.size.height, alignment: .trailing)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .opacity(model.settings.hudOpacity)
            .allowsHitTesting(false)
        } else {
            GameHUDView(model: host.hud, showRadar: model.settings.showRadar,
                        largerHUD: model.settings.largerHUD,
                        highContrast: model.settings.highContrastHUD)
                .opacity(model.settings.hudOpacity)
        }
    }

    private func sidebarWidth(_ size: CGSize, _ style: AuthenticHUDStyle?) -> CGFloat {
        guard let style, style.nativeSize.height > 0 else { return 0 }
        let scale = size.height / style.nativeSize.height
        return min(style.nativeSize.width * scale, size.width * 0.35)
    }

    // MARK: Input

    private func handleDiscrete(_ action: GameAction) {
        guard let scene = session.host?.scene else { return }
        if scene.isJumping { switch action { case .land, .hyperjump: return; default: break } }
        if session.landedSpobID != nil { return }
        switch action {
        case .land: session.landKeyPressed()
        case .openMenu, .pauseGame:
            if nav.showingMap { nav.showingMap = false } else { session.setPaused(!session.paused) }
        case .galaxyMap: nav.autoRoutePlotting = model.settings.enhancements.autoRoutePlotting; nav.showingMap.toggle()
        case .hyperjump: if !session.attemptJump(), model.settings.enhancements.autoRoutePlotting { nav.showingMap = true }
        case .targetNearest: scene.selectNearestTarget()
        case .nearestHostile: scene.selectNearestHostile()
        case .targetNext: scene.cycleTarget()
        case .targetPrevious: scene.cycleTarget(reverse: true)
        case .targetEscortNext: scene.cycleTarget(squad: true)
        case .clearTarget: scene.clearTarget()
        case .clearShipTarget: scene.clearShipTarget()
        case .selectNav1, .selectNav2, .selectNav3, .selectNav4:
            let i = [GameAction.selectNav1, .selectNav2, .selectNav3, .selectNav4].firstIndex(of: action) ?? 0
            scene.selectNavStellar(index: i)
        case .cycleHyperspaceLink: _ = nav.cycleHyperspaceLink()
        case .hyperspaceArm: scene.clearTravelSelection(); nav.selectHyperspace()
        case .clearSecondary: scene.playerShip?.clearSecondary()
        case .selectSecondaryNext: _ = scene.cycleSecondaryWeapon(forward: true)
        case .selectSecondaryPrev: _ = scene.cycleSecondaryWeapon(forward: false)
        case .toggleCloak: scene.togglePlayerCloak()
        case .recallFighters: scene.recallPlayerFighters()
        case .eject: scene.requestEject()
        case .dismissMessage: session.host?.hud.dismissMessage()
        default: break   // hail / board dialogs, info windows, escort panels: not in the test run
        }
    }

    /// Claim keyboard focus for the flight scene, retrying a few times — a
    /// single deferred set can lose the race against the view entering the tree.
    private func grabFocus(attempt: Int = 0) {
        DispatchQueue.main.async {
            focused.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !focused.wrappedValue, attempt < 5 { grabFocus(attempt: attempt + 1) }
            }
        }
    }
}

// MARK: - Landing stub

/// The test run's stand-in for the spaceport: what you landed on, and Take Off.
private struct LandedStub: View {
    @ObservedObject var session: EditorTestSession
    let spobID: Int

    var body: some View {
        let spob = session.game?.spob(spobID)
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                Image(systemName: "building.2.crop.circle").font(.system(size: 34)).foregroundStyle(novaAmber)
                Text("Landed on \(spob?.displayName ?? "stellar #\(spobID)")")
                    .font(.title3.weight(.semibold))
                if let spob {
                    Text(summary(spob)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Spaceport services (trade, outfitter, shipyard, missions) aren't part of the test run.\nUse the debug panel to change ship, outfits, bits and missions.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button { session.takeOff() } label: {
                    Label("Take Off", systemImage: "arrow.up.forward.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(novaAmber, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(28)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(novaAmber.opacity(0.4)))
        }
    }

    private func summary(_ spob: SpobRes) -> String {
        var parts = ["#\(spob.id)"]
        if let g = session.game?.govt(spob.government)?.displayName { parts.append(g) }
        parts.append("tech \(spob.techLevel)")
        if spob.landingFee > 0 { parts.append("landing fee \(spob.landingFee)") }
        if spob.isUninhabited { parts.append("uninhabited") }
        return parts.joined(separator: " · ")
    }
}
#endif
