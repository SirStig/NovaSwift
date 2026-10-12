#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit
import NovaSwiftEngine

// MARK: - Shared plumbing for the specialised inspectors (ship / weapon / outfit /
// shän / HD). Everything here is read-only over `EditorModel.effective`; writes go
// through `EditorModel.setValue` / `writeData` so they stay undoable.

/// The engine's catalog (game data + `Galaxy`) for one revision of the effective
/// collection. Both are lazy and cheap to build; the box exists so decode work can
/// hop to a background task.
final class SpecData: @unchecked Sendable {
    let game: NovaGame
    let galaxy: Galaxy
    let collection: ResourceCollection
    let revision: Int
    /// `Galaxy` keeps unsynchronised memo dictionaries, so catalog work on one `SpecData`
    /// is serialised (`SpecCache.compute`). `NovaGame` itself is lock-guarded.
    let lock = NSLock()

    init(_ collection: ResourceCollection, revision: Int) {
        self.collection = collection
        self.revision = revision
        let g = NovaGame(collection)
        self.game = g
        self.galaxy = Galaxy(game: g, flightTuning: .default)
    }
}

/// Carries a value computed off the main actor back to it (decoded catalogs and sprite
/// sheets aren't `Sendable`, but each result is only read after it has been handed over).
struct SpecBox<T>: @unchecked Sendable { let value: T }

/// One `SpecData` per (model, data revision): inspectors on the same revision share it, so
/// stats are only recomputed when resource data actually changed (not on Save/metadata).
@MainActor
enum SpecCache {
    private static var cached: (model: ObjectIdentifier, revision: Int, data: SpecData)?

    /// Cheap on the main actor (building `NovaGame`/`Galaxy` is lazy); all decoding happens
    /// when the result is *used* — do that through `compute`, never directly in a `body`.
    static func data(_ model: EditorModel) -> SpecData {
        let id = ObjectIdentifier(model)
        if let c = cached, c.model == id, c.revision == model.dataRevision { return c.data }
        let d = SpecData(model.effective, revision: model.dataRevision)
        cached = (id, model.dataRevision, d)
        return d
    }

    /// Run `work` against this revision's catalog on a background thread and return the
    /// result on the main actor. `NovaGame`'s decode caches are lock-guarded and shared, so
    /// concurrent inspectors reuse each other's decodes.
    static func compute<T>(_ model: EditorModel, _ work: @escaping @Sendable (SpecData) -> T) async -> T {
        let d = data(model)
        let box = await Task.detached(priority: .userInitiated) { () -> SpecBox<T> in
            d.lock.lock(); defer { d.lock.unlock() }
            return SpecBox(value: work(d))
        }.value
        return box.value
    }
}

// MARK: - Layered ship sprites

/// A hull's decoded `shän` layers (frame sheets), ready to composite.
struct ShipLayerSet: @unchecked Sendable {
    var shan: ShanRes
    var base: EditorDecodedSprite?
    var alt: EditorDecodedSprite?
    var engine: EditorDecodedSprite?
    var lights: EditorDecodedSprite?
    var weaponGlow: EditorDecodedSprite?
    var shield: EditorDecodedSprite?

    /// Headings per full turn (`FramesPer`).
    var headings: Int { max(1, shan.framesPerSet) }
}

/// Small LRU of decoded layer sets so re-selecting / nudging a number doesn't re-decode.
final class ShipLayerCache: @unchecked Sendable {
    static let shared = ShipLayerCache()
    private var store: [Int: ShipLayerSet] = [:]
    private var order: [Int] = []
    private let lock = NSLock()
    private let capacity = 10

    /// Decode (off the calling actor) the layers of `shän`/ship `id`.
    func load(_ data: SpecData, id: Int) async -> ShipLayerSet? {
        await Task.detached(priority: .userInitiated) { [self] in loadSync(data, id: id) }.value
    }

