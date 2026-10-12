#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// DITL / DLOG preview and layout editor: the dialog window and every item rectangle drawn to
/// scale (pictures drawn from their PICT), hover for index/type/rect, drag to move, drag the
/// corner handle to resize. Edits patch only the 8 rect bytes of the item
/// (`DialogCodec.setRect`), so everything else in the resource is preserved byte for byte.
struct DialogPreviewEditor: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey

    private struct Loaded: @unchecked Sendable {
        let ditlKey: ResourceKey
        let dialog: NovaDialogRes
        let pictures: [Int: CGImage]
    }

    @State private var loaded: Loaded?
    @State private var failure: String?
    @State private var finished = false
    @State private var hovered: Int?
    @State private var selected: Int?
    @State private var draft: [Int: NovaRect] = [:]
    @State private var dragOrigin: NovaRect?
    @State private var zoom: CGFloat = 1

    private struct TaskKey: Hashable { let key: ResourceKey; let rev: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let l = loaded {
                controls(l)
                infoBar(l)
                stage(l)
                if let s = selected, let item = l.dialog.items.items.first(where: { $0.index == s }) {
                    rectFields(l, item)
                }
                Text("Drag an item to move it, or its corner handle to resize. Rectangles are window-relative pixels (the game centres the window; the DLOG position is ignored).")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if finished {
                EditorEmptyState(icon: "rectangle.dashed", title: failure ?? "Nothing to preview",
                                 subtitle: "Use Raw to edit the bytes.").frame(minHeight: 160)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                    ProgressView().controlSize(.regular).tint(novaAmber)
                }.frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: TaskKey(key: key, rev: model.dataRevision)) { await load() }
        .onChange(of: key) { _, _ in selected = nil; hovered = nil; draft = [:]; loaded = nil; finished = false }
    }

    // MARK: Loading

    private func load() async {
        let k = key, eff = model.effective, previous = loaded?.pictures ?? [:]
        let result = await Task.detached(priority: .userInitiated) {
            Self.build(key: k, eff: eff, previous: previous)
        }.value
        if Task.isCancelled { return }
        switch result {
        case let .success(l): loaded = l; failure = nil
        case let .failure(e): loaded = nil; failure = e.message
        }
        draft = [:]
        finished = true
    }

    private struct BuildError: Swift.Error { let message: String }

    nonisolated private static func build(key: ResourceKey, eff: ResourceCollection,
                                          previous: [Int: CGImage]) -> Result<Loaded, BuildError> {
        var window: DLOGRes?
        let ditlID: Int
        if key.type == NovaType.dlog {
            guard let r = eff.resource(NovaType.dlog, key.id) else { return .failure(.init(message: "DLOG #\(key.id) not found")) }
            let w = DLOGRes(r)
            window = w; ditlID = w.itemsID
        } else {
            ditlID = key.id
            if let r = eff.resource(NovaType.dlog, key.id), DLOGRes(r).itemsID == ditlID { window = DLOGRes(r) }
            else { window = eff.resources(of: NovaType.dlog).map(DLOGRes.init).first { $0.itemsID == ditlID } }
        }
        guard let dr = eff.resource(NovaType.ditl, ditlID) else {
            return .failure(.init(message: "DLOG #\(key.id) points at DITL #\(ditlID), which doesn't exist"))
        }
        let items = DITLRes(dr)
        var pictures: [Int: CGImage] = [:]
        for item in items.items where item.kind == .picture {
            guard let id = item.resourceID, pictures[id] == nil, pictures.count < 12 else { continue }
            if let p = previous[id] { pictures[id] = p; continue }
            if let r = eff.resource(NovaType.pict, id),
               let cg = EditorSpriteCache.shared.decode(type: NovaType.pict, id: id, data: r.data).0?.frame(0) {
                pictures[id] = cg
            }
        }
        return .success(Loaded(ditlKey: ResourceKey(NovaType.ditl, ditlID),
                               dialog: NovaDialogRes(window: window, items: items), pictures: pictures))
    }

    // MARK: Chrome

    private func controls(_ l: Loaded) -> some View {
        HStack(spacing: 12) {
            let d = l.dialog
            Text(d.window.map { "DLOG #\($0.id) · \($0.bounds.width)×\($0.bounds.height)" } ?? "No DLOG (standalone DITL)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text("DITL #\(l.ditlKey.id) · \(d.items.items.count) item\(d.items.items.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if key.type == NovaType.dlog || l.ditlKey.id != key.id {
                Button { model.navigate(to: l.ditlKey) } label: { Label("Open DITL", systemImage: "arrow.right.circle") }
                    .controlSize(.small)
            }
            Spacer()
            Picker("", selection: $zoom) {
                Text("1×").tag(CGFloat(1)); Text("1.5×").tag(CGFloat(1.5)); Text("2×").tag(CGFloat(2))
            }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
        }
    }

    private func infoBar(_ l: Loaded) -> some View {
        let idx = hovered ?? selected
        let item = idx.flatMap { i in l.dialog.items.items.first { $0.index == i } }
        return HStack(spacing: 8) {
            if let item {
                let r = draft[item.index] ?? item.rect
                Text("Item \(item.index)").font(.system(size: 11, weight: .semibold))
                Text(Self.kindName(item.kind)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("left \(r.left) top \(r.top) · \(r.width)×\(r.height)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                if !item.isEnabled { Text("not hit-tested").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if let t = Self.label(item), !t.isEmpty { Text(t).font(.system(size: 11)).lineLimit(1).foregroundStyle(novaAmber) }
            } else {
                Text("Hover an item for its index, type and rectangle.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(height: 16)
    }

    private func stage(_ l: Loaded) -> some View {
        let s = zoom
        let design = l.dialog.designSize
        let wb = l.dialog.window?.bounds
        let ww = CGFloat(wb?.width ?? design.width) * s, wh = CGFloat(wb?.height ?? design.height) * s
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.17)).frame(width: ww, height: wh)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                ForEach(l.dialog.items.items, id: \.index) { item in
                    itemView(item, l, s)
                }
            }
            .frame(width: max(ww, CGFloat(design.width) * s), height: max(wh, CGFloat(design.height) * s), alignment: .topLeading)
            .padding(10)
        }
        .frame(minHeight: 200, maxHeight: 560)
        .background(CheckerboardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
    }

    private func itemView(_ item: DITLItem, _ l: Loaded, _ s: CGFloat) -> some View {
        let r = draft[item.index] ?? item.rect
        let w = max(CGFloat(r.width) * s, 3), h = max(CGFloat(r.height) * s, 3)
        let isSel = selected == item.index
        return DialogItemChrome(item: item, scale: s, size: CGSize(width: w, height: h),
                                picture: item.resourceID.flatMap { l.pictures[$0] },
                                isSelected: isSel, isHovered: hovered == item.index)
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if isSel { resizeHandle(item, l, s) }
            }
            .offset(x: CGFloat(r.left) * s, y: CGFloat(r.top) * s)
            .onHover { inside in
                if inside { hovered = item.index } else if hovered == item.index { hovered = nil }
            }
            .onTapGesture { selected = item.index }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { g in
                        if dragOrigin == nil { dragOrigin = draft[item.index] ?? item.rect; selected = item.index }
                        guard let o = dragOrigin else { return }
                        let dx = Int((g.translation.width / s).rounded()), dy = Int((g.translation.height / s).rounded())
                        draft[item.index] = NovaRect(top: o.top + dy, left: o.left + dx,
                                                     bottom: o.bottom + dy, right: o.right + dx)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        if let r = draft[item.index] { commit(item.index, r, l) }
                    })
    }

    private func resizeHandle(_ item: DITLItem, _ l: Loaded, _ s: CGFloat) -> some View {
        Rectangle().fill(novaAmber).frame(width: 9, height: 9)
            .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .offset(x: 4, y: 4)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragOrigin == nil { dragOrigin = draft[item.index] ?? item.rect }
                        guard let o = dragOrigin else { return }
                        let dx = Int((g.translation.width / s).rounded()), dy = Int((g.translation.height / s).rounded())
                        draft[item.index] = NovaRect(top: o.top, left: o.left,
                                                     bottom: max(o.top + 2, o.bottom + dy), right: max(o.left + 2, o.right + dx))
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        if let r = draft[item.index] { commit(item.index, r, l) }
                    })
            .help("Drag to resize")
    }

    private func rectFields(_ l: Loaded, _ item: DITLItem) -> some View {
        let r = draft[item.index] ?? item.rect
        func field(_ title: String, _ value: Int, _ make: @escaping (Int) -> NovaRect) -> some View {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                NumberField(value: value, range: -4000...4000, stepper: true, width: 56) { n in
                    commit(item.index, make(n), l)
                }
            }
        }
        return HStack(spacing: 14) {
            Text("Item \(item.index)").font(.system(size: 11, weight: .semibold))
            field("Left", r.left) { NovaRect(top: r.top, left: $0, bottom: r.bottom, right: r.right + ($0 - r.left)) }
            field("Top", r.top) { NovaRect(top: $0, left: r.left, bottom: r.bottom + ($0 - r.top), right: r.right) }
            field("Width", r.width) { NovaRect(top: r.top, left: r.left, bottom: r.bottom, right: r.left + max(1, $0)) }
            field("Height", r.height) { NovaRect(top: r.top, left: r.left, bottom: r.top + max(1, $0), right: r.right) }
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: Editing

    private func commit(_ index: Int, _ rect: NovaRect, _ l: Loaded) {
        guard let current = model.document.resource(NovaType.ditl, l.ditlKey.id),
              let patched = DialogCodec.setRect(rect, ofItem: index, in: current.data) else {
            draft[index] = nil; return
        }
        if patched == current.data { draft[index] = nil; return }
        model.writeData(patched, for: l.ditlKey, label: "Move dialog item \(index)",
                        coalesce: "ditl/\(l.ditlKey.id)/\(index)")
    }

    // MARK: Labels

    static func kindName(_ k: DITLItemKind) -> String {
        switch k {
        case .userItem: return "User item"
        case .button: return "Button"
        case .checkbox: return "Checkbox / radio"
        case .resControl: return "Control"
        case .statText: return "Static text"
        case .editText: return "Edit text"
        case .icon: return "Icon"
        case .picture: return "Picture"
        case let .unknown(n): return "Unknown (\(n))"
        }
    }

    static func label(_ item: DITLItem) -> String? {
        if !item.text.isEmpty { return "“\(item.text)”" }
        if let id = item.resourceID { return "#\(id)" }
        return nil
    }
}

