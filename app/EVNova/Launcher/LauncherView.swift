import SwiftUI

/// The main menu: title, primary actions, and data/plug-in status.
struct LauncherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case plugins, settings, importData, about
        var id: String { rawValue }
    }

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        ZStack {
            StarfieldBackground()
            VStack(spacing: 0) {
                Spacer()
                hero
                Spacer()
                actions
                    .frame(maxWidth: 460)
                statusPill
                    .padding(.top, 18)
                Spacer()
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .plugins: PluginsView()
                case .settings: SettingsView()
                case .importData: ImportDataView()
                case .about: AboutView()
                }
            }
            .frame(minWidth: 400, minHeight: 500)
            .preferredColorScheme(.dark)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            AppMark()
                .frame(width: 116, height: 116)
                .background(
                    Circle().fill(amber.opacity(0.18)).blur(radius: 40).frame(width: 200, height: 200)
                )
            Text("EV NOVA")
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .tracking(8)
                .foregroundStyle(
                    LinearGradient(colors: [.white, amber.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: amber.opacity(0.35), radius: 12)
            Text("an unofficial port")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button {
                model.audio.play(.uiSelect)
                model.startGame()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text(model.data.hasBaseData ? "Play" : "Play Demo")
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(
                LinearGradient(colors: [amber, amber.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: amber.opacity(0.4), radius: 16, y: 6)

            HStack(spacing: 12) {
                tile("Plug-ins", "puzzlepiece.extension.fill") { sheet = .plugins }
                tile("Settings", "gearshape.fill") { sheet = .settings }
                tile("Import", "square.and.arrow.down.fill") { sheet = .importData }
                tile("About", "info.circle.fill") { sheet = .about }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { model.audio.play(.uiSelect); action() } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private var statusPill: some View {
        Text(model.data.status)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: Capsule())
            .frame(maxWidth: 460)
    }

    private var footer: some View {
        Text("Unaffiliated with Ambrosia Software / ATMOS. Bring your own game data.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
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