    private func loadSync(_ data: SpecData, id: Int) -> ShipLayerSet? {
        guard let shan = data.game.shan(id) else { return nil }
        let c = data.collection
        func fp(_ spriteID: Int) -> Int {
            if let r = c.resource(NovaType.rleD, spriteID) { return r.data.hashValue }
            if let r = c.resource(NovaType.pict, spriteID) { return r.data.hashValue }
            return 0
        }
        var h = Hasher()
        h.combine(id)
        // Only decode-relevant shän fields (not hardpoints), so dragging a point never re-decodes.
        for v in [shan.baseSetCount, shan.baseWidth, shan.baseHeight, shan.altSetCount, shan.altWidth, shan.altHeight,
                  shan.engineWidth, shan.engineHeight, shan.lightWidth, shan.lightHeight, shan.weaponGlowWidth,
                  shan.weaponGlowHeight, shan.shieldWidth, shan.shieldHeight, shan.framesPerSet] { h.combine(v) }
        for s in [shan.baseSpriteID, shan.altSpriteID, shan.engineSpriteID, shan.lightSpriteID,
                  shan.weaponGlowSpriteID, shan.shieldSpriteID] { h.combine(fp(s)) }
        for m in [shan.baseMaskID, shan.altMaskID, shan.engineMaskID, shan.lightMaskID,
                  shan.weaponGlowMaskID, shan.shieldMaskID] { h.combine(fp(m)) }
        let key = h.finalize()
        lock.lock()
        if var hit = store[key] { order.removeAll { $0 == key }; order.append(key); lock.unlock(); hit.shan = shan; return hit }
        lock.unlock()

        let g = data.game
        func dec(_ s: SpriteSheet?) -> EditorDecodedSprite? { s.flatMap { EditorDecodedSprite($0) } }
        let set = ShipLayerSet(shan: shan, base: dec(g.shipSprite(id)), alt: dec(g.altSprite(id)),
                               engine: dec(g.engineGlowSprite(id)), lights: dec(g.lightSprite(id)),
                               weaponGlow: dec(g.weaponGlowSprite(id)), shield: dec(g.shieldSprite(id)))
        lock.lock()
        store[key] = set; order.append(key)
        while order.count > capacity { store[order.removeFirst()] = nil }
        lock.unlock()
        return set
    }
}

/// Which `shän` layers are drawn.
struct ShipLayerToggles: Equatable {
    var base = true
    var alt = true
    var engine = true      // engine glow (the "thrusting" overlay)
    var lights = true
    var weaponGlow = false
    var shield = false
}

enum ShipCompositor {
    /// Draw the hull layers centred on `center`, at `zoom` screen px per sprite px.
    /// `heading` is the frame within a rotation (0 = nose up, clockwise).
    static func draw(_ ctx: GraphicsContext, center: CGPoint, zoom: CGFloat, layers: ShipLayerSet,
                     heading: Int, altStep: Int, toggles: ShipLayerToggles) {
        func put(_ sprite: EditorDecodedSprite?, frame: Int, additive: Bool, opacity: Double = 1) {
            guard let sprite, let cg = sprite.frame(frame) else { return }
            let w = CGFloat(sprite.sheet.frameWidth) * zoom, h = CGFloat(sprite.sheet.frameHeight) * zoom
            var c = ctx
            if additive { c.blendMode = .plusLighter }
            c.opacity = opacity
            let img = Image(decorative: cg, scale: 1).interpolation(.none)
            c.draw(img, in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        }
        func rotFrame(_ s: EditorDecodedSprite?) -> Int {
            guard let s, s.sheet.frameCount > 0 else { return 0 }
            return s.sheet.frameCount == 1 ? 0 : heading % s.sheet.frameCount
        }
        let shan = layers.shan
        if toggles.base { put(layers.base, frame: rotFrame(layers.base), additive: false, opacity: shan.baseOpacity) }
        if toggles.alt, shan.hasAltLayer, let alt = layers.alt, alt.sheet.frameCount > 0 {
            let step = altStep % max(1, shan.altSetCount)
            put(alt, frame: min(alt.sheet.frameCount - 1, step * layers.headings + heading), additive: false)
        }
        if toggles.engine { put(layers.engine, frame: rotFrame(layers.engine), additive: true) }
        if toggles.lights { put(layers.lights, frame: rotFrame(layers.lights), additive: true) }
        if toggles.weaponGlow { put(layers.weaponGlow, frame: rotFrame(layers.weaponGlow), additive: true) }
        if toggles.shield { put(layers.shield, frame: rotFrame(layers.shield), additive: true, opacity: 0.8) }
    }

    /// Auto-spin heading for a timeline date.
    static func spinHeading(_ date: Date, headings: Int, turnsPerSecond: Double = 0.25) -> Int {
        let t = date.timeIntervalSinceReferenceDate * turnsPerSecond
        return Int((t - t.rounded(.down)) * Double(headings)) % max(1, headings)
    }

    /// Alt-layer step for a timeline date (cycles at the shän's AnimDelay, 1/30 s units).
    static func altStep(_ date: Date, shan: ShanRes) -> Int {
        guard shan.hasAltLayer else { return 0 }
        let period = Double(max(1, shan.animDelay)) / 30.0
        return Int(date.timeIntervalSinceReferenceDate / period) % max(1, shan.altSetCount)
    }
}

// MARK: - Small shared views

/// "Test fly" etc. use this to hand a request to the shell.
struct SpecSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A read-only "label ... value" stat row.
struct StatRow: View {
    let label: String
    let value: String
    var note: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, design: .monospaced))
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}

