import SwiftUI

/// Full settings, bound to the persisted `GameSettings`. Grouped Form so it lays
/// out and scrolls correctly on iPhone, iPad and Mac. Covers gameplay, controls,
/// graphics, audio (with a live sound test), interface and accessibility.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var previewSoundID: Int = 128
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            gameplaySection
            controlsSection
            graphicsSection
            audioSection
            interfaceSection
            accessibilitySection
            developerSection

            Section {
                Button("Reset All Settings", role: .destructive) { showResetConfirm = true }
            }
        }
        .formStyle(.grouped)
        .novaResponsive()
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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

    private var gameplaySection: some View {
        Section("Gameplay") {
            Picker("Difficulty", selection: binding(\.difficulty)) {
                ForEach(GameSettings.Difficulty.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Auto-target after firing", isOn: binding(\.autoTargetAfterFiring))
            Toggle("Confirm before landing", isOn: binding(\.confirmLanding))
            Toggle("Tutorial hints", isOn: binding(\.tutorialHints))
            Toggle("Pause when app loses focus", isOn: binding(\.pauseOnFocusLoss))
        }
    }

    private var controlsSection: some View {
        Section("Controls") {
            NavigationLink {
                ControlsView()
            } label: {
                Label("Keyboard & Controller Bindings", systemImage: "keyboard")
            }
            Picker("Touch scheme", selection: binding(\.controlScheme)) {
                ForEach(GameSettings.ControlScheme.allCases) { Text($0.label).tag($0) }
            }
            sliderRow("Turn sensitivity", binding(\.controlSensitivity), 0.4...2.0)
            sliderRow("Tilt sensitivity", binding(\.tiltSensitivity), 0.4...2.0)
            sliderRow("Stick dead zone", binding(\.stickDeadzone), 0...0.5)
            Toggle("Invert turn", isOn: binding(\.invertTurn))
            Toggle("Haptic feedback", isOn: binding(\.hapticsEnabled))
            #if os(macOS)
            Toggle("Mouse aiming", isOn: binding(\.mouseAiming))
            #endif
        }
    }

    private var graphicsSection: some View {
        Section("Graphics") {
            sliderRow("Starfield density", binding(\.starfieldDensity), 0.2...2.0)
            Picker("Frame rate", selection: binding(\.frameRateCap)) {
                ForEach(GameSettings.FrameRateCap.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Smooth sprite scaling", isOn: binding(\.smoothSprites))
            Toggle("Engine & weapon glow", isOn: binding(\.engineGlow))
            Toggle("Screen shake", isOn: binding(\.screenShake))
            Toggle("Show FPS", isOn: binding(\.showFPS))
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Mute all", isOn: binding(\.muteAll))
            sliderRow("Master", binding(\.masterVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Music", binding(\.musicVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Effects", binding(\.sfxVolume), 0...1, disabled: model.settings.muteAll)
            sliderRow("Interface", binding(\.uiVolume), 0...1, disabled: model.settings.muteAll)
            Toggle("Background music", isOn: binding(\.musicEnabled))

            soundTest
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
        Section("Interface") {
            Toggle("Use authentic EV Nova menu", isOn: binding(\.useAuthenticMenu))
            Toggle("Show radar", isOn: binding(\.showRadar))
            sliderRow("HUD opacity", binding(\.hudOpacity), 0.2...1.0)
        }
    }

    private var accessibilitySection: some View {
        Section("Accessibility") {
            Toggle("Larger HUD", isOn: binding(\.largerHUD))
            Toggle("High-contrast HUD", isOn: binding(\.highContrastHUD))
            Toggle("Reduce flashing & motion", isOn: binding(\.reduceFlashing))
            Picker("Colorblind mode", selection: binding(\.colorblindMode)) {
                ForEach(GameSettings.ColorblindMode.allCases) { Text($0.label).tag($0) }
            }
            sliderRow("UI scale", binding(\.uiScale), 0.8...1.4)
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("UI debug overlay", isOn: binding(\.uiDebugOverlay))
            Text("Draws the design-space measurement grid on authentic screens and reads the .novaPlace coordinate under your finger. Toggle live with ⇧⌘D.")
                .novaFont(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Developer")
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
