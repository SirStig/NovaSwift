import SwiftUI

/// The Nova Swift (modern) main menu, shown in place of `AuthenticMainMenuView`
/// when `GameSettings.modernMainMenu` is on. Same actions and dialogs as the authentic
/// menu — New Pilot / Open Pilot / Enter Ship / Settings / About / Plug-ins /
/// Import Data / Quit — but presented over the port's own hero artwork with
/// modern buttons instead of the game's `rlëD` sprite buttons. Presentation
/// only: it drives the exact same `AppModel` flow the authentic menu does.
struct ModernMainMenuView: View {
    @EnvironmentObject private var model: AppModel

    @State private var appeared = false
    @State private var sheet: Sheet?
    private enum Sheet: String, Identifiable {
        case newPilot, openPilot, settings, about, plugins, importData
        var id: String { rawValue }
    }

    /// The hero image's dominant red, reused as the menu accent.
    private let accent = Color(red: 0.86, green: 0.18, blue: 0.16)

    /// Menu-button scale for the device's width: 1× on a desktop/iPad-width
    /// window, shrinking toward `0.8` on a narrow phone. `menuButton`/
    /// `smallButton` were sized against a desktop-class window and read as
    /// oversized capsules on a phone screen — this is a straight width ratio
    /// rather than `novaResponsive()`, which by design never goes below 1×
    /// (it exists to nudge *chrome text* up on large displays, not to shrink
    /// whole buttons down on small ones).
    private func buttonScale(_ width: CGFloat) -> CGFloat {
        let reference: CGFloat = 430
        return min(max(width / reference, 0.8), 1.0)
    }

    var body: some View {
        GeometryReader { geo in
        let scale = buttonScale(geo.size.width)
        ZStack {
            // Hero background, scaled to cover the whole screen (aspect-fill).
            Image("NovaSwiftMenuBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Darken the lower half so the controls read over the artwork,
            // leaving the NOVA SWIFT wordmark up top clear.
            LinearGradient(colors: [.clear, .black.opacity(0.45), .black.opacity(0.9)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                pilotStatus

                VStack(spacing: 8 * scale) {
                    if !model.roster.isEmpty {
                        menuButton("Enter Ship", icon: "airplane.departure", prominent: true, scale: scale) {
                            // Resume the loaded pilot; open the picker when there's
                            // no unambiguous one (rather than auto-picking newest).
                            if !model.enterShip() { sheet = .openPilot }
                        }
                    }
                    menuButton("New Pilot", icon: "person.crop.circle.badge.plus", scale: scale) { sheet = .newPilot }
                    menuButton("Open Pilot", icon: "folder", scale: scale) { sheet = .openPilot }
                    menuButton("Settings", icon: "gearshape", scale: scale) { sheet = .settings }
                    menuButton("About Nova Swift", icon: "info.circle", scale: scale) { sheet = .about }
                }
                .frame(maxWidth: 288)
                .padding(.bottom, 14)

                HStack(spacing: 10) {
                    // Flight Training and Import Data moved into Settings (this menu
                    // only appears once base data is present).
                    smallButton("Plug-ins", "puzzlepiece.extension.fill", scale: scale) { sheet = .plugins }
                    #if os(macOS)
                    smallButton("Quit", "power", scale: scale) { NSApplication.shared.terminate(nil) }
                    #endif
                }
                .padding(.bottom, 34)
            }
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: appeared)
        }
        .preferredColorScheme(.dark)
        .overlay { dialogOverlay }
        .onAppear {
            withAnimation { appeared = true }
            model.audio.play(.uiSelect)
            model.prepareAudioAndData()   // ensure menu music is playing
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// A one-line "continue where you left off" readout above the buttons, when a
    /// saved pilot exists — mirrors the authentic menu's Enter-Ship status.
    @ViewBuilder private var pilotStatus: some View {
        if let save = model.roster.selected {
            let ship = model.data.game?.ship(save.player.shipType)?.displayName
            VStack(spacing: 2) {
                Text(save.displayName)
                    .novaFont(.heading, weight: .bold).foregroundStyle(.white)
                Text([save.snapshot.ratingTitle.isEmpty ? "Harmless" : save.snapshot.ratingTitle, ship]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .novaFont(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.bottom, 18)
        }
    }

    /// A primary menu button. `prominent` fills with the accent (used for the
    /// resume/Enter-Ship action); the rest are glassy outlined rows.
    private func menuButton(_ title: String, icon: String, prominent: Bool = false, scale: CGFloat = 1,
                            action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect); action()
        } label: {
            HStack(spacing: 10 * scale) {
                Image(systemName: icon).font(.callout.weight(.semibold)).frame(width: 18 * scale)
                Text(title).novaFont(.body, weight: .semibold, size: 14 * scale)
                Spacer()
            }
            .padding(.horizontal, 15 * scale).padding(.vertical, 9 * scale)
            .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.92))
            .background {
                if prominent {
                    Capsule().fill(accent.opacity(0.9))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder((prominent ? Color.white.opacity(0.3) : accent.opacity(0.35)), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A compact secondary button (Plug-ins / Import / Quit).
    private func smallButton(_ label: String, _ icon: String, scale: CGFloat = 1, action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect); action()
        } label: {
            HStack(spacing: 7 * scale) {
                Image(systemName: icon)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
            .foregroundStyle(.white.opacity(0.85))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// Dialogs presented full-screen over the menu, matching the authentic menu's
    /// overlay approach (each already fills its surface with a dimmed backdrop).
    @ViewBuilder private var dialogOverlay: some View {
        if let which = sheet {
            Group {
                switch which {
                case .newPilot:   NewPilotView(onClose: { sheet = nil })
                case .openPilot:  PilotListView(onClose: { sheet = nil })
                case .settings:   SettingsView(onClose: { sheet = nil })
                case .about:      AboutView(onClose: { sheet = nil })
                case .plugins:    PluginsView(onClose: { sheet = nil })
                case .importData: DataSetupWizard(onClose: { sheet = nil }, startAtImport: true)
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
    }
}
