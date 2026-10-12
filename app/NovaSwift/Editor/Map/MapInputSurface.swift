#if os(macOS)
import SwiftUI
import AppKit

// Shared mouse/keyboard surface for the galaxy and system editors. SwiftUI's
// gestures can't see scroll wheels, magnify, middle-drag or key-up, so an
// AppKit view sits on top of the Canvas and reports everything in top-left
// (flipped) view coordinates.

struct MapMenuItem {
    var title: String
    var symbol: String? = nil
    var destructive = false
    var disabled = false
    var children: [MapMenuItem] = []
    var isSeparator = false
    var action: (() -> Void)? = nil

    static let separator = MapMenuItem(title: "", isSeparator: true)
}

struct MapPointer {
    var location: CGPoint
    var shift: Bool
    var option: Bool
    var command: Bool
    var clickCount: Int
}

struct MapInputSurface: NSViewRepresentable {
    var onDown: (MapPointer) -> Void = { _ in }
    var onDrag: (MapPointer) -> Void = { _ in }
    var onUp: (MapPointer) -> Void = { _ in }
    var onMove: (CGPoint) -> Void = { _ in }
    /// (cursor, scrollDelta, isTrackpad, ctrlOrCmd)
    var onScroll: (CGPoint, CGSize, Bool, Bool) -> Void = { _, _, _, _ in }
    var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
    /// Middle-button drag translation since last event.
    var onPan: (CGSize) -> Void = { _ in }
    var onSpace: (Bool) -> Void = { _ in }
    /// Return true if handled. Keys: "delete", "escape", "return".
    var onKey: (String) -> Bool = { _ in false }
    var menu: (CGPoint) -> [MapMenuItem] = { _ in [] }
    var cursor: NSCursor? = nil

    func makeNSView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.owner = self
        return v
    }

    func updateNSView(_ v: SurfaceView, context: Context) {
        v.owner = self
        if v.cursorValue !== cursor { v.cursorValue = cursor; v.window?.invalidateCursorRects(for: v) }
    }

    final class SurfaceView: NSView {
        var owner: MapInputSurface!
        var cursorValue: NSCursor?
        private var tracking: NSTrackingArea?
        private var spaceDown = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if let c = cursorValue { addCursorRect(bounds, cursor: c) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                   owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }

        private func pointer(_ e: NSEvent) -> MapPointer {
            MapPointer(location: convert(e.locationInWindow, from: nil),
                       shift: e.modifierFlags.contains(.shift), option: e.modifierFlags.contains(.option),
                       command: e.modifierFlags.contains(.command), clickCount: e.clickCount)
        }

        override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); owner.onDown(pointer(e)) }
        override func mouseDragged(with e: NSEvent) { owner.onDrag(pointer(e)) }
        override func mouseUp(with e: NSEvent) { owner.onUp(pointer(e)) }
        override func mouseMoved(with e: NSEvent) { owner.onMove(convert(e.locationInWindow, from: nil)) }
        override func otherMouseDragged(with e: NSEvent) { owner.onPan(CGSize(width: e.deltaX, height: e.deltaY)) }

        override func scrollWheel(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            let dy = e.scrollingDeltaY, dx = e.scrollingDeltaX
            owner.onScroll(p, CGSize(width: dx, height: dy), e.hasPreciseScrollingDeltas,
                           e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control))
        }

        override func magnify(with e: NSEvent) {
            owner.onMagnify(convert(e.locationInWindow, from: nil), e.magnification)
        }

        override func keyDown(with e: NSEvent) {
            if e.charactersIgnoringModifiers == " " {
                if !spaceDown { spaceDown = true; owner.onSpace(true) }
                return
            }
            let key: String?
            switch e.keyCode {
            case 51, 117: key = "delete"
            case 53: key = "escape"
            case 36, 76: key = "return"
            default: key = nil
            }
            if let key, owner.onKey(key) { return }
            super.keyDown(with: e)
        }

        override func keyUp(with e: NSEvent) {
            if e.charactersIgnoringModifiers == " " { spaceDown = false; owner.onSpace(false); return }
            super.keyUp(with: e)
        }

        override func resignFirstResponder() -> Bool {
            if spaceDown { spaceDown = false; owner.onSpace(false) }
            return super.resignFirstResponder()
        }

        override func rightMouseDown(with e: NSEvent) {
            window?.makeFirstResponder(self)
            let p = convert(e.locationInWindow, from: nil)
            let items = owner.menu(p)
            guard !items.isEmpty else { return }
            let m = NSMenu()
            m.autoenablesItems = false
            Self.fill(m, items)
            NSMenu.popUpContextMenu(m, with: e, for: self)
        }

        private static func fill(_ menu: NSMenu, _ items: [MapMenuItem]) {
            for it in items {
                if it.isSeparator { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
                if let s = it.symbol { mi.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
                mi.isEnabled = !it.disabled
                if !it.children.isEmpty {
                    let sub = NSMenu(); sub.autoenablesItems = false
                    fill(sub, it.children)
                    mi.submenu = sub
                } else if let act = it.action {
                    let target = MenuTarget(act)
                    mi.target = target; mi.action = #selector(MenuTarget.fire)
                    mi.representedObject = target   // retain
                }
                menu.addItem(mi)
            }
        }
    }

    final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func fire() { action() }
    }
}

// MARK: - Viewport

/// World↔screen transform shared by both canvases. World y is DOWN (map and
/// system data coordinates); `center` is the world point at the view centre.
struct MapViewport: Equatable {
    var center = CGPoint.zero
    var zoom: CGFloat = 1

    func toScreen(_ w: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (w.x - center.x) * zoom + size.width / 2, y: (w.y - center.y) * zoom + size.height / 2)
    }
    func toWorld(_ s: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (s.x - size.width / 2) / zoom + center.x, y: (s.y - size.height / 2) / zoom + center.y)
    }
    /// Zoom by `factor` keeping the world point under `cursor` fixed.
    mutating func zoom(by factor: CGFloat, around cursor: CGPoint, size: CGSize, range: ClosedRange<CGFloat>) {
        let before = toWorld(cursor, size)
        zoom = min(max(zoom * factor, range.lowerBound), range.upperBound)
        let after = toWorld(cursor, size)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }
    mutating func pan(byScreen d: CGSize) {
        center.x -= d.width / zoom
        center.y -= d.height / zoom
    }
}

// MARK: - Shared chrome

/// Small floating palette button.
struct MapToolButton: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? novaAmber : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

struct MapPalette<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func mapInspectorSection(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber.opacity(0.85))
            self
        }
    }
}
#endif
