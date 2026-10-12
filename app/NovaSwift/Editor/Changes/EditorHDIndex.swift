#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// A game object that draws with an HD-upgraded sprite ("Kestrel (ship)").
struct HDOwnerRef: Hashable, Sendable {
    let key: ResourceKey
    let name: String
    let noun: String
    var title: String { name.isEmpty ? "\(noun) #\(key.id)" : "\(name) (\(noun))" }
}

/// One NSgx attachment with the game objects it upgrades.
struct HDAttachmentInfo: Identifiable, Sendable {
    let spriteID: Int
    let attachment: HDPackAuthoring.Attachment
    /// Distinct owners, primary category first. Empty when nothing draws this sprite.
    let owners: [HDOwnerRef]
    /// True when the open plug-in's own layer carries the NSgx (vs. base / another plug-in).
    let inLayer: Bool
    var id: Int { spriteID }

    var title: String {
        guard let first = owners.first else { return "Sprite #\(spriteID)" }
        return owners.count > 1 ? "\(first.title) +\(owners.count - 1) more" : first.title
    }
    var kindText: String {
        attachment.kind == .model ? "3D model" : "HD sprite ×\(SpecFormat.num(attachment.descriptor.effectiveScale))"
    }
    /// Where a click should go: the first owner, else the sprite resource itself.
    var target: ResourceKey? { owners.first?.key }
}

struct HDIndexResult: Sendable {
    let revision: Int
    let attachments: [HDAttachmentInfo]
    /// Resources that should carry an "HD" badge in the browser.
    let badgeKeys: Set<ResourceKey>
    static let empty = HDIndexResult(revision: -1, attachments: [], badgeKeys: [])
}

/// Resolves every NSgx descriptor (keyed by sprite id) to the resources that draw with it,
/// off the main actor, once per data revision. Shared by the Changes view and the browser's
/// HD badges so the (non-trivial) `SpriteOwnerIndex` walk happens at most once.
@MainActor
final class EditorHDIndex: ObservableObject {
    @Published private(set) var result: HDIndexResult?

    private var inflight: (revision: Int, task: Task<HDIndexResult, Never>)?

    private static var current: (model: ObjectIdentifier, index: EditorHDIndex)?

    /// The one index for this editor model.
    static func shared(for model: EditorModel) -> EditorHDIndex {
        let id = ObjectIdentifier(model)
        if let c = current, c.model == id { return c.index }
        let i = EditorHDIndex()
        current = (id, i)
        return i
    }

    func refresh(_ model: EditorModel) async {
        guard model.dataReady else { return }
        let rev = model.dataRevision
        if result?.revision == rev { return }
        let task: Task<HDIndexResult, Never>
        if let f = inflight, f.revision == rev {
            task = f.task
        } else {
            let eff = model.effective, layer = model.document.layer
            task = Task.detached(priority: .utility) { Self.compute(eff: eff, layer: layer, revision: rev) }
            inflight = (rev, task)
        }
        let r = await task.value
        if inflight?.revision == rev { inflight = nil }
        if (result?.revision ?? -1) < r.revision { result = r }
    }

    nonisolated private static func noun(_ c: SpriteOwnerIndex.Category) -> (NovaSwiftKit.FourCharCode, String) {
        switch c {
        case .ships: return (NovaType.ship, "ship")
        case .stellars: return (NovaType.spob, "planet")
        case .weapons: return (NovaType.weapon, "weapon")
        case .explosions: return (NovaType.boom, "explosion")
        case .asteroids: return (NovaType.roid, "asteroid")
        case .other: return (NovaType.spin, "sprite")
        }
    }

    nonisolated private static func compute(eff: ResourceCollection, layer: ResourceCollection,
                                            revision: Int) -> HDIndexResult {
        let atts = HDPackAuthoring.attachments(in: eff)
        guard !atts.isEmpty else { return HDIndexResult(revision: revision, attachments: [], badgeKeys: []) }
        let owners = SpriteOwnerIndex(game: NovaGame(eff))
        let ownLayer = Set(layer.resources(of: GraphicsEnhancementType.descriptor).map(\.id))
        var infos: [HDAttachmentInfo] = []
        var badges = Set<ResourceKey>()
        for a in atts {
            var refs: [HDOwnerRef] = []
            var seen = Set<ResourceKey>()
            if let entry = owners[a.spriteID] {
                let primary = entry.primaryOwners
                let rest = entry.owners.filter { o in !primary.contains(o) }
                for o in primary + rest {
                    let (type, noun) = Self.noun(o.category)
                    let k = ResourceKey(type, o.resourceID)
                    guard seen.insert(k).inserted else { continue }
                    refs.append(HDOwnerRef(key: k, name: o.name, noun: noun))
                    badges.insert(k)
                    if o.category == .ships { badges.insert(ResourceKey(NovaType.shan, o.resourceID)) }
                    if let spin = o.spinID { badges.insert(ResourceKey(NovaType.spin, spin)) }
                }
            }
            badges.insert(ResourceKey(NovaType.rleD, a.spriteID))
            badges.insert(ResourceKey(NovaType.pict, a.spriteID))
            badges.insert(ResourceKey(GraphicsEnhancementType.descriptor, a.spriteID))
            infos.append(HDAttachmentInfo(spriteID: a.spriteID, attachment: a, owners: refs,
                                          inLayer: ownLayer.contains(a.spriteID)))
        }
        return HDIndexResult(revision: revision, attachments: infos, badgeKeys: badges)
    }
}
#endif