/// An editable numeric stat that writes straight to a schema field (one coalesced
/// undo step per field while typing) with the game-unit meaning shown beside it.
struct InlineStat: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    var label: String? = nil
    var note: String = ""

    var body: some View {
        let f = ResourceSchemas.schema(for: key.type)?.field(field)
        let v = model.readValue(field, of: key)?.intValue ?? 0
        let range = Self.range(of: f)
        HStack(spacing: 6) {
            Text(label ?? f?.label ?? field).font(.system(size: 12)).foregroundStyle(.secondary)
                .help(f?.help ?? "")
            Spacer(minLength: 6)
            NumberField(value: v, range: range, stepper: false, width: 78) { n in
                model.setValue(.int(n), field: field, of: key)
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).frame(minWidth: 70, alignment: .leading)
            }
        }
    }
}

extension InlineStat {
    static func range(of f: SchemaField?) -> ClosedRange<Int> {
        guard let kind = f?.kind else { return -32768...32767 }
        switch kind {
        case let .int(w, s): return editorIntRange(w, signed: s)
        case let .enumeration(w, s): return editorIntRange(w, signed: s)
        default: return -32768...32767
        }
    }
}

/// A link chip that jumps to another resource.
struct ResourceChip: View {
    let env: EditorEnv
    let type: NovaSwiftKit.FourCharCode
    let id: Int
    var suffix: String = ""

    var body: some View {
        let exists = env.exists(type, id)
        Button { if exists { env.jump(type, id) } } label: {
            HStack(spacing: 4) {
                Text(type.stringValue).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Text("\(env.label(type, id))\(suffix)").font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(exists ? Color.primary : Color.red)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping flow layout for chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); width = max(width, x)
        }
        return CGSize(width: min(maxW, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

/// Number formatting helpers.
enum SpecFormat {
    static func num(_ v: Double, _ digits: Int = 1) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        return String(format: "%.\(digits)f", v)
    }
    static func credits(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " cr"
    }
}

/// Which spöbs list a ship / outfit for sale (tech level + special tech; ignores the
/// day's BuyRandom roll and NCB gates, which depend on the player).
enum SpecAvailability {
    static func spobs(sellingShip s: ShipRes, game: NovaGame) -> [SpobRes] {
        game.spobs().filter { spob in
            spob.hasShipyard && s.techLevel >= 0
                && (s.techLevel <= spob.techLevel || game.spobSpecialTech(spob.id).contains(s.techLevel))
        }
    }

    static func spobs(sellingOutfit o: OutfRes, game: NovaGame) -> [SpobRes] {
        guard o.techLevel >= 0, o.techLevel < 0x7fff else { return [] }
        return game.spobs().filter { spob in
            spob.hasOutfitter && (spob.techLevel >= o.techLevel || game.spobSpecialTech(spob.id).contains(o.techLevel))
        }
    }
}

/// Tab strip + routing state, per resource type.
enum SpecTab: String, CaseIterable, Identifiable {
    case overview = "Overview", layers = "Layers & Hardpoints", form = "Form", editor = "Editor", hd = "HD / 3D"
    var id: String { rawValue }
}
#endif
