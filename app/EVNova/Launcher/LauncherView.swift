import SwiftUI

/// The main menu: title, primary actions, and data/plug-in status.
struct LauncherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case plugins, settings, importData, about
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            StarfieldBackground()
            VStack(spacing: 28) {
                Spacer()
                titleBlock
                Spacer()
                menu
                statusLine
                Spacer()
            }
            .padding(40)
            .frame(maxWidth: 520)
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
            .frame(minWidth: 380, minHeight: 480)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 8) {
            AppMark()
                .frame(width: 96, height: 96)
            Text("EV NOVA")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .tracking(6)
                .foregroundStyle(.white)
            Text("an unofficial port")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(2)
        }
    }

    private var menu: some View {
        VStack(spacing: 12) {
            MenuButton(title: model.data.hasBaseData ? "Play" : "Play (demo)",
                       systemImage: "play.fill", prominent: true) {
                model.startGame()
            }
            HStack(spacing: 12) {
                MenuButton(title: "Plug-ins", systemImage: "puzzlepiece.extension.fill") { sheet = .plugins }
                MenuButton(title: "Settings", systemImage: "gearshape.fill") { sheet = .settings }
            }
            HStack(spacing: 12) {
                MenuButton(title: "Import Data", systemImage: "square.and.arrow.down.fill") { sheet = .importData }
                MenuButton(title: "About", systemImage: "info.circle.fill") { sheet = .about }
            }
        }
    }

    private var statusLine: some View {
        Text(model.data.status)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }
}

/// A menu button with a consistent style.
struct MenuButton: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.black : Color.white)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(prominent
                      ? AnyShapeStyle(Color.cyan)
                      : AnyShapeStyle(.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(prominent ? 0 : 0.12), lineWidth: 1)
        )
    }
}

/// A subtle animated starfield used behind menus.
struct StarfieldBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.08),
                                    Color(red: 0.05, green: 0.03, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B9
                func rnd() -> Double {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    return Double(seed % 10_000) / 10_000
                }
                for _ in 0..<220 {
                    let x = rnd() * size.width
                    let y = rnd() * size.height
                    let r = rnd() * 1.4 + 0.3
                    let a = rnd() * 0.7 + 0.2
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity(a)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
