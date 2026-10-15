import SwiftUI
import NovaSwiftNet

/// In-flight chat cluster — a chat button + collapsible panel.
/// Shown **only while a multiplayer session is live**; renders nothing in
/// single-player so no multiplayer chrome clutters the solo HUD. A session is
/// started from the in-game menu ("Host Local Co-op"), not from here.
///
/// The empty regions of the enclosing `VStack` have no background, so they don't
/// intercept the tap/drag-to-fly steering underneath — only the button and panel
/// are hit-testable.
struct MultiplayerChatCluster: View {
    @ObservedObject var session: MultiplayerSession
    /// True while the on-screen touch controls own the bottom of the screen.
    /// Their turn cluster sits bottom-left at the same inset this cluster
    /// normally uses, so the chat moves up beside the Menu button instead.
    var touchControlsVisible = false
    @State private var showChat = false

    var body: some View {
        if session.isActive {
            if touchControlsVisible {
                // Top-left, to the right of the hamburger Menu button; the panel
                // hangs down from the button.
                VStack(alignment: .leading, spacing: 8) {
                    ChatButton(session: session, showChat: $showChat)
                    if showChat {
                        ChatOverlayView(session: session, isPresented: $showChat)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, Self.menuButtonClearance)
                .padding(.top, 14)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if showChat {
                        ChatOverlayView(session: session, isPresented: $showChat)
                    }
                    ChatButton(session: session, showChat: $showChat)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
    }

    /// Leading inset that clears `GameContainerView`'s top-left menu button
    /// (14pt leading + a ~44pt cap) plus a gap.
    private static let menuButtonClearance: CGFloat = 68
}

/// Small non-blocking banner at the top of the flight view: "Connection lost, reconnecting… (Cancel)" while the
/// auto-reconnect runs, then "Reconnect / Dismiss" if it ran out of retries. Renders nothing otherwise.
struct MultiplayerConnectionBanner: View {
    @ObservedObject var session: MultiplayerSession
    @EnvironmentObject private var model: AppModel
    private let warn = Color(red: 1.0, green: 0.6, blue: 0.2)

    var body: some View {
        VStack {
            if case .reconnecting(let attempt, let total) = session.reconnectState {
                banner(icon: "wifi.exclamationmark",
                       text: attempt > 0 ? "Connection lost, reconnecting… (\(attempt)/\(total))" : "Connection lost, reconnecting…",
                       spinner: true) {
                    Button("Cancel") { session.cancelReconnect() }.buttonStyle(.novaPlain)
                }
            } else if let lost = session.lostConnection {
                banner(icon: "wifi.slash", text: lost.message, spinner: false) {
                    HStack(spacing: 14) {
                        Button("Reconnect") { model.reconnectToLostServer() }.buttonStyle(.novaPlain)
                        Button { session.dismissLostConnection() } label: { Image(systemName: "xmark") }.buttonStyle(.novaPlain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .allowsHitTesting(session.reconnectState != .idle || session.lostConnection != nil)
    }

    private func banner<Actions: View>(icon: String, text: String, spinner: Bool,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.small).tint(warn) }
            else { Image(systemName: icon).foregroundStyle(warn) }
            Text(text).novaFont(.caption).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            actions().novaFont(.caption, weight: .semibold).foregroundStyle(warn)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(warn.opacity(0.5)))
        .frame(maxWidth: 520)
    }
}

/// Round chat toggle with an unread badge.
struct ChatButton: View {
    @ObservedObject var session: MultiplayerSession
    @Binding var showChat: Bool

    var body: some View {
        Button { showChat.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.black.opacity(0.55), in: Circle())
                if session.unreadCount > 0 && !showChat {
                    Text("\(min(session.unreadCount, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.red, in: Circle())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.novaPlain)
    }
}

/// The chat panel: scrolling message feed + input bar.
struct ChatOverlayView: View {
    @ObservedObject var session: MultiplayerSession
    @Binding var isPresented: Bool

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            messages
            inputBar
        }
        .frame(width: 320, height: 260)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
        .cursorCancel { isPresented = false }
        .onAppear { session.chatVisible = true }
        .onDisappear { session.chatVisible = false }
    }

    private var header: some View {
        HStack {
            Text("Session Chat")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Text("\(max(session.presence.count, 1)) online")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.novaPlain)
            .padding(.leading, 6)
        }
        .padding(10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(session.chatLog.enumerated()), id: \.offset) { _, message in
                        messageRow(message)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: session.chatLog.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .cursorScrollable()
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let mine = message.playerID == session.localPlayerID
        return VStack(alignment: .leading, spacing: 1) {
            Text(message.senderName)
                .font(.caption2.bold())
                .foregroundStyle(mine ? Color.cyan : Color.orange)
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !mine {
                Button("Block \(message.senderName)") { session.blockPlayer(message.playerID) }
                Button("Report \(message.senderName)") { session.reportPlayer(message.playerID) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            #if os(tvOS)
            // Cursor-clickable stand-in: opens the fullscreen keyboard and
            // sends straight from its commit (see TVTextEntry.swift).
            TVCursorTextField(placeholder: "Message…", text: $draft, onCommit: send)
            #else
            TextField("Message…", text: $draft)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(8)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .focused($inputFocused)
                .onSubmit(send)
                .padTextEntry("Message", text: $draft, onCommit: send)
            #endif
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .white.opacity(0.3) : .white)
            }
            .buttonStyle(.novaPlain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        draft = ""
        session.sendChat(text)
        inputFocused = true
    }
}
