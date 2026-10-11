import SwiftUI

/// Controller-operable replacement for SwiftUI's `.alert` / `.confirmationDialog`.
///
/// System alerts are invisible to the controller cursor — they're drawn by the
/// OS in their own window/controller, so a pad player could open one (a delete
/// confirm, "Land here?", a notice) and then never press anything in it. This
/// draws the same choice as a `NovaDialog` (authentic chrome, cursor targets,
/// Ⓑ = cancel, Menu = default) instead.
///
/// Requests are presented by the cursor host they were raised in (`RootView`
/// or a sheet's `.cursorHost()`), full-surface and above every other layer,
/// so an alert raised from inside a small panel still covers the screen.
struct NovaAlertButton {
    enum Role { case normal, cancel, destructive }
    let title: String
    var role: Role = .normal
    var action: () -> Void = {}

    static func cancel(_ title: String = "Cancel", action: @escaping () -> Void = {}) -> NovaAlertButton {
        NovaAlertButton(title: title, role: .cancel, action: action)
    }

    static func destructive(_ title: String, action: @escaping () -> Void) -> NovaAlertButton {
        NovaAlertButton(title: title, role: .destructive, action: action)
    }
}

@MainActor
final class NovaAlertCenter: ObservableObject {
    static let shared = NovaAlertCenter()

    struct Request: Identifiable {
        let id: UUID
        var host: UUID
        var title: String
        var message: String?
        var text: Binding<String>?
        var buttons: [NovaAlertButton]
        var dismiss: () -> Void
    }

    @Published private(set) var requests: [Request] = []

    func present(_ request: Request) {
        if let i = requests.firstIndex(where: { $0.id == request.id }) {
            requests[i] = request
        } else {
            requests.append(request)
        }
    }

    func remove(_ id: UUID) {
        if requests.contains(where: { $0.id == id }) { requests.removeAll { $0.id == id } }
    }
}

private struct NovaAlertModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String?
    let text: Binding<String>?
    let buttons: [NovaAlertButton]
    @Environment(\.cursorHost) private var host
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, shown in sync(shown) }
            // Keep a showing alert's text current if the caller re-renders it.
            .onChange(of: title) { _, _ in if isPresented { sync(true) } }
            .onChange(of: message) { _, _ in if isPresented { sync(true) } }
            .onDisappear { NovaAlertCenter.shared.remove(id) }
    }

    private func sync(_ shown: Bool) {
        guard shown else { NovaAlertCenter.shared.remove(id); return }
        let presented = $isPresented
        NovaAlertCenter.shared.present(.init(
            id: id, host: host, title: title, message: message, text: text,
            buttons: buttons.isEmpty ? [NovaAlertButton(title: "OK")] : buttons,
            dismiss: { presented.wrappedValue = false }))
    }
}

extension View {
    /// A controller-operable alert (see `NovaAlertButton`). Every button
    /// dismisses it before running its action, like a system alert. With no
    /// buttons it shows a single OK.
    func novaAlert(_ title: String, isPresented: Binding<Bool>, message: String? = nil,
                   text: Binding<String>? = nil, buttons: [NovaAlertButton] = []) -> some View {
        modifier(NovaAlertModifier(title: title, isPresented: isPresented, message: message,
                                   text: text, buttons: buttons))
    }
}

/// Draws the current host's alerts. Mounted by `RootView` and every
/// `.cursorHost()`; the newest request is on top.
struct NovaAlertLayer: View {
    let host: UUID
    @ObservedObject private var center = NovaAlertCenter.shared

    var body: some View {
        ZStack {
            ForEach(center.requests.filter { $0.host == host }) { request in
                NovaDialog(title: request.title, width: 420, buttons: dialogButtons(request)) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = request.message, !message.isEmpty {
                            Text(message).novaFont(.body).foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let text = request.text {
                            NovaTextField(placeholder: request.title, text: text)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // Above every in-hierarchy modal the screen might already have up.
        .environment(\.cursorLayer, 1000)
        .environment(\.cursorHost, host)
        .animation(.easeInOut(duration: 0.15), value: center.requests.map(\.id))
    }

    /// Cancel first (leftmost), then the rest in order. The default (Return /
    /// Menu) is the last non-cancel, non-destructive button — never a delete.
    private func dialogButtons(_ request: NovaAlertCenter.Request) -> [NovaDialogButton] {
        let ordered = request.buttons.filter { $0.role == .cancel }
            + request.buttons.filter { $0.role != .cancel }
        let defaultIndex = ordered.lastIndex { $0.role == .normal }
        return ordered.enumerated().map { i, b in
            NovaDialogButton(title: b.title, isDefault: i == defaultIndex,
                             cancelRole: b.role == .cancel) {
                request.dismiss()
                NovaAlertCenter.shared.remove(request.id)
                b.action()
            }
        }
    }
}
