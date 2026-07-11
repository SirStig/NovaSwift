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
    @State private var platform: GuidePlatform = .defaultForDevice

    private enum Sheet: String, Identifiable {
        case importData, about
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            StarfieldBackground()
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    if model.data.hasBaseData {
                        dataFoundCard
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
        }
        .novaResponsive()
        .overlay { dialogOverlay }
    }

    /// Full-screen dialog overlay (not a macOS `.sheet`, whose fixed card would
    /// double the panel) — matches `AuthenticMainMenuView.dialogOverlay`.
    @ViewBuilder private var dialogOverlay: some View {
        if let which = sheet {
            Group {
                switch which {
                case .importData: ImportDataView(onClose: { sheet = nil })
                case .about:      AboutView(onClose: { sheet = nil })
                }
            }
            .transition(.opacity)
            .preferredColorScheme(.dark)
        }
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

    // MARK: No data yet — the setup guide

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bring your own game data", systemImage: "externaldrive.badge.person.crop")
                .novaFont(.body, weight: .bold)
                .foregroundStyle(novaAmber)

            Text("NovaSwift never bundles EV Nova's copyrighted data. Import your own legally-obtained copy to unlock the real game.")
                .novaFont(.caption)
                .foregroundStyle(.secondary)

            Picker("Platform", selection: $platform) {
                ForEach(GuidePlatform.allCases) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(platform.steps.enumerated()), id: \.offset) { i, step in
                    stepRow(number: i + 1, text: step)
                }
            }

            importButton

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

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .novaFont(.caption, weight: .bold)
                .foregroundStyle(.black)
                .frame(width: 17, height: 17)
                .background(Circle().fill(novaAmber))
            Text(text)
                .novaFont(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importButton: some View {
        Button {
            model.audio.play(.uiSelect)
            sheet = .importData
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                Text("Import Game Data")
            }
            .novaFont(.body, weight: .bold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(
            LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: novaAmber.opacity(0.35), radius: 10, y: 4)
    }

    // MARK: Data present — the moment before `RootView` advances to the real menu

    /// Only ever on screen for a beat: `RootView` watches `hasBaseData` and
    /// advances to `.mainMenu` as soon as it flips true. Kept as real content
    /// (not just a blank frame) in case that transition ever races a render.
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
                Link(destination: NovaLinks.repo) {
                    linkPillLabel("GitHub", "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.plain)
            }
            Text("Unaffiliated with Ambrosia Software / ATMOS. Bring your own game data.")
                .novaFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func linkPill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { model.audio.play(.uiSelect); action() } label: {
            linkPillLabel(title, icon)
        }
        .buttonStyle(.plain)
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

/// Which platform's setup steps the guide card shows.
private enum GuidePlatform: String, CaseIterable, Identifiable {
    case mac = "Mac"
    case mobile = "iPhone & iPad"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .mobile: return "ipad.and.iphone"
        }
    }

    var steps: [String] {
        switch self {
        case .mac:
            return [
                "Locate your legally-owned EV Nova install (or an extracted “Nova Files” folder).",
                "Tap Import Game Data below and choose that folder, or a single .rez/.ndat file.",
                "NovaSwift copies what it needs into its own app data folder — your original files are never modified.",
            ]
        case .mobile:
            return [
                "Get your EV Nova data onto this device — AirDrop, the Files app, or “Open in NovaSwift” from another app.",
                "Tap Import Game Data and pick the folder or file from the file browser.",
                "Everything is decoded on-device — nothing is uploaded anywhere.",
            ]
        }
    }

    static var defaultForDevice: GuidePlatform {
        #if os(macOS)
        return .mac
        #else
        return .mobile
        #endif
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
