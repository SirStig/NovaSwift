import SwiftUI

/// NovaSwift's own pre-game screen: branding + a bring-your-own-data setup
/// guide. Shown only until the player supplies their own EV Nova data (see
/// `docs/GET_THE_DATA.md`) — the instant data loads, `RootView` advances
/// straight to the authentic EV Nova main menu (`AuthenticMainMenuView`), so
/// there is no "demo" state here: without data, this screen's only job is to
/// explain the model and get the player to Import Data.
struct LauncherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?
    /// Open the wizard directly on its Import step — set when resuming a
    /// partial import (the guide steps are already done) and by the
    /// dev/automation hook in the DEBUG onAppear.
    @State private var wizardStartsAtImport = false

    private enum Sheet: String, Identifiable {
        case importData, about
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            StarfieldBackground()
            #if os(tvOS)
            // Room-distance readability: the phone-sized column is far too
            // small on a TV. The content fits a TV screen at 1.5×, so skip the
            // ScrollView (scaling inside one clips the top — the scroll
            // geometry doesn't know about the visual transform) and centre
            // the scaled column directly.
            column
                .cursorScaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            ScrollView { column }
                .cursorScrollable()
            #endif
        }
        .novaResponsive()
        .overlay { dialogOverlay }
        .onAppear {
            #if os(tvOS)
            // A partial import can only be finished over Wi-Fi, and the
            // receiver (with the address to type into a browser) only runs
            // while the wizard's Import step is on screen — so landing here
            // with files missing reopens that step immediately instead of
            // parking the player on a card.
            if model.data.hasBaseData, !model.data.isBaseDataComplete, sheet == nil {
                wizardStartsAtImport = true
                sheet = .importData
            }
            #endif
            #if DEBUG
            // Dev/automation: open the import wizard immediately so scripted
            // simulator runs can screenshot it without navigating.
            if let mode = ProcessInfo.processInfo.environment["NOVASWIFT_OPEN_IMPORT"] {
                wizardStartsAtImport = (mode == "import")
                sheet = .importData
            }
            #endif
        }
    }

    /// Full-screen dialog overlay (not a macOS `.sheet`, whose fixed card would
    /// double the panel) — matches `AuthenticMainMenuView.dialogOverlay`.
    @ViewBuilder private var dialogOverlay: some View {
        if let which = sheet {
            Group {
                switch which {
                case .importData: DataSetupWizard(onClose: { sheet = nil },
                                                  startAtImport: wizardStartsAtImport)
                case .about:      AboutView(onClose: { sheet = nil })
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
    }

    /// The launcher's single content column, shared by the scrolling (phone/
    /// desktop) and fixed 1.5×-scaled (tvOS) presentations.
    private var column: some View {
        VStack(spacing: 18) {
            hero
            if model.data.isBaseDataComplete {
                dataFoundCard
            } else if model.data.hasBaseData {
                partialDataCard
            } else {
                guideCard
            }
            bottomRow
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            AppLogo().frame(width: 68, height: 68)
            Text("NOVA SWIFT")
                .novaFont(.title, weight: .heavy, size: 30)
                .tracking(5)
                .foregroundStyle(
                    LinearGradient(colors: [.white, novaAmber.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
            Text("an unofficial EV Nova port")
                .novaFont(.caption, weight: .semibold)
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: No data yet — a slim invite into the setup wizard

    /// The launcher's only job without data is to invite the player into the
    /// full setup assistant (`DataSetupWizard`), which does the real teaching.
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bring your own game data", systemImage: "externaldrive.badge.person.crop")
                .novaFont(.body, weight: .bold)
                .foregroundStyle(novaAmber)

            Text("NovaSwift runs your own legally-obtained EV Nova — nothing copyrighted is bundled in. The setup guide walks you through it step by step, whatever device you're on.")
                .novaFont(.caption)
                .foregroundStyle(.secondary)
                // Wrap fully rather than truncate: at tvOS's larger text scale
                // the proposed height comes up short and clipped to "…".
                .fixedSize(horizontal: false, vertical: true)

            setUpButton

            Text(model.data.status)
                .novaFont(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private var setUpButton: some View { setUpButton(title: "Set Up EV Nova") }

    private func setUpButton(title: String, startAtImport: Bool = false) -> some View {
        CursorButton {
            model.audio.play(.uiSelect)
            wizardStartsAtImport = startAtImport
            sheet = .importData
        } label: {
            HStack {
                Image(systemName: "sparkles")
                Text(title)
            }
            .novaFont(.body, weight: .bold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.novaPlain)
        .foregroundStyle(.black)
        .background(
            LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: novaAmber.opacity(0.35), radius: 10, y: 4)
    }

    // MARK: Partial data — some files landed, essentials still missing

    /// Behind the auto-reopened wizard on tvOS, and the manual route back into
    /// the Import step everywhere else. Says exactly what's still missing
    /// (`status` carries the list) and keeps the door to the importer open —
    /// this state used to render `dataFoundCard`, a button-less spinner that
    /// could never advance.
    private var partialDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import incomplete", systemImage: "exclamationmark.triangle.fill")
                .novaFont(.body, weight: .bold)
                .foregroundStyle(novaAmber)

            Text(model.data.status)
                .novaFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            setUpButton(title: "Continue Import", startAtImport: true)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    // MARK: Data present — the moment before `RootView` advances to the real menu

    /// Only ever on screen for a beat: `RootView` watches `isBaseDataComplete`
    /// and advances to `.mainMenu` as soon as it flips true. Kept as real
    /// content (not just a blank frame) in case that transition ever races a
    /// render.
    private var dataFoundCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(novaAmber)
            Text("Game data loaded").novaFont(.body, weight: .bold)
            Text(model.data.status)
                .novaFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView().tint(novaAmber)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    // MARK: About / links / legal

    private var bottomRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                linkPill("About", "info.circle") { sheet = .about }
                // Not on tvOS: `Link` is a focusable system button (the focus
                // engine would inflate it — see CursorButton) and there's no
                // browser to open the URL in anyway.
                #if !os(tvOS)
                Link(destination: NovaLinks.repo) {
                    linkPillLabel("GitHub", "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.novaPlain)
                #endif
            }
            Text("Unaffiliated with Ambrosia Software / ATMOS. Bring your own game data.")
                .novaFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func linkPill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        CursorButton { model.audio.play(.uiSelect); action() } label: {
            linkPillLabel(title, icon)
        }
    }

    private func linkPillLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .novaFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }
}

/// A subtle animated starfield used behind menus.
struct StarfieldBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.06, green: 0.04, blue: 0.12),
                                    Color(red: 0.02, green: 0.02, blue: 0.06)],
                           center: .center, startRadius: 40, endRadius: 700)
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B9
                func rnd() -> Double {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    return Double(seed % 10_000) / 10_000
                }
                for _ in 0..<240 {
                    let x = rnd() * size.width, y = rnd() * size.height
                    let r = rnd() * 1.4 + 0.3, a = rnd() * 0.7 + 0.2
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity(a)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
