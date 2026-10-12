#if os(macOS)
import SwiftUI
import AppKit
import SceneKit
import UniformTypeIdentifiers
import NovaSwiftKit
import NovaSwiftHD

/// Renders a model attachment on demand (SceneKit work stays on the main actor).
@MainActor
final class HDModelPreviewer: ObservableObject {
    private var baker: ModelBaker?
    private var node: SCNNode?
    private var nodeKey: String?
    @Published var error: String?

    func render(blob: Data, settings: GraphicsEnhancement.BakeSettings, headingDegrees: Double, size: Int) -> CGImage? {
        let key = "\(blob.count)-\(blob.hashValue)"
        if nodeKey != key {
            do { node = try ModelLoader.load(.blob(blob)); nodeKey = key; error = nil }
            catch { node = nil; nodeKey = nil; self.error = "\(error)"; return nil }
        }
        if baker == nil { baker = ModelBaker() }
        guard let baker, let node else { error = "No GPU renderer available"; return nil }
        return baker.view(model: node, settings: settings, heading: headingDegrees,
                          pitch: settings.pitch ?? 38, size: size)
    }
}

/// "HD / 3D" tab: attachments for a resource's sprite, classic vs HD side by side at
/// the same rotation frame, attach/remove PNG atlases and USDZ models (bake options),
/// export the plug-in's HD layer as a `.nsx` pack. All edits go through the document
/// (grouped, undoable).
struct HDTabView: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey

    private struct Target {
        var spriteID: Int
        var classic: SpriteSheet?
        var framesPerSet: Int
        var label: String
    }

    @State private var target: Target?
    /// The classic sheet as a ready-to-crop image, built once per load (not per body pass).
    @State private var classicSprite: EditorDecodedSprite?
    /// Attachments in this plug-in's own layer (for the Export button).
    @State private var layerAttachmentCount = 0
    /// First load has landed (until then: skeleton, not "no sprite to upgrade").
    @State private var loaded = false
    @State private var attachments: [HDPackAuthoring.Attachment] = []
    @State private var heading = 0
    @State private var autoSpin = false
    @State private var atlas: HDAtlas?
    @State private var atlasError: String?
    @State private var modelImage: CGImage?
    @StateObject private var previewer = HDModelPreviewer()
    @State private var status: String?

    // Sprite attach form
    @State private var pngURL: URL?
    @State private var pngData: Data?
    @State private var scale = "2"
    @State private var columns = ""
    @State private var frameCount = ""
    @State private var overlays = 0     // 0 default, 1 keep, 2 hide
    @State private var pngValidation: (ok: Bool, message: String)?

    // Model attach form
    @State private var usdzURL: URL?
    @State private var usdzData: Data?
    @State private var pitch = ""
    @State private var yaw = ""
    @State private var tilt = ""
    @State private var bankRoll = ""
    @State private var fit = ""
    @State private var exposure = ""
    @State private var bakeScale = ""
    @State private var spin = ""

    private struct TaskKey: Hashable { let key: ResourceKey; let revision: Int }
    private struct Loaded {
        var target: Target?
        var classic: EditorDecodedSprite?
        var attachments: [HDPackAuthoring.Attachment]
        var layerCount: Int
        var atlas: HDAtlas?
        var atlasError: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = target {
                compare(t)
                attachmentList(t)
                spriteForm(t)
                modelForm(t)
                exportSection
                if let status { Label(status, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else if !loaded {
                SkeletonForm(groups: 3)
            } else {
                EditorEmptyState(icon: "cube.transparent", title: "No sprite to upgrade",
                                 subtitle: "This resource doesn't resolve to a sprite id (no shän / spïn / rlëD reached).")
            }
        }
        .task(id: TaskKey(key: key, revision: model.dataRevision)) { await refresh() }
        .task(id: "\(heading)-\(model.dataRevision)") { renderModelFrame() }
    }

    // MARK: Resolve + load

    nonisolated private static func resolve(_ d: SpecData, key: ResourceKey) -> Target? {
        let c = d.collection
        func sid(_ t: NovaSwiftKit.FourCharCode, _ id: Int) -> Int? { HDPackAuthoring.spriteID(forType: t, id: id, in: c) }
        switch key.type {
        case NovaType.ship, NovaType.shan:
            guard let s = sid(NovaType.shan, key.id) else { return nil }
            return Target(spriteID: s, classic: d.game.shipSprite(key.id), framesPerSet: d.game.shan(key.id)?.framesPerSet ?? 36, label: "hull base sprite")
        case NovaType.spin:
            guard let s = sid(NovaType.spin, key.id) else { return nil }
            let sheet = d.game.spinSheet(key.id)
            return Target(spriteID: s, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "spïn sprite")
        case NovaType.rleD, NovaType.pict:
            let sheet = c.resource(key.type, key.id).flatMap { EditorSpriteCache.shared.decode(type: key.type, id: key.id, data: $0.data).0?.sheet }
            return Target(spriteID: key.id, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "sprite")
        case NovaType.spob:
            guard let s = sid(NovaType.spob, key.id) else { return nil }
            let sheet = d.game.spobSprite(key.id)
            return Target(spriteID: s, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "stellar sprite")
        case NovaType.weapon:
            guard let spin = d.game.weapon(key.id)?.graphicSpinID, let s = sid(NovaType.spin, spin) else { return nil }
            let sheet = d.game.weaponSprite(spinID: spin)
            return Target(spriteID: s, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "shot sprite (spïn #\(spin))")
        case NovaType.boom:
            guard let spin = d.game.boom(key.id)?.graphicSpinID, let s = sid(NovaType.spin, spin) else { return nil }
            let sheet = d.game.boomSprite(key.id)?.sheet
            return Target(spriteID: s, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "explosion sprite (spïn #\(spin))")
        case NovaType.roid:
            guard let s = sid(NovaType.spin, key.id + 672) else { return nil }
            let sheet = d.game.asteroidSprite(key.id)
            return Target(spriteID: s, classic: sheet, framesPerSet: sheet?.frameCount ?? 1, label: "asteroid sprite")
        default: return nil
        }
    }

    /// Resolve the sprite, scan attachments (JSON-decodes every descriptor) and decode the
    /// classic sheet + HD atlas — all off the main actor.
    private func refresh() async {
        let k = key
        let layer = model.document.layer
        let r = await SpecCache.compute(model) { d -> Loaded in
            let t = Self.resolve(d, key: k)
            let layerCount = HDPackAuthoring.attachments(in: layer).count
            guard let t else { return Loaded(target: nil, classic: nil, attachments: [], layerCount: layerCount, atlas: nil, atlasError: nil) }
            let classic = t.classic.flatMap { EditorDecodedSprite($0) }
            let atts = HDPackAuthoring.attachments(in: d.collection).filter { $0.spriteID == t.spriteID }
            var atlas: HDAtlas?
            var atlasError: String?
            if let a = atts.first, a.kind == .sprite, let sheet = t.classic,
               let blobID = a.blobID, let blob = d.collection.resource(GraphicsEnhancementType.blob, blobID)?.data {
                do { atlas = try HDAtlas.load(blob, descriptor: a.descriptor, classic: sheet, maxScale: 4) }
                catch { atlasError = "\(error)" }
            }
            return Loaded(target: t, classic: classic, attachments: atts, layerCount: layerCount, atlas: atlas, atlasError: atlasError)
        }
        if Task.isCancelled { return }
        target = r.target; classicSprite = r.classic; attachments = r.attachments
        layerAttachmentCount = r.layerCount; atlas = r.atlas; atlasError = r.atlasError
        loaded = true
        renderModelFrame()
    }

    private func renderModelFrame() {
        guard let t = target, let a = attachments.first, a.kind == .model,
              let blobID = a.blobID, let blob = model.effective.resource(GraphicsEnhancementType.blob, blobID)?.data else {
            modelImage = nil; return
        }
        let frames = max(1, t.framesPerSet)
        modelImage = previewer.render(blob: blob, settings: a.descriptor.bake ?? .init(),
                                      headingDegrees: Double(heading % frames) * 360 / Double(frames), size: 240)
    }

    // MARK: Compare

    private func compare(_ t: Target) -> some View {
        let frames = max(1, t.framesPerSet)
        return SpecSection(title: "Classic vs HD", trailing: "sprite #\(t.spriteID) · \(t.label)") {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    pane("Classic", image: classicImage(t))
                    pane(attachments.first.map { $0.kind == .model ? "3D model (auto-framed)" : "HD sprite ×\(SpecFormat.num($0.descriptor.effectiveScale))" } ?? "HD",
                         image: hdImage(t), note: hdNote)
                }
                HStack(spacing: 12) {
                    RotationDial(frames: frames, frame: Binding(get: { heading % frames }, set: { heading = $0 }))
                    Slider(value: Binding(get: { Double(heading % frames) }, set: { heading = Int($0) }),
                           in: 0...Double(max(1, frames - 1)), step: 1)
                    Text("frame \(heading % frames)/\(frames)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hdNote: String? {
        if let atlasError { return atlasError }
        if previewer.error != nil, attachments.first?.kind == .model { return previewer.error }
        if attachments.isEmpty { return "Nothing attached" }
        return nil
    }

    private func classicImage(_ t: Target) -> CGImage? {
        classicSprite?.frame(heading % max(1, t.framesPerSet))
    }

    private func hdImage(_ t: Target) -> CGImage? {
        guard let a = attachments.first else { return nil }
        if a.kind == .model { return modelImage }
        guard let atlas else { return nil }
        return atlas.frameImage(heading % max(1, min(t.framesPerSet, atlas.frameCount)))
    }

    private func pane(_ title: String, image: CGImage?, note: String? = nil) -> some View {
        VStack(spacing: 4) {
            ZStack {
                CheckerboardBackground()
                if let image {
                    Image(decorative: image, scale: 1).interpolation(.high).resizable().scaledToFit().padding(8)
                } else {
                    Text(note ?? "No image").font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(10)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Attachments

    private func attachmentList(_ t: Target) -> some View {
        SpecSection(title: "Attachments", trailing: "NSgx / NSbl — ignored by the original game") {
            if attachments.isEmpty {
                Text("No HD sprite or 3D model is attached to sprite #\(t.spriteID).").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(attachments, id: \.spriteID) { a in
                    let own = model.document.layerResource(GraphicsEnhancementType.descriptor, a.spriteID) != nil
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.kind == .model ? "3D model (USDZ)" : "HD sprite atlas (PNG)").font(.system(size: 12, weight: .semibold))
                            Text(detail(a)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(own ? "in this plug-in" : "from the base game or another plug-in (read-only here)")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if own {
                            Button(role: .destructive) { remove(a.spriteID) } label: { Label("Remove", systemImage: "trash") }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ a: HDPackAuthoring.Attachment) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(a.assetByteCount), countStyle: .file)]
        let d = a.descriptor
        if a.kind == .sprite {
            parts.append("×\(SpecFormat.num(d.effectiveScale))"); parts.append("\(d.effectiveColumns) cols")
            if let f = d.frameCount { parts.append("\(f) frames") }
        } else if let b = d.bake {
            if let p = b.pitch { parts.append("pitch \(SpecFormat.num(p))°") }
            if let y = b.yaw { parts.append("yaw \(SpecFormat.num(y))°") }
            if let f = b.fit { parts.append("fit \(SpecFormat.num(f, 2))") }
        }
        if let o = d.overlays { parts.append("overlays \(o.rawValue)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Forms

    private func num(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }
    private func int(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }

    private func spriteForm(_ t: Target) -> some View {
        SpecSection(title: "Attach HD sprite atlas") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Choose PNG…") { pickPNG() }.controlSize(.small)
                    Text(pngURL?.lastPathComponent ?? "no file").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    field("Scale", $scale, width: 50, hint: "px per classic px")
                    field("Columns", $columns, width: 50, hint: "default 6")
                    field("Frames", $frameCount, width: 50, hint: "optional check")
                    Picker("Overlays", selection: $overlays) {
                        Text("Default").tag(0); Text("Keep").tag(1); Text("Hide").tag(2)
                    }.frame(width: 170).controlSize(.small)
                }
                if let v = pngValidation {
                    Label(v.message, systemImage: v.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 11)).foregroundStyle(v.ok ? Color.green : Color.red)
                }
                Button { attachSprite(t) } label: { Label("Attach to sprite #\(t.spriteID)", systemImage: "photo.badge.plus") }
                    .disabled(!(pngValidation?.ok ?? false)).controlSize(.small)
            }
        }
        .onChange(of: scale) { _, _ in validatePNG(t) }
        .onChange(of: columns) { _, _ in validatePNG(t) }
        .onChange(of: frameCount) { _, _ in validatePNG(t) }
    }

    private func modelForm(_ t: Target) -> some View {
        SpecSection(title: "Attach 3D model", trailing: "USDZ · nose +Z, Y up") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Choose USDZ…") { pickUSDZ() }.controlSize(.small)
                    Text(usdzURL?.lastPathComponent ?? "no file").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Bake options (blank = default)").font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(spacing: 12) {
                    field("Pitch°", $pitch, width: 46, hint: "38"); field("Yaw°", $yaw, width: 46, hint: "0")
                    field("Tilt°", $tilt, width: 46, hint: "0"); field("Bank°", $bankRoll, width: 46, hint: "30")
                }
                HStack(spacing: 12) {
                    field("Fit", $fit, width: 46, hint: "1"); field("Exposure", $exposure, width: 46, hint: "1")
                    field("Scale", $bakeScale, width: 46, hint: "px/px"); field("Spin °/s", $spin, width: 46, hint: "planets")
                }
                Button { attachModel(t) } label: { Label("Attach to sprite #\(t.spriteID)", systemImage: "cube.badge.plus") }
                    .disabled(usdzData == nil).controlSize(.small)
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, width: CGFloat, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(hint, text: text).textFieldStyle(.roundedBorder).frame(width: width).font(.system(size: 11, design: .monospaced))
        }
    }

    private var exportSection: some View {
        let count = layerAttachmentCount
        return SpecSection(title: "Export", trailing: "\(count) attachment\(count == 1 ? "" : "s") in this plug-in") {
            HStack {
                Button { exportPack() } label: { Label("Export HD layer as .nsx pack…", systemImage: "square.and.arrow.up") }
                    .disabled(count == 0).controlSize(.small)
                Text("A sidecar folder players can drop next to any plug-in.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Actions

    private func pickPNG() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png]; p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        pngURL = url; pngData = data
        if let t = target { validatePNG(t) }
    }

    private func pickUSDZ() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "usdz") ?? .data]; p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        usdzURL = url; usdzData = data
    }

    private func descriptorFromForm() -> GraphicsEnhancement {
        GraphicsEnhancement(kind: .sprite, scale: num(scale) ?? 2, columns: int(columns), frameCount: int(frameCount),
                            overlays: overlays == 1 ? .keep : (overlays == 2 ? .hide : nil))
    }

    private func validatePNG(_ t: Target) {
        guard let data = pngData else { pngValidation = nil; return }
        guard let classic = t.classic else {
            pngValidation = (false, "No classic sheet to check against."); return
        }
        let desc = descriptorFromForm()
        Task {
            let r: Result<HDAtlas, Error> = await Task.detached { Result { try HDAtlas.load(data, descriptor: desc, classic: classic, maxScale: 64) } }.value
            switch r {
            case .success(let a): pngValidation = (true, "OK — \(a.frameCount) frames, \(a.frameWidth)×\(a.frameHeight) classic px at ×\(SpecFormat.num(desc.effectiveScale))")
            case .failure(let e): pngValidation = (false, "\(e)")
            }
        }
    }

    private func attachSprite(_ t: Target) {
        guard let data = pngData else { return }
        let d = descriptorFromForm()
        apply("Attach HD sprite to #\(t.spriteID)") { c in
            _ = try HDPackAuthoring.attachSprite(png: data, spriteID: t.spriteID, scale: d.effectiveScale, columns: d.columns,
                                                 frameCount: d.frameCount, overlays: d.overlays, name: pngURL?.deletingPathExtension().lastPathComponent ?? "", to: &c)
        }
    }

    private func attachModel(_ t: Target) {
        guard let data = usdzData else { return }
        var bake = GraphicsEnhancement.BakeSettings(pitch: num(pitch), yaw: num(yaw), bankRoll: num(bankRoll), fit: num(fit),
                                                    exposure: num(exposure), scale: num(bakeScale), spin: num(spin))
        bake.tilt = num(tilt)
        let empty = GraphicsEnhancement.BakeSettings()
        apply("Attach 3D model to #\(t.spriteID)") { c in
            _ = try HDPackAuthoring.attachModel(usdz: data, spriteID: t.spriteID, bake: bake == empty ? nil : bake,
                                                name: usdzURL?.deletingPathExtension().lastPathComponent ?? "", to: &c)
        }
    }

    private func remove(_ spriteID: Int) {
        apply("Remove HD art from #\(spriteID)") { c in _ = HDPackAuthoring.remove(spriteID: spriteID, from: &c) }
    }

    /// Run an authoring mutation on a copy of the plug-in layer, then replay the NSgx / NSbl
    /// differences through the document as one undo step.
    private func apply(_ label: String, _ mutate: (inout ResourceCollection) throws -> Void) {
        let before = model.document.layer
        var c = before
        do { try mutate(&c) } catch { status = "\(error)"; return }
        let doc = model.document
        doc.withGroup(label) {
            for t in [GraphicsEnhancementType.descriptor, GraphicsEnhancementType.blob] {
                for r in c.resources(of: t) where before.resource(t, r.id) != r { _ = doc.put(r, label: label) }
                for r in before.resources(of: t) where c.resource(t, r.id) == nil { _ = doc.remove(t, r.id) }
            }
        }
        status = label
    }

    private func exportPack() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(model.document.name).\(GraphicsPackManifest.folderExtension)"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let n = try HDPackAuthoring.exportPack(from: model.document.layer, to: url, name: model.document.name)
            status = "Exported \(n) enhancement\(n == 1 ? "" : "s") to \(url.lastPathComponent)"
        } catch { status = "Export failed: \(error)" }
    }
}
#endif
