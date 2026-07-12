import SwiftUI

/// The Nova Swift (modern) main menu, shown in place of `AuthenticMainMenuView`
/// when `GameSettings.modernUI` is on. Same actions and dialogs as the authentic
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

    var body: some View {
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

                VStack(spacing: 8) {
                    if !model.roster.isEmpty {
                        menuButton("Enter Ship", icon: "airplane.departure", prominent: true) {
                            // Resume the loaded pilot; open the picker when there's
                            // no unambiguous one (rather than auto-picking newest).
                            if !model.enterShip() { sheet = .openPilot }
                        }
                    }
                    menuButton("New Pilot", icon: "person.crop.circle.badge.plus") { sheet = .newPilot }
                    menuButton("Open Pilot", icon: "folder") { sheet = .openPilot }
                    menuButton("Settings", icon: "gearshape") { sheet = .settings }
                    menuButton("About Nova Swift", icon: "info.circle") { sheet = .about }
                }
                .frame(maxWidth: 288)
                .padding(.bottom, 14)

                HStack(spacing: 10) {
                    smallButton("Plug-ins", "puzzlepiece.extension.fill") { sheet = .plugins }
                    smallButton("Import Data", "square.and.arrow.down.fill") { sheet = .importData }
                    #if os(macOS)
                    smallButton("Quit", "power") { NSApplication.shared.terminate(nil) }
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
    private func menuButton(_ title: String, icon: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect); action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.callout.weight(.semibold)).frame(width: 18)
                Text(title).novaFont(.body, weight: .semibold, size: 14)
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
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
    private func smallButton(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect); action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
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
                case .importData: ImportDataView(onClose: { sheet = nil })
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
    }
}
