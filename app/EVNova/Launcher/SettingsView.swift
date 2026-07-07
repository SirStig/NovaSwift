import SwiftUI

/// Settings, bound to the persisted `GameSettings` model. Uses a Form so it
/// scrolls and lays out correctly on iPhone, iPad and Mac.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Controls") {
                NavigationLink {
                    ControlsView()
                } label: {
                    Label("Keyboard Controls", systemImage: "keyboard")
                }
                Picker("Touch scheme", selection: binding(\.controlScheme)) {
                    ForEach(GameSettings.ControlScheme.allCases) { Text($0.label).tag($0) }
                }
                sliderRow("Turn sensitivity", binding(\.controlSensitivity), 0.4...2.0)
                Toggle("Invert turn", isOn: binding(\.invertTurn))
            }
            Section("Interface") {
                Toggle("Use authentic EV Nova menu", isOn: binding(\.useAuthenticMenu))
                Toggle("Larger HUD", isOn: binding(\.largerHUD))
                Toggle("Show FPS", isOn: binding(\.showFPS))
            }
            Section("Graphics") {
                sliderRow("Starfield density", binding(\.starfieldDensity), 0.2...2.0)
            }
            Section("Audio") {
                sliderRow("Music", binding(\.musicVolume), 0...1)
                sliderRow("Effects", binding(\.sfxVolume), 0...1)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.commitSettings() }
        )
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            Slider(value: value, in: range)
        }
        .padding(.vertical, 2)
    }
}
