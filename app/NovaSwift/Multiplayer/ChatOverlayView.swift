import SwiftUI
import NovaSwiftNet

/// Bottom-leading in-flight cluster: a "Co-op" launcher that starts a local
/// session, then a chat button + collapsible chat panel once a session is live.
/// Self-contained so `GameContainerView` only adds one line to its overlay stack.
///
/// The empty regions of the enclosing `VStack` have no background, so they don't
/// intercept the tap/drag-to-fly steering underneath — only the button and panel
/// are hit-testable.
struct MultiplayerChatCluster: View {
    @ObservedObject var session: MultiplayerSession
    /// The local pilot's display name, fed to presence + chat.
    let pilotName: String
    /// The system the local player is currently in, fed to presence on start.
    let currentSystemID: Int

    @State private var showChat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isActive && showChat {
                ChatOverlayView(session: session, isPresented: $showChat)
            }
            controlButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var controlButton: some View {
        if session.isActive {
            ChatButton(session: session, showChat: $showChat)
        } else {
            Button {
                session.startLocal(displayName: pilotName.isEmpty ? "Captain" : pilotName,
                                   systemID: currentSystemID)
                showChat = true
            } label: {
                Label("Co-op", systemImage: "person.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
        }
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
        .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Message…", text: $draft)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(8)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .focused($inputFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .white.opacity(0.3) : .white)
            }
            .buttonStyle(.plain)
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
