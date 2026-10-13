#if os(iOS)
import SwiftUI
import UIKit

/// The Touch tab: a live preview of the on-screen flight cockpit at the device's
/// aspect, over a dimmed starfield, plus an inspector. Drag a control to move it
/// (8pt grid, snapping to the safe-area edges; stored edge-anchored so it
/// survives rotation); select one to resize it, re-bind its action, hide or
/// remove it. Edits save immediately (like pad bindings) — Cancel/Done only
/// close the screen. The preview draws with the very same `TouchMetrics`,
/// `TouchControlVisual` and `TouchControl` geometry the game overlay uses.
struct TouchTab: View {
    @EnvironmentObject private var model: AppModel

    @State private var selectedID: String?
    /// The dragged control's box when the drag began (safe-area space).
    @State private var dragOrigin: CGRect?
    /// A press only selects; it becomes a move once the finger travels a little.
    @State private var dragging = false
    @State private var adding = false
    @State private var newAction: GameAction = .hailTarget

    private static let grid: CGFloat = 8
    private static let edgeSnap: CGFloat = 10
    private static let space = "touchCanvas"

    // MARK: Geometry

    /// The device in landscape (flight is landscape), in points.
    private var device: CGSize {
        let b = UIScreen.main.bounds.size
        return CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
    }

    /// Landscape safe-area insets, approximated: notch phones inset the sides
    /// and the home indicator; iPads have effectively none.
    private var insets: (h: CGFloat, bottom: CGFloat) {
        UIDevice.current.userInterfaceIdiom == .phone ? (47, 21) : (0, 0)
    }

    private var area: CGSize {
        CGSize(width: device.width - 2 * insets.h, height: device.height - insets.bottom)
    }

    private var metrics: TouchMetrics { TouchMetrics(device) }
    private var layout: TouchLayout { model.touchLayout }
    private var u: CGFloat { layout.unit(metric: metrics.s) }