/// How one DITL item is drawn in the preview.
private struct DialogItemChrome: View {
    let item: DITLItem
    let scale: CGFloat
    let size: CGSize
    let picture: CGImage?
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            if isSelected || isHovered {
                Text("\(item.index)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 3)
                    .background(isSelected ? novaAmber : Color.white.opacity(0.7))
                    .foregroundStyle(Color.black)
                    .offset(x: 0, y: -12)
                    .fixedSize()
            }
        }
        .opacity(item.isEnabled ? 1 : 0.7)
        .overlay(Rectangle().stroke(isSelected ? novaAmber : (isHovered ? Color.white.opacity(0.8) : Color.clear), lineWidth: 1.5))
    }

    private var font: Font { .system(size: max(8, 11 * scale)) }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .button:
            RoundedRectangle(cornerRadius: 4 * scale).fill(Color.white.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 4 * scale).stroke(Color.white.opacity(0.5), lineWidth: 1))
                .overlay(Text(item.text).font(font).lineLimit(1).padding(.horizontal, 2))
        case .checkbox:
            HStack(spacing: 4 * scale) {
                Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1).frame(width: 10 * scale, height: 10 * scale)
                Text(item.text).font(font).lineLimit(1)
                Spacer(minLength: 0)
            }
        case .statText:
            Text(item.text).font(font).foregroundStyle(Color.white.opacity(0.75)).lineLimit(nil)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .overlay(Rectangle().stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        case .editText:
            Rectangle().fill(Color.black.opacity(0.35))
                .overlay(Rectangle().stroke(Color.white.opacity(0.45), lineWidth: 1))
                .overlay(Text(item.text).font(font).lineLimit(1).padding(.horizontal, 3), alignment: .leading)
        case .picture:
            if let picture {
                Image(decorative: picture, scale: 1).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else { placeholder("PICT #\(item.resourceID ?? 0)", Color.purple) }
        case .icon:
            placeholder("Icon #\(item.resourceID ?? 0)", Color.teal)
        case .resControl:
            placeholder("Control #\(item.resourceID ?? 0)", Color.green)
        case .userItem:
            placeholder("User item", novaAmber)
        case .unknown:
            placeholder("?", Color.red)
        }
    }

    private func placeholder(_ label: String, _ tint: Color) -> some View {
        Rectangle().fill(tint.opacity(0.1))
            .overlay(Rectangle().stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay(Text(label).font(.system(size: 9)).foregroundStyle(tint.opacity(0.9)).lineLimit(1).padding(2),
                     alignment: .topLeading)
    }
}
#endif
