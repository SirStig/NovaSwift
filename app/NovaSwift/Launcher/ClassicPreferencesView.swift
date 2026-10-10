import SwiftUI
import NovaSwiftKit

/// The original's Preferences window: `Menu_RunSettingsDialog` 0x00488650,
/// DLOG/DITL 4003, drawn with the native controls at the DITL's own rects.
/// Item map (DITL index → preference), from the dialog's event loop:
/// 1 Share Processor Time, 4 sound-volume label (STR# 136) with the PICT
/// 135/134 down/up arrows at 5/6, 7 Intro Music, 8 QuickTime Movies,
/// 9 Smoke Trails, 10 Run in a window, 11 Ship Animations, 12 Engine Glows,
/// 13 Running Lights, 14 Weapon Effects, 15 Key Settings, 17 Parallax
/// Starfield, 19 Ambient Sounds, 20 Hyperspace Effects, 21 Check For Updates,
/// 23 brightness label (STR# 139) with arrows 24/25, 0 OK. Defaults are
/// `NovaPrefs_ResetToDefaults` (volume 5, brightness 3, all on but updates).
struct ClassicPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    var onClose: () -> Void
    /// Opens the port's own settings (everything the original never had).
    var onPortOptions: () -> Void

    @State private var showKeys = false

    private func flag(_ kp: WritableKeyPath<GameSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: kp] },
                set: { model.settings[keyPath: kp] = $0; model.commitSettings() })
    }

    /// The preference stored inverted in the exe (hyperspace effects).
    private var hyperspace: Binding<Bool> {
        Binding(get: { !model.settings.noHyperspaceEffects },
                set: { model.settings.noHyperspaceEffects = !$0; model.commitSettings() })
    }

    private func step(_ kp: WritableKeyPath<GameSettings, Int>, by d: Int, max m: Int) {
        model.settings[keyPath: kp] = Swift.min(m, Swift.max(0, model.settings[keyPath: kp] + d))
        if kp == \GameSettings.soundVolumeStep {
            // 5 is the stock level (full gain here); lower steps attenuate.
            model.settings.masterVolume = Swift.min(1, Double(model.settings.soundVolumeStep) / 5)
        }
        model.commitSettings()
    }

    private func label(_ list: Int, _ n: Int) -> String {
        model.data.game?.stringList(list)?.string(at: n + 1) ?? ""
    }

    var body: some View {
        let s = model.settings
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ClassicDITLDialog(
                game: model.data.game, graphics: model.uiGraphics, id: 4003,
                fallbackSize: CGSize(width: 340, height: 300),
                texts: [4: label(136, s.soundVolumeStep),
                        23: s.brightnessStep < 7 ? label(139, s.brightnessStep) : ""],
                checks: [1: flag(\.shareProcessorTime), 7: flag(\.introMusic), 8: flag(\.playMovies),
                         9: flag(\.smokeTrails), 11: flag(\.shipAnimations), 12: flag(\.engineGlow),
                         13: flag(\.runningLights), 14: flag(\.weaponEffects),
                         17: flag(\.parallaxStarfield), 19: flag(\.ambientSounds),
                         20: hyperspace, 21: flag(\.checkForUpdates)],
                actions: [0: onClose, 15: { showKeys = true },
                          5: { step(\.soundVolumeStep, by: -1, max: 8) },
                          6: { step(\.soundVolumeStep, by: 1, max: 8) },
                          24: { step(\.brightnessStep, by: -1, max: 6) },
                          25: { step(\.brightnessStep, by: 1, max: 6) }],
                // "Run in a window" has no meaning outside the Windows build.
                hidden: [10],
                defaultItem: 0, cancelItem: 0)
            VStack {
                Spacer()
                Button("Port options…", action: onPortOptions)
                    .buttonStyle(.plain)
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showKeys) {
            NavigationStack { ControlsView() }
                .frame(minWidth: 480, minHeight: 560)
                .preferredColorScheme(.dark)
        }
    }
}
