import SwiftUI
import NovaSwiftKit
import NovaSwiftNet
#if canImport(GameKit)
import GameKit
#endif

/// The single Multiplayer entry point (from the in-game menu). Before a session
/// it lets you **host** or **join** a named lobby — Local (Wi-Fi) or Online (Game
/// Center) — after configuring the session rules. While in a session it shows the
/// lobby roster with host moderation (kick / ban). Fully responsive: a compact
/// stack on iPhone, comfortably centred on iPad / Mac.
struct MultiplayerHubView: View {
    @EnvironmentObject private var model: AppModel
    /// Called when a session has started and the player should drop back into flight.
    var onEnterFlight: () -> Void
    var onClose: () -> Void

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        NavigationStack {
            Group {
                if model.session.isActive {
                    LobbyRosterView(onEnterFlight: onEnterFlight, onClose: onClose)
                } else {
                    lobbyChooser
                }
            }
            .frame(maxWidth: 560)               // keep line-lengths sane on wide screens
            .frame(maxWidth: .infinity)
            .background(backdrop)
        }
        .sheet(isPresented: Binding(
            get: { model.session.pluginMismatch != nil },
            set: { if !$0 { model.session.pluginMismatch = nil } })) {
            if let mismatch = model.session.pluginMismatch {
                PluginMismatchView(lobbyName: model.session.pluginMismatchLobbyName,
                                   mismatch: mismatch)
                    .cursorHost()
            }
        }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var backdrop: some View {
        LinearGradient(colors: [.black, Color(red: 0.04, green: 0.05, blue: 0.09)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Pre-session: Browse / Host

    @State private var tab: Tab = .browse
    private enum Tab: String, CaseIterable, Identifiable { case browse = "Browse", host = "Host"; var id: String { rawValue } }
    @State private var showQuickConnect = false
    #if canImport(GameKit)
    @StateObject private var gcFlow = GameCenterFlow()
    #endif

    private var lobbyChooser: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                NovaSegmentedPicker(selection: $tab, options: Array(Tab.allCases)) { $0.rawValue }
                    .padding(.horizontal)

                switch tab {
                case .browse:
                    #if canImport(GameKit)
                    MultiplayerBrowseView(onEnterFlight: onEnterFlight, onQuickConnect: { showQuickConnect = true }, gcFlow: gcFlow)
                    #else
                    MultiplayerBrowseView(onEnterFlight: onEnterFlight, onQuickConnect: { showQuickConnect = true })
                    #endif
                case .host:
                    #if canImport(GameKit)
                    MultiplayerHostView(onEnterFlight: onEnterFlight, gcFlow: gcFlow)
                    #else
                    MultiplayerHostView(onEnterFlight: onEnterFlight)
                    #endif
                }

                CursorButton(action: onClose) {
                    Text("Close").novaFont(.button).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
        .cursorScrollable()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        // Toolbar items are system chrome the cursor can't press: Ⓑ closes, and
        // the in-view Close below is the pressable equivalent.
        .cursorCancel(onClose)
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet(onConnect: {}).cursorHost()
        }
        // An ENet join that went live: the hub's job is done, drop into flight.
        .onChange(of: model.session.isActive) { _, active in
            if active && model.crossPlay.joinInFlight { model.crossPlay.joinInFlight = false; onEnterFlight() }
        }
        .overlay {
            if let plan = model.crossPlay.pluginPlan {
                PluginPlanOverlay(plan: plan)
            }
        }
        #if canImport(GameKit)
        .sheet(isPresented: $gcFlow.showMatchmaker) {
            GameCenterMatchmakerView(
                playerGroup: model.currentPluginManifest().groupID,
                onMatch: { match in
                    gcFlow.showMatchmaker = false
                    model.startOnlineSession(match: match, role: gcFlow.role)
                    onEnterFlight()
                },
                onCancel: { gcFlow.showMatchmaker = false; model.onlineHostConfig = nil },
                onError: { gcFlow.showMatchmaker = false; model.gameCenter.lastError = $0 })
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
                .cursorHost()
        }
        #endif
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.wave.2.fill").font(.system(size: 34)).foregroundStyle(amber)
            Text("Multiplayer").novaFont(.heading).foregroundStyle(.white)
            Text("Fly, fight, and quest together - with Apple players, or with Linux, Windows and Steam Deck players.")
                .novaFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            CursorButton { showQuickConnect = true } label: {
                Label("Quick Connect", systemImage: "bolt.fill")
                    .novaFont(.button, weight: .medium).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(amber))
            }
        }
    }
}

// MARK: - Plug-in mismatch

/// Explains why a join was refused and exactly what to change: which plug-ins to
/// install + enable, which to disable, and which are the wrong version. Shown when
/// a joiner's enabled-plug-in set doesn't match the host's.
private struct PluginMismatchView: View {
    @Environment(\.dismiss) private var dismiss
    let lobbyName: String
    let mismatch: PluginMismatch

    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }
    private var warn: Color { Color(red: 1.0, green: 0.6, blue: 0.2) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 34)).foregroundStyle(warn)
                        Text("Plug-ins don't match")
                            .novaFont(.heading).foregroundStyle(.white)
                        Text("To join \(lobbyName.isEmpty ? "this lobby" : "“\(lobbyName)”") you need the same enabled plug-ins as the host.")
                            .novaFont(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    section("Install & enable", systemImage: "arrow.down.circle.fill",
                            color: .green, plugins: mismatch.missing,
                            note: "The host has these — get them from the Plug-ins screen and enable them.")
                    section("Disable", systemImage: "minus.circle.fill",
                            color: warn, plugins: mismatch.extra,
                            note: "The host isn't running these — turn them off in the Plug-ins screen.")
                    section("Update to the host's version", systemImage: "arrow.triangle.2.circlepath",
                            color: amber, plugins: mismatch.wrongVersion,
                            note: "You have these, but a different version. Reinstall the host's copy.")

                    Text("Change plug-ins from the main menu’s Plug-ins screen, then reopen Multiplayer.")
                        .novaFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .cursorScrollable()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Can't Join")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .cursorCancel { dismiss() }
        .cursorDefault { dismiss() }
        .novaResponsive()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String, color: Color,
                         plugins: [PluginRequirement], note: String) -> some View {
        if !plugins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .novaFont(.button, weight: .medium).foregroundStyle(color)
                ForEach(plugins, id: \.id) { p in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(p.name.isEmpty ? p.id : p.name)
                            .novaFont(.caption, weight: .medium).foregroundStyle(.white)
                    }
                }
                Text(note).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        }
    }
}

// MARK: - Shared bits

/// A large, tappable action card used across the hub.
struct HubActionLabel: View {
    let icon: String, title: String, subtitle: String
    private var amber: Color { Color(red: 1.0, green: 0.7, blue: 0.28) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(amber).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).novaFont(.button, weight: .medium).foregroundStyle(.white)
                Text(subtitle).novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(amber.opacity(0.25)))
        .padding(.horizontal)
    }
}
