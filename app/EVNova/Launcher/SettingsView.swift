import SwiftUI

/// Settings form bound to the persisted `GameSettings` model.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Controls") {
                Picker("Scheme", selection: binding(\.controlScheme)) {
                    ForEach(GameSettings.ControlScheme.allCases) { Text($0.label).tag($0) }
                }
                sliderRow("Turn sensitivity", binding(\.controlSensitivity), 0.4...2.0)
                Toggle("Invert turn", isOn: binding(\.invertTurn))
            }
            Section("Graphics") {
                sliderRow("Starfield density", binding(\.starfieldDensity), 0.2...2.0)
                Toggle("Show FPS", isOn: binding(\.showFPS))
            }
            Section("Audio") {
                sliderRow("Music", binding(\.musicVolume), 0...1)
                sliderRow("Effects", binding(\.sfxVolume), 0...1)
            }
            Section("Accessibility") {
                Toggle("Larger HUD", isOn: binding(\.largerHUD))
            }
        }
        .navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.commitSettings() }
        )
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Slider(value: value, in: range)
        }
    }
}
