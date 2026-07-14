import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The in-game menu — a single, clean, animated panel that slides in from the
/// left and hosts every non-flight action: resume, galaxy map, mission log,
/// preferences, pilot save/load, and returning to the main menu. Opening it
/// pauses the simulation; Resume (or tapping outside / Esc) closes it.
///
/// New features get a row here rather than another floating button on the HUD.
struct GameMenuView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var hud: GameHUDModel
    var onResume: () -> Void
    var onOpenMap: () -> Void
    /// Whether to show the Debug Suite row (debug mode enabled).
    var showDebug: Bool = false
    /// Open the in-game debug suite.
    var onOpenDebug: () -> Void = {}

    @State private var showSettings = false
    @State private var storyModel: StoryGuideModel?
    @State private var storyTab: StoryGuideView.Tab = .story
    @State private var showPlayerInfo = false
    @State private var showMissions = false
    @State private var info: String?

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onResume() }

            panel
                .frame(maxWidth: 340, maxHeight: .infinity, alignment: .top)
                .background(.ultraThinMaterial)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))

            // The authentic 4-tab player-info dialog (DITL #1017), stacked over
            // the menu like the game's own dialogs.
            if showPlayerInfo, let graphics = model.uiGraphics {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showPlayerInfo = false }
                    .transition(.opacity)
                PlayerInfoView(graphics: graphics, pilot: model.pilot,
                               onJettison: { jettisonCargo() },
                               onDone: { showPlayerInfo = false })
                    .transition(.opacity)
            }

            // The authentic Mission Info dialog (DITL #1012 / PICT #8517):
            // active missions, their destinations, and Abort Mission.
            if showMissions, let graphics = model.uiGraphics, let game = model.data.game {
                MissionInfoView(graphics: graphics, game: game, pilot: model.pilot,
                                onClose: { showMissions = false })
                    .transition(.opacity)
            }
        }
        .novaResponsive()
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .frame(minWidth: 640, minHeight: 580)
                .preferredColorScheme(.dark)
        }
        // The Story Map / Pilot Log wants the whole screen to breathe. On iPhone
        // a `.sheet` is only a partial card (and the 900pt macOS width floor
        // overflows it), so present it as a true full-screen cover there; on Mac
        // keep the comfortable centred sheet.
        #if os(iOS)
        .fullScreenCover(isPresented: storyGuidePresented) { storyGuideContent }
        #else
        .sheet(isPresented: storyGuidePresented) {
            storyGuideContent.frame(minWidth: 900, minHeight: 620)
        }
        #endif
        .alert("Notice", isPresented: Binding(get: { info != nil },
                                                   set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(info ?? "") }
    }

    /// Whether the Story Map / Pilot Log is open (drives its presentation).
    private var storyGuidePresented: Binding<Bool> {
        Binding(get: { storyModel != nil }, set: { if !$0 { storyModel = nil } })
    }

    /// The Pilot Log itself — fills whatever presents it (full-screen on iOS,
    /// the sized sheet on macOS).
    @ViewBuilder private var storyGuideContent: some View {
        if let storyModel {
            StoryGuideView(model: storyModel, initialTab: storyTab,
                           onClose: { self.storyModel = nil },
                           onAbort: { abortMission($0) })
                .preferredColorScheme(.dark)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            ScrollView {
                VStack(spacing: 2) {
                    row("Resume", "play.fill", tint: amber) { onResume() }
                    row("Galaxy Map", "map.fill") { onResume(); onOpenMap() }
                    row("Pilot Info", "person.crop.circle") {
                        if model.uiGraphics != nil { showPlayerInfo = true }
                        else { info = "Import your EV Nova data to view pilot info." }
                    }
                    row("Missions", "list.bullet.clipboard") {
                        if model.uiGraphics != nil, model.data.game != nil { showMissions = true }
                        else { info = "Import your EV Nova data to view missions." }
                    }
                    row("Story Map", "point.3.connected.trianglepath.dotted") {
                        openStoryGuide(.map)
                    }
                    row("Preferences", "gearshape.fill") { showSettings = true }
                    if showDebug {
                        row("Debug Suite", "ladybug.fill",
                            tint: Color(red: 0.35, green: 0.95, blue: 0.5)) { onOpenDebug() }
                    }

                    sectionGap
                    // Multiplayer: the single entry point. Starting a session
                    // reveals the in-flight chat button + galaxy-map player
                    // markers; there is no multiplayer chrome in single-player.
                    if model.session.isActive {
                        row("Leave Co-op", "xmark.circle.fill", tint: .red) {
                            model.session.stop()
                        }
                    } else {
                        row("Host Local Co-op", "antenna.radiowaves.left.and.right") {
                            let name = model.pilot.state.pilotName
                            model.session.startLocal(
                                displayName: name.isEmpty ? "Captain" : name,
                                systemID: model.pilot.state.currentSystem)
                            onResume()   // drop back to flight with chat now live
                        }
                    }

                    sectionGap
                    row("Save Pilot", "square.and.arrow.down") {
                        model.autosave(reason: .manual)
                        info = model.pilot.rosterID != nil
                            ? "Pilot saved (\(model.pilot.state.pilotName))."
                            : "This session isn't a roster pilot yet — start one from the main menu to save."
                    }
                    row("Load Pilot", "folder") {
                        // Loading a different pilot means returning to the roster.
                        model.autosave(reason: .manual)
                        model.returnToMainMenu()
                    }

                    sectionGap
                    row("Main Menu", "rectangle.portrait.and.arrow.right", tint: .red) {
                        model.autosave(reason: .manual)   // save on the way out
                        model.returnToMainMenu()
                    }
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppLogo().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(hud.shipName.isEmpty ? "NOVA SWIFT" : hud.shipName)
                    .novaFont(.heading).foregroundStyle(amber)
                if !hud.systemName.isEmpty {
                    Text(hud.systemName).novaFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onResume) {
                Image(systemName: "xmark").font(.subheadline.weight(.bold))
                    .padding(8).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    /// Open the Pilot Log over the live game + current pilot, on `tab`. Builds a
    /// fresh guide model (indexing the mission graph) on demand; without loaded
    /// game data there's nothing to show, so explain that instead.
    private func openStoryGuide(_ tab: StoryGuideView.Tab) {
        guard let game = model.data.game else {
            info = "Load your EV Nova data to view your pilot log."
            return
        }
        storyTab = tab
        storyModel = .over(game, player: model.pilot.state, plugins: model.data.plugins)
    }

    /// Abort an active mission from the pilot panel and reflect it immediately:
    /// runs the real `StoryEngine` abort (applying the mission's OnAbort bits),
    /// writes the mutated pilot back to the live store, saves, and refreshes the
    /// panel so the mission drops off the list.
    /// Dump the hold (the player-info dialog's "Jettison Cargo"). Clears the
    /// persisted pilot's cargo immediately; the live ship's hold syncs from the
    /// pilot on the next takeoff/jump rebuild.
    private func jettisonCargo() {
        model.pilot.state.cargo = [:]
        model.pilot.save()
    }

    private func abortMission(_ missionID: Int) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state)
        engine.abortMission(missionID)
        model.pilot.state = engine.player
        model.pilot.save()
        storyModel?.update(player: model.pilot.state)
    }

    private var sectionGap: some View {
        Divider().overlay(.white.opacity(0.08)).padding(.vertical, 6)
    }

    private func row(_ title: String, _ icon: String, tint: Color = .white,
                     _ action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 26)
                    .foregroundStyle(tint == .white ? amber : tint)
                Text(title).novaFont(.button, weight: .medium).foregroundStyle(tint)
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}
