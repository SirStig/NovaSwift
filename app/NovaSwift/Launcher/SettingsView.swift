import SwiftUI

/// Full settings, bound to the persisted `GameSettings`. Grouped Form so it lays
/// out and scrolls correctly on iPhone, iPad and Mac. Covers gameplay, controls,
/// graphics, audio (with a live sound test), interface and accessibility.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}

    @State private var previewSoundID: Int = 128
    @State private var showResetConfirm = false

    var body: some View {
        DialogChrome(title: "Settings", onClose: onClose) {
            Form {
                uiModeSection
                gameplaySection
                controlsSection
                graphicsSection
                audioSection
                interfaceSection
                storageSection
                accessibilitySection
                developerSection

                Section {
                    Button("Reset All Settings", role: .destructive) { showResetConfirm = true }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
    }

    // MARK: Sections

    private var uiModeSection: some View {
        Section {
            Picker("Interface", selection: binding(\.uiMode)) {
                ForEach(GameSettings.UIMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("Presentation", systemImage: "sparkles.tv")
        } footer: {
            Text(model.settings.uiMode.blurb
                 + " This changes how the interface is presented; the individual options below still apply in every mode.")
        }
    }

    private var gameplaySection: some View {
        Section {
            Picker("Difficulty", selection: binding(\.difficulty)) {
                ForEach(GameSettings.Difficulty.allCases) { Text($0.label).tag($0) }
            }
            Picker("Game speed", selection: binding(\.gameSpeed)) {
                ForEach(GameSettings.GameSpeed.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
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
            Toggle("Pause when app loses focus", isOn: binding(\.pauseOnFocusLoss))
        } header: {
            Label("Gameplay", systemImage: "gamecontroller")
        } footer: {
            Text("Difficulty scales the damage you take. Game speed sets the overall pace — 1× is the faithful, unhurried EV Nova cruise; step it up to 8× when you'd rather not wait. Auto-target locks onto the nearest hostile the moment you open fire. With Auto-landing on, targeting a planet or station and pressing Land flies you there and sets down automatically. Tutorial hints show one-time tips as you play — “Show all hints again” brings them back.")
        }
    }

    private var controlsSection: some View {
        Section {
            NavigationLink {
                ControlsView()
            } label: {
                Label("Keyboard & Controller Bindings", systemImage: "keyboard")
            }
            Picker("Touch flying", selection: binding(\.controlScheme)) {
                ForEach(GameSettings.ControlScheme.allCases) { Text($0.label).tag($0) }
            }
            sliderRow("Turn sensitivity", binding(\.controlSensitivity), 0.4...2.0)
            if model.settings.controlScheme == .tilt {
                sliderRow("Tilt sensitivity", binding(\.tiltSensitivity), 0.4...2.0)
            }
            sliderRow("Stick dead zone", binding(\.stickDeadzone), 0...0.5)
            Toggle("Invert turn direction", isOn: binding(\.invertTurn))
            Toggle("Haptic feedback", isOn: binding(\.hapticsEnabled))
            #if os(macOS)
            Toggle("Aim toward mouse cursor", isOn: binding(\.mouseAiming))
            #endif
        } header: {
            Label("Controls", systemImage: "dpad")
        } footer: {
            Text("Touch flying sets how the on-screen controls steer your ship. The dead zone is how far a stick or drag must move before it registers.")
        }
    }

    private var graphicsSection: some View {
        Section {
            sliderRow("Starfield density", binding(\.starfieldDensity), 0.2...2.0)
            Picker("Frame rate limit", selection: binding(\.frameRateCap)) {
                ForEach(GameSettings.FrameRateCap.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Smooth sprite scaling", isOn: binding(\.smoothSprites))
            Toggle("Engine & weapon glow", isOn: binding(\.engineGlow))
            Toggle("Screen shake", isOn: binding(\.screenShake))
            Picker("Hull / shield bars", selection: binding(\.shipBarPosition)) {
                ForEach(GameSettings.ShipBarPosition.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Show FPS counter", isOn: binding(\.showFPS))
        } header: {
            Label("Graphics", systemImage: "sparkles")
        } footer: {
            Text("EV Nova's art is pixel art — leave smooth scaling off for the crisp, faithful look. Hull/shield bars over ships weren't in the original — set them to Hidden for the authentic look. A lower frame-rate limit saves battery on mobile.")
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
            Label("Audio", systemImage: "speaker.wave.2")
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
            Picker("Preview sound", selection: $previewSoundID) {
                ForEach(ids, id: \.self) { id in
                    Text(label(forSound: id)).tag(id)
                }
            }
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

    private var interfaceSection: some View {
        Section {
            Toggle("Show radar", isOn: binding(\.showRadar))
            Toggle("Show planet names", isOn: binding(\.showPlanetLabels))
            sliderRow("HUD opacity", binding(\.hudOpacity), 0.2...1.0)
        } header: {
            Label("Interface", systemImage: "rectangle.on.rectangle")
        } footer: {
            Text("The Nova Swift presentation mode swaps the authentic status bar, menus and dialogs for the port's own modern UI. The original never labelled planets in flight — leave planet names off for the faithful look.")
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
        } header: {
            Label("Saved Games", systemImage: "externaldrive.badge.icloud")
        } footer: {
            Text(model.settings.iCloudSaves && !model.roster.isCloudBacked
                 ? "iCloud is enabled but not available right now (sign in to iCloud on this device). Pilots are saved on this device and will sync once iCloud is reachable."
                 : "Keeps your pilots — all save slots and their auto-backups — in sync across your devices. Turning this off moves them back onto this device. Your saves are never deleted by switching.")
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle("Larger HUD", isOn: binding(\.largerHUD))
            Toggle("High-contrast HUD", isOn: binding(\.highContrastHUD))
            Toggle("Reduce flashing & motion", isOn: binding(\.reduceFlashing))
            Picker("Colorblind mode", selection: binding(\.colorblindMode)) {
                ForEach(GameSettings.ColorblindMode.allCases) { Text($0.label).tag($0) }
            }
            sliderRow("Overall UI scale", binding(\.uiScale), 0.8...1.4)
        } header: {
            Label("Accessibility", systemImage: "accessibility")
        } footer: {
            Text("Reduce flashing calms the exhaust flicker, screen shake and jump flash. UI scale resizes menus and dialogs everywhere.")
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("Debug mode", isOn: binding(\.debugModeEnabled))
        } header: {
            Label("Developer", systemImage: "hammer")
        } footer: {
            Text("Shows an in-game debug button that opens the debug suite: the UI measurement overlay, a performance stress test, and more developer tools as we build them.")
        }
    }

    // MARK: Helpers

    private func label(forSound id: Int) -> String {
        if let name = model.audio.soundName(id), !name.isEmpty { return "\(id) — \(name)" }
        return "Sound \(id)"
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
            Slider(value: value, in: range)
        }
        .padding(.vertical, 2)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
