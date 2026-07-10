import SwiftUI

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

    @State private var showSettings = false
    @State private var storyModel: StoryGuideModel?
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
        }
        .novaResponsive()
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .frame(minWidth: 420, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: Binding(get: { storyModel != nil },
                                    set: { if !$0 { storyModel = nil } })) {
            if let storyModel {
                StoryGuideView(model: storyModel, initialTab: .map,
                               onClose: { self.storyModel = nil })
                    .frame(minWidth: 900, minHeight: 620)
                    .preferredColorScheme(.dark)
            }
        }
        .alert("Notice", isPresented: Binding(get: { info != nil },
                                                   set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(info ?? "") }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            ScrollView {
                VStack(spacing: 2) {
                    row("Resume", "play.fill", tint: amber) { onResume() }
                    row("Galaxy Map", "map.fill") { onResume(); onOpenMap() }
                    row("Story Map", "point.3.connected.trianglepath.dotted") {
                        openStoryMap()
                    }
                    row("Preferences", "gearshape.fill") { showSettings = true }

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
            AppMark().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(hud.shipName.isEmpty ? "EV NOVA" : hud.shipName)
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

    /// Open the full-screen Story Map over the live game + current pilot. Builds
    /// a fresh guide model (indexing the mission graph) on demand; without loaded
    /// game data there's nothing to chart, so explain that instead.
    private func openStoryMap() {
        if let game = model.data.game {
            storyModel = .over(game, player: model.pilot.state)
        } else {
            info = "Load your EV Nova data to chart the storyline map."
        }
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
