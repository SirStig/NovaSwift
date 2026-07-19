import SwiftUI
import GameController

/// App-wide observable for the connected game controller, so any view can
/// react to connect/disconnect and render the *connected pad's* vendor-correct
/// button names and SF Symbol glyphs (Ⓐ on Xbox, ✕ on DualSense, etc.).
@MainActor
final class PadState: ObservableObject {
    static let shared = PadState()

    @Published private(set) var pad: GCExtendedGamepad?
    @Published private(set) var vendorName: String?

    var isConnected: Bool { pad != nil }

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        pad = GCController.current?.extendedGamepad
        vendorName = GCController.current?.vendorName
        print("PadState: current=\(GCController.current?.vendorName ?? "none") extended=\(pad != nil) all=\(GCController.controllers().map { $0.vendorName ?? "?" }.joined(separator: ","))")
    }

    /// "Ⓐ"-style hint text for an action on the current pad — the connected
    /// controller's own control name, or nil when no pad/binding exists.
    /// Use in interpolated instruction strings ("Press \(label) to land").
    func hintLabel(for action: GameAction, bindings: PadBindings) -> String? {
        guard let pad else { return nil }
        guard let button = bindings.button(for: action) else { return nil }
        return button.displayName(on: pad)
    }
}

/// The connected controller's icon for a bound action: its real SF Symbol
/// (per-vendor — "a.circle" on Xbox, "xmark.circle" on DualSense) with the
/// button's name as fallback, or nothing at all with no pad connected. Drop
/// it inline next to any prompt: `Label { Text("Land") } icon: { PadGlyph(.land) }`.
struct PadGlyph: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var padState = PadState.shared
    let action: GameAction
    var size: CGFloat = 16
    var tint: Color = novaAmber

    init(_ action: GameAction, size: CGFloat = 16, tint: Color = novaAmber) {
        self.action = action
        self.size = size
        self.tint = tint
    }

    var body: some View {
        if let pad = padState.pad, let button = model.padBindings.button(for: action) {
            if let symbol = button.symbolName(on: pad) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            } else {
                Text(button.displayName(on: pad))
                    .font(.system(size: size * 0.75, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