    private var selected: TouchControl? {
        guard let id = selectedID else { return nil }
        return layout.controls.first { $0.id == id }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 640
            let stack = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                             : AnyLayout(VStackLayout(spacing: 10))
            stack {
                canvasView
                inspector.frame(maxWidth: wide ? 300 : .infinity)
            }
        }
        .onChange(of: model.touchLayout) { _, _ in model.commitTouchLayout() }
    }

    // MARK: Preview canvas

    private var canvasView: some View {
        GeometryReader { geo in
            let k = geo.size.width / device.width
            canvas
                .frame(width: device.width, height: device.height)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(device.width / device.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2)))
    }

    private var canvas: some View {
        ZStack {
            Color(white: 0.03)
            starfield
            Color.black.opacity(0.35)
            // Tapping the empty sky deselects.
            Color.clear.contentShape(Rectangle())
                .onTapGesture { selectedID = nil }
                .cursorClickable { selectedID = nil }
            safeAreaOutline
            ZStack {
                ForEach(layout.controls) { c in
                    preview(c)
                        .touchPlaced(anchor: c.anchor, x: CGFloat(c.x) * u, y: CGFloat(c.y) * u, rightInset: 0)
                }
            }
            .padding(.horizontal, insets.h)
            .padding(.bottom, insets.bottom)
        }
        .coordinateSpace(.named(Self.space))
    }

    private var safeAreaOutline: some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            .padding(.horizontal, insets.h)
            .padding(.bottom, insets.bottom)
            .allowsHitTesting(false)
    }

    private var starfield: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / 9007199254740992.0
            }
            for _ in 0..<160 {
                let x = next() * size.width, y = next() * size.height
                let r = 0.6 + next() * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(.white.opacity(0.15 + next() * 0.55)))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func previewVisual(_ c: TouchControl) -> some View {
        if c.kind == .weaponChip {
            let box = c.boxSize(unit: u)
            HStack(spacing: 5 * u * CGFloat(c.size)) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Secondary")
            }
            .font(.system(size: 11 * u * CGFloat(c.size), weight: .semibold))
            .foregroundStyle(novaAmber)
            .frame(width: box.width, height: box.height)
            .background(RoundedRectangle(cornerRadius: 7 * u).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7 * u).strokeBorder(novaAmber.opacity(0.3)))
        } else {
            let sz = c.capSize(unit: u)
            TouchControlVisual(control: c, size: sz, unit: u, captions: metrics.captions)
                .padding(sz * TouchControl.hitPad)
        }
    }

    private func preview(_ c: TouchControl) -> some View {
        let isSelected = c.id == selectedID
        return previewVisual(c)
            .allowsHitTesting(false)
            .opacity(c.hidden ? 0.28 : layout.opacity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(novaAmber, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .overlay(
                Color.clear.contentShape(Rectangle())
                    .cursorClickable { selectedID = c.id }
                    .gesture(dragGesture(c.id))
            )
    }

    // MARK: Dragging

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in move(id, by: v.translation) }
            .onEnded { _ in endMove(id) }
    }

    private func move(_ id: String, by t: CGSize) {
        guard let i = layout.index(of: id) else { return }
        selectedID = id
        let c = layout.controls[i]
        let start = dragOrigin ?? c.frame(in: area, unit: u)
        dragOrigin = start
        if !dragging {
            guard abs(t.width) + abs(t.height) > 4 else { return }
            dragging = true
        }
        let r = snapped(start.offsetBy(dx: t.width, dy: t.height), anchor: c.anchor)
        model.touchLayout.controls[i].place(r, in: area, unit: u, reanchor: false)
    }

    private func endMove(_ id: String) {
        if dragging, let i = layout.index(of: id) {
            // Hug whichever corner the control ended up nearest.
            let r = layout.controls[i].frame(in: area, unit: u)
            model.touchLayout.controls[i].place(r, in: area, unit: u, reanchor: true)
        }
        dragOrigin = nil
        dragging = false
    }

    /// Snap a box to the 8pt grid (measured from the edges it is anchored to),
    /// pull it onto a nearby safe-area edge, and keep it on screen.
    private func snapped(_ r: CGRect, anchor: TouchCorner) -> CGRect {
        let g = Self.grid, e = Self.edgeSnap
        var x = r.minX, y = r.minY
        if anchor.isTrailing {
            x = area.width - r.width - ((area.width - r.maxX) / g).rounded() * g
        } else {
            x = (x / g).rounded() * g
        }
        if anchor.isBottom {
            y = area.height - r.height - ((area.height - r.maxY) / g).rounded() * g
        } else {
            y = (y / g).rounded() * g
        }
        if x < e { x = 0 }
        if area.width - (x + r.width) < e { x = area.width - r.width }
        if y < e { y = 0 }
        if area.height - (y + r.height) < e { y = area.height - r.height }
        return clamped(CGRect(x: x, y: y, width: r.width, height: r.height))
    }

    private func clamped(_ r: CGRect) -> CGRect {
        CGRect(x: min(max(r.minX, 0), max(0, area.width - r.width)),
               y: min(max(r.minY, 0), max(0, area.height - r.height)),
               width: r.width, height: r.height)
    }

    /// Nudge the selected control by whole grid steps — the controller-friendly
    /// alternative to dragging.
    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let id = selectedID, let i = layout.index(of: id) else { return }
        let r = clamped(layout.controls[i].frame(in: area, unit: u).offsetBy(dx: dx, dy: dy))
        model.touchLayout.controls[i].place(r, in: area, unit: u, reanchor: true)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drag a control to move it; it snaps to an 8 pt grid and the screen edges. Changes save as you make them.")
                    .novaFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sliderRow("Scale", valueText: String(format: "%.0f%%", layout.scale * 100),
                          value: Binding(get: { model.touchLayout.scale },
                                         set: { model.touchLayout.scale = ($0 * 20).rounded() / 20 }),
                          range: TouchLayout.scaleRange)
                sliderRow("Opacity", valueText: String(format: "%.0f%%", layout.opacity * 100),
                          value: Binding(get: { model.touchLayout.opacity },
                                         set: { model.touchLayout.opacity = ($0 * 20).rounded() / 20 }),
                          range: TouchLayout.opacityRange)

                Text("Presets").novaFont(.body, weight: .semibold).foregroundStyle(.white)
                HStack(spacing: 6) {
                    ForEach(TouchLayout.Preset.allCases) { p in
                        CursorButton {
                            model.touchLayout.apply(p)
                            selectedID = nil
                        } label: {
                            EditorChip(text: p.rawValue, highlighted: layout.matches(p))
                        }
                    }
                }

                addSection
                Divider().overlay(Color.white.opacity(0.15))
                selectionSection
            }
            .padding(.vertical, 2)
        }
        .cursorScrollable()
    }

    private func sliderRow(_ title: String, valueText: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).novaFont(.body).foregroundStyle(.white)
                Spacer()
                Text(valueText).novaFont(.caption).foregroundStyle(.secondary)
            }
            NovaSlider(value: value, range: range)
        }
    }

    @ViewBuilder
    private var addSection: some View {
        CursorButton { adding.toggle() } label: {
            EditorChip(text: adding ? "Cancel" : "Add button", highlighted: adding)
        }
        if adding {
            NovaMenuPicker(title: "Action", selection: $newAction,
                           options: GameAction.touchTapActions) { $0.title }
            CursorButton {
                let c = TouchLayout.customTap(newAction)
                model.touchLayout.controls.append(c)
                selectedID = c.id
                adding = false
            } label: {
                EditorChip(text: "Place \(newAction.title)", highlighted: true)
            }
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        if let c = selected {
            Text(c.caption).novaFont(.heading).foregroundStyle(novaAmber)

            sliderRow("Size", valueText: String(format: "%.2f×", c.size),
                      value: Binding(
                        get: { model.touchLayout.controls.first { $0.id == c.id }?.size ?? 1 },
                        set: { v in
                            if let i = model.touchLayout.index(of: c.id) {
                                model.touchLayout.controls[i].size = (v * 20).rounded() / 20
                            }
                        }),
                      range: TouchControl.sizeRange)

            actionPicker(c)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                nudgeButton("arrow.left", -Self.grid, 0)
                nudgeButton("arrow.up", 0, -Self.grid)
                nudgeButton("arrow.down", 0, Self.grid)
                nudgeButton("arrow.right", Self.grid, 0)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                if c.isCustom {
                    CursorButton {
                        model.touchLayout.controls.removeAll { $0.id == c.id }
                        selectedID = nil
                    } label: { EditorChip(text: "Remove", highlighted: true, tint: .red) }
                } else if c.kind != .actionsToggle {
                    CursorButton {
                        if let i = model.touchLayout.index(of: c.id) { model.touchLayout.controls[i].hidden.toggle() }
                    } label: { EditorChip(text: c.hidden ? "Show" : "Hide") }
                }
            }
            if c.kind == .actionsToggle {
                Text("The Actions button opens the full action grid, so it can't be hidden.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
            if c.kind == .hold, c.effect == .turnLeft || c.effect == .turnRight {
                Text("Turn buttons are hidden while Tap to Fly steering is on.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Select a control to resize it, change its action, or hide it.")
                .novaFont(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionPicker(_ c: TouchControl) -> some View {
        switch c.kind {
        case .hold:
            NovaMenuPicker(title: "Holds",
                           selection: Binding(
                            get: { c.effect ?? .thrust },
                            set: { e in
                                if let i = model.touchLayout.index(of: c.id) { model.touchLayout.controls[i].setEffect(e) }
                            }),
                           options: TouchHoldEffect.allCases) { $0.title }
        case .tap:
            NovaMenuPicker(title: "Action",
                           selection: Binding(
                            get: { c.action ?? .targetNearest },
                            set: { a in
                                if let i = model.touchLayout.index(of: c.id) { model.touchLayout.controls[i].setAction(a) }
                            }),
                           options: GameAction.touchTapActions) { $0.title }
        case .weaponChip, .actionsToggle:
            EmptyView()
        }
    }

    private func nudgeButton(_ system: String, _ dx: CGFloat, _ dy: CGFloat) -> some View {
        CursorButton { nudge(dx, dy) } label: {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
        }
    }
}
#endif
