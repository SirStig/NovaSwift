import SwiftUI

/// Full settings, bound to the persisted `GameSettings`. A sidebar of
/// categories plus a scrolling detail `Form` — rather than one long stacked
/// list — so each category reads as its own short pane, like a normal game's
/// options screen. Covers gameplay, controls, graphics, audio (with a live
/// sound test), interface and accessibility. Every row control (toggle,
/// slider, picker) is one of `NovaFormControls.swift`'s authentic dark/amber
/// replacements rather than the stock iOS widgets.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}

    @State private var selectedCategory: SettingsCategory = .interface
    @State private var previewSoundID: Int = 128
    @State private var showResetConfirm = false
    @State private var showImportData = false
    @State private var showControls = false
    /// Debug: preview the full first-run setup wizard from the top, regardless of
    /// whether data is already imported.
    @State private var showWizardDebug = false

    var body: some View {
        DialogChrome(title: "Settings", onClose: onClose) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detailPane
            }
            // `content()` renders edge-to-edge inside DialogChrome's card — the
            // old single Form's own list insets masked that; this sidebar/detail
            // split has no such implicit margin, so it needs its own.
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        // No `.novaResponsive()` — it scales ambient text by window width, which
        // at the dialog's design size blows every Form row up ~1.6×. The grouped
        // Form controls want their native point sizes; `DialogChrome` then scales
        // the whole card uniformly to fit the screen. (Same reasoning as PluginsView.)
        .onAppear {
            // Populate the sound library so the sound test works (and enables menu music).
            if model.data.hasBaseData || model.data.game != nil { model.prepareAudioAndData() }
            if let first = model.audio.availableSoundIDs().first { previewSoundID = first }
        }
        .confirmationDialog("Reset every setting to its default?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) {
                model.settings.resetToDefaults()
                model.commitSettings()
            }
            Button("Cancel", role: .cancel) {}
        }
        // Data import now lives here (moved off the main menu once data is present).
        // Presented as a full-screen overlay over the settings card, matching how
        // the menus present their own dialogs.
        .overlay {
            if showImportData {
                DataSetupWizard(onClose: { showImportData = false }, startAtImport: true)
                    .transition(.opacity)
                    .preferredColorScheme(.dark)
            }
        }
        // `ControlsView` relies on `.navigationTitle`/`.toolbar` for its title and
        // Done button, which need an actual navigation host to render at all —
        // `DialogChrome` is a plain card, not a `NavigationStack`, so this can't
        // be a `NavigationLink` pushed from the Form above (that's what left the
        // row permanently inert). A sheet supplies its own dismissible container;
        // wrapping it in a `NavigationStack` here is what makes the title/Done
        // button actually appear.
        .sheet(isPresented: $showControls) {
            NavigationStack { ControlsView() }
                .frame(minWidth: 480, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        // Debug: the full first-run wizard from the welcome step (no `startAtImport`),
        // so the whole guide can be reviewed even after data is imported.
        .overlay {
            if showWizardDebug {
                DataSetupWizard(onClose: { showWizardDebug = false })
                    .transition(.opacity)
                    .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: Navigation

    /// The category rail: one row per `SettingsCategory`, plus a pinned
    /// destructive reset button underneath — it's a global action, not any
    /// one category's content, so it lives outside the switched detail pane.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsCategory.allCases) { category in
                NovaSelectRow(title: category.title, selected: category == selectedCategory,
                              systemImage: category.systemImage) {
                    EmptyView()
                } action: {
                    model.audio.play(.uiSelect)
                    selectedCategory = category
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { showResetConfirm = true } label: {
                Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                    .novaFont(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(width: 176)
        .frame(maxHeight: .infinity)
    }

    /// The selected category's section(s), in the same scrolling `Form` the
    /// screen always used — just showing one category's worth at a time
    /// instead of all ten stacked together.
    private var detailPane: some View {
        Form {
            switch selectedCategory {
            case .interface:
                presentationSection
                hudInterfaceSection
            case .gameplay:
                gameplaySection
            case .controls:
                controlsSection
            case .graphics:
                graphicsSection
            case .audio:
                audioSection
            case .accessibility:
                accessibilitySection
            case .data:
                storageSection
                developerSection
            }
        }
        .formStyle(.grouped)
        .novaHiddenScrollContentBackground()
        .toggleStyle(NovaToggleStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    /// A one-tap preset stamps the interface toggles below; editing any of them
    /// flips the selector to "Custom". `.custom` isn't user-selectable — it only
    /// reflects a hand-mixed state.
    private var presetBinding: Binding<GameSettings.UIMode> {
        Binding(
            get: { model.settings.matchedPreset },
            set: { newValue in
                guard newValue != .custom else { return }
                model.settings.applyPreset(newValue)
                model.commitSettings()
            }
        )
    }

    @ViewBuilder
    private var presentationSection: some View {
        Section {
            NovaSegmentedPicker(selection: presetBinding, options: GameSettings.UIMode.allCases) { $0.label }
        } header: {
            sectionHeader("Presentation", icon: "sparkles.tv")
        } footer: {
            Text(model.settings.matchedPreset.blurb
                 + " Presets are templates — pick one to set the interface options below, then fine-tune any of them individually.")
        }

        Section {
            Toggle("Full-screen galaxy map", isOn: binding(\.fullscreenGalaxyMap))
            Toggle("Modern main menu", isOn: binding(\.modernMainMenu))
            Toggle("Modern dialog chrome", isOn: binding(\.modernDialogs))
            Toggle("Modern HUD", isOn: binding(\.modernHUD))
            Toggle("Sidebar pause menu", isOn: binding(\.sidebarPauseMenu))
            Toggle("Show mission storyline tags", isOn: binding(\.showMissionStorylineTags))
        } header: {
            sectionHeader("Interface Options", icon: "slider.horizontal.3")
        } footer: {
            Text("Mix the port's modern touches over the authentic EV Nova presentation. Full-screen map opens the galaxy map without its dialog frame. With the sidebar pause menu off (the Classic default), pausing saves and drops straight to the main menu; on it opens the port's own menu. On mobile the sidebar is always available via the ☰ button. Storyline tags mark missions that continue a reconstructed campaign and jump to it in the Story Guide — an aftermarket hint the original game never had.")
        }
    }

    private var gameplaySection: some View {
        Section {
            NovaMenuPicker(title: "Difficulty", selection: binding(\.difficulty),
                           options: GameSettings.Difficulty.allCases) { $0.label }
            NovaMenuPicker(title: "System Aliveness", selection: binding(\.systemAliveness),
                           options: GameSettings.SystemAliveness.allCases) { $0.label }
            Text(model.settings.systemAliveness.blurb)
                .novaFont(.caption).foregroundStyle(.secondary)
            NovaSegmentedPicker(selection: binding(\.gameSpeed), options: GameSettings.GameSpeed.allCases) { $0.label }
                .disabled(model.session.isActive)
            if model.session.isActive {
                Text("Set by the lobby host while in a co-op session.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
            Toggle("Auto-target after firing", isOn: binding(\.autoTargetAfterFiring))
            Toggle("Auto-landing", isOn: binding(\.autoLanding))
            Toggle("Confirm before landing", isOn: binding(\.confirmLanding))
            Toggle("Tutorial hints", isOn: binding(\.tutorialHints))
            if model.settings.tutorialHints {
                Button("Show all hints again") {
                    model.audio.play(.uiSelect)
                    HintTracker.resetAll()
                    // The first-flight controls card and the one-time
                    // spaceport/BBS/outfitter banners all clear together.
                    UserDefaults.standard.removeObject(forKey: "novaswift.seenFlightHints")
                }
            }
            // Replayable flight-training run, moved here off the main menu. Needs
            // decoded ship/outfit data to fly, so it's gated on base data; close
            // Settings first so the tutorial hands back to a clean menu.
            if model.data.hasBaseData {
                Button {
                    model.audio.play(.uiSelect)
                    onClose()
                    model.startTutorial(exit: .menu)
                } label: {
                    Label("Flight Training", systemImage: "graduationcap.fill")
                }
            }
            Toggle("Pause when app loses focus", isOn: binding(\.pauseOnFocusLoss))
        } header: {
            sectionHeader("Gameplay", icon: "gamecontroller")
        } footer: {
            Text("Difficulty scales the damage you take, from Very Easy for a mostly-story run up to Hard. System Aliveness controls how much traffic systems carry and how often ships actually land — Authentic thins it out and sends most traders cruising through instead of docking, closer to the original game's pace; Bustling pushes past the default for even busier systems. Game speed sets the overall pace — 1× is the faithful, unhurried EV Nova cruise; drop to 0.5× for more room to react in a dogfight, or step it up to 8× when you'd rather not wait. Auto-target locks onto the nearest hostile the moment you open fire. With Auto-landing on, targeting a planet or station and pressing Land flies you there and sets down automatically. Tutorial hints show one-time tips as you play — “Show all hints again” brings them back.")
        }
    }

    private var controlsSection: some View {
        Section {
            Button {
                showControls = true
            } label: {
                Label("Keyboard & Controller Bindings", systemImage: "keyboard")
            }
            NovaMenuPicker(title: "Touch flying", selection: binding(\.controlScheme),
                           options: GameSettings.ControlScheme.allCases) { $0.label }
            sliderRow("Turn sensitivity", binding(\.controlSensitivity), 0.4...2.0)
            if model.settings.controlScheme == .tilt {
                sliderRow("Tilt sensitivity", binding(\.tiltSensitivity), 0.4...2.0)
            }
            sliderRow("Stick dead zone", binding(\.stickDeadzone), 0...0.5)
            sliderRow("Controller cursor speed", binding(\.cursorSensitivity), 0.4...2.0)
            Toggle("Invert turn direction", isOn: binding(\.invertTurn))
            Toggle("Haptic feedback", isOn: binding(\.hapticsEnabled))
            #if os(macOS)
            Toggle("Aim toward mouse cursor", isOn: binding(\.mouseAiming))
            #endif
        } header: {
            sectionHeader("Controls", icon: "dpad")
        } footer: {
            Text("Touch flying sets how the on-screen controls steer your ship. The dead zone is how far a stick or drag must move before it registers.")
        }
    }

    private var graphicsSection: some View {
        Section {
            sliderRow("Starfield density", binding(\.starfieldDensity), 0.2...2.0)
            sliderRow("Camera zoom", binding(\.cameraZoom), 0.5...2.5)
            NovaMenuPicker(title: "Frame rate limit", selection: binding(\.frameRateCap),
                           options: GameSettings.FrameRateCap.allCases) { $0.label }
            Toggle("Smooth sprite scaling", isOn: binding(\.smoothSprites))
            Toggle("Engine & weapon glow", isOn: binding(\.engineGlow))
            Toggle("Screen shake", isOn: binding(\.screenShake))
        } header: {
            sectionHeader("Graphics", icon: "sparkles")
        } footer: {
            Text("EV Nova's art is pixel art — leave smooth scaling off for the crisp, faithful look. Camera zoom is world pixels shown per screen point; 1.0 is the original's own native scale (higher shows more of the system at once, everything reading smaller). iPhone starts a bit further out than that by default, since its screen is far fewer points across than a Mac window or iPad. A lower frame-rate limit saves battery on mobile.")
        }
    }

    private var audioSection: some View {
        Section {
            Toggle("Mute all", isOn: binding(\.muteAll))
            sliderRow("Master", binding(\.masterVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Music", binding(\.musicVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Effects", binding(\.sfxVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Interface", binding(\.uiVolume), 0...1, disabled: model.settings.muteAll)
            Toggle("Background music", isOn: binding(\.musicEnabled))

            soundTest
        } header: {
            sectionHeader("Audio", icon: "speaker.wave.2")
        } footer: {
            Text("Master scales everything; the individual sliders balance music, weapon/engine effects and interface clicks beneath it.")
        }
    }

    @ViewBuilder
    private var soundTest: some View {
        let ids = model.audio.availableSoundIDs()
        if ids.isEmpty {
            Text("Import game data to preview sounds.")
                .novaFont(.caption).foregroundStyle(.secondary)
        } else {
            NovaMenuPicker(title: "Preview sound", selection: $previewSoundID, options: ids) { label(forSound: $0) }
            HStack {
                Button {
                    model.audio.preview(previewSoundID)
                } label: {
                    Label("Play Sound", systemImage: "play.circle")
                }
                Spacer()
                Button {
                    model.audio.preview(GameAudio.GameEvent.uiSelect.soundID)
                } label: {
                    Label("Test Beep", systemImage: "speaker.wave.2")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    /// On-screen HUD readouts and their look — grouped with the presentation
    /// section above so all the interface/UI controls sit together.
    private var hudInterfaceSection: some View {
        Section {
            Toggle("Show radar", isOn: binding(\.showRadar))
            Toggle("Show planet names", isOn: binding(\.showPlanetLabels))
            NovaMenuPicker(title: "Hull / shield bars", selection: binding(\.shipBarPosition),
                           options: GameSettings.ShipBarPosition.allCases) { $0.label }
            sliderRow("HUD opacity", binding(\.hudOpacity), 0.2...1.0)
            Toggle("Larger HUD", isOn: binding(\.largerHUD))
            Toggle("High-contrast HUD", isOn: binding(\.highContrastHUD))
            sliderRow("Overall UI scale", binding(\.uiScale), 0.8...1.4)
            Toggle("Show FPS counter", isOn: binding(\.showFPS))
        } header: {
            sectionHeader("HUD & Interface", icon: "rectangle.on.rectangle")
        } footer: {
            Text("On-screen readouts and their look, in every presentation. Hull/shield bars over ships weren't in the original — set them to Hidden for the authentic look, and the original never labelled planets in flight either. Larger and high-contrast HUD affect the modern HUD; UI scale resizes menus and dialogs everywhere.")
        }
    }

    private var storageSection: some View {
        Section {
            Toggle("iCloud pilot sync", isOn: Binding(
                get: { model.settings.iCloudSaves },
                set: { model.setICloudSaves($0) }   // persists + migrates saves
            ))
            HStack {
                Text("Saved to")
                Spacer()
                Text(model.roster.isCloudBacked ? "iCloud" : "This device")
                    .foregroundStyle(.secondary)
            }
            #if canImport(CloudKit)
            Toggle("iCloud game data sync", isOn: Binding(
                get: { model.settings.iCloudGameData },
                set: { on in
                    model.settings.iCloudGameData = on
                    model.commitSettings()
                    // Turning it on should take effect now, not next launch.
                    if on { Task { await model.syncGameDataWithCloud() } }
                }
            ))
            #endif
            // Re-import or update game data. Only offered once data is already
            // present — the first-run import lives on the pre-data launcher.
            if model.data.hasBaseData {
                Button {
                    model.audio.play(.uiSelect)
                    showImportData = true
                } label: {
                    Label("Import Data", systemImage: "square.and.arrow.down.fill")
                }
            }
        } header: {
            sectionHeader("Saved Games", icon: "externaldrive.badge.icloud")
        } footer: {
            Text(model.settings.iCloudSaves && !model.roster.isCloudBacked
                 ? "iCloud is enabled but not available right now (sign in to iCloud on this device). Pilots are saved on this device and will sync once iCloud is reachable."
                 : "Keeps your pilots — all save slots and their auto-backups — in sync across your devices. Turning this off moves them back onto this device. Your saves are never deleted by switching. Game data sync keeps a copy of your imported Nova Files in your private iCloud, so other devices set themselves up without re-importing.")
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle("Reduce flashing & motion", isOn: binding(\.reduceFlashing))
            NovaMenuPicker(title: "Colorblind mode", selection: binding(\.colorblindMode),
                           options: GameSettings.ColorblindMode.allCases) { $0.label }
        } header: {
            sectionHeader("Accessibility", icon: "accessibility")
        } footer: {
            Text("Reduce flashing calms the exhaust flicker, screen shake and jump flash. (Larger HUD, high-contrast HUD and UI scale are under HUD & Interface.)")
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("Debug mode", isOn: binding(\.debugModeEnabled))
            if model.settings.debugModeEnabled {
                Button {
                    model.audio.play(.uiSelect)
                    showWizardDebug = true
                } label: {
                    Label("Preview Setup Wizard", systemImage: "sparkles.rectangle.stack")
                }
            }
        } header: {
            sectionHeader("Developer", icon: "hammer")
        } footer: {
            Text("Shows an in-game debug button that opens the debug suite: the UI measurement overlay, a performance stress test, and more developer tools as we build them. Preview Setup Wizard replays the full first-run data guide from the top, even with data already imported.")
        }
    }

    // MARK: Helpers

    private func label(forSound id: Int) -> String {
        if let name = model.audio.soundName(id), !name.isEmpty { return "\(id) — \(name)" }
        return "Sound \(id)"
    }

    /// Icon + amber Charcoal title, matching the dialog's own heading —
    /// replaces the default gray SF-Symbol `Label` section headers used before.
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .novaFont(.button, weight: .semibold)
            .foregroundStyle(novaAmber)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.commitSettings() }
        )
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                           disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).novaFont(.body)
                Spacer()
                Text("\(Int((value.wrappedValue) * 100))%")
                    .novaFont(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            NovaSlider(value: value, range: range)
        }
        .padding(.vertical, 2)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// The sidebar's categories — 10 old stacked sections consolidated into 7,
/// each shown as its own pane instead of one long scroll.
private enum SettingsCategory: CaseIterable, Identifiable, Hashable {
    case interface, gameplay, controls, graphics, audio, accessibility, data

    var id: Self { self }

    var title: String {
        switch self {
        case .interface: return "Interface"
        case .gameplay: return "Gameplay"
        case .controls: return "Controls"
        case .graphics: return "Graphics"
        case .audio: return "Audio"
        case .accessibility: return "Accessibility"
        case .data: return "Data & Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .interface: return "sparkles.tv"
        case .gameplay: return "gamecontroller"
        case .controls: return "dpad"
        case .graphics: return "sparkles"
        case .audio: return "speaker.wave.2"
        case .accessibility: return "accessibility"
        case .data: return "externaldrive.badge.icloud"
        }
    }
}
