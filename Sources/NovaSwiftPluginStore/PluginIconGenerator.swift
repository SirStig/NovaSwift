import Foundation
import NovaSwiftKit

/// Builds a card icon for an installed plug-in from its own resources, for
/// catalog entries that have no `iconURL` (or whose URL fails to load).
///
/// Order: a cicn/PICT the plug-in names as its logo or icon, else the first
/// ship's sprite (frame 0), else nothing (the UI shows a neutral placeholder).
public enum PluginIconGenerator {
    public enum Source: Equatable, Sendable {
        case cicn(id: Int)
        case pict(id: Int)
        /// First shïp that resolves to an rlëD sprite.
        case shipSprite(shipID: Int, rleID: Int)
        case none
    }

    /// Pure choice of where the icon comes from.
    public static func selectSource(in resources: ResourceCollection) -> Source {
        func isLogo(_ r: Resource) -> Bool {
            let n = r.name.lowercased()
            return n.contains("logo") || n.contains("icon")
        }
        if let r = resources.resources(of: NovaType.cicn).first(where: isLogo) { return .cicn(id: r.id) }
        if let r = resources.resources(of: NovaType.pict).first(where: isLogo) { return .pict(id: r.id) }
        for ship in resources.resources(of: NovaType.ship) {
            guard let shan = resources.resource(NovaType.shan, ship.id), shan.data.count >= 2 else { continue }
            let base = Int(Int16(bitPattern: UInt16(shan.data[shan.data.startIndex]) << 8
                                 | UInt16(shan.data[shan.data.startIndex + 1])))
            if resources.resource(NovaType.rleD, base) != nil {
                return .shipSprite(shipID: ship.id, rleID: base)
            }
            if let spin = resources.resource(NovaType.spin, base), spin.data.count >= 2 {
                let s = Int(Int16(bitPattern: UInt16(spin.data[spin.data.startIndex]) << 8
                                 | UInt16(spin.data[spin.data.startIndex + 1])))
                if resources.resource(NovaType.rleD, s) != nil { return .shipSprite(shipID: ship.id, rleID: s) }
            }
        }
        return .none
    }

    /// PNG bytes for the chosen source, or nil when it can't be decoded.
    public static func renderPNG(from resources: ResourceCollection) -> Data? {
        var source = selectSource(in: resources)
        // A logo that fails to decode should not hide a usable ship sprite.
        if let png = render(source, resources) { return png }
        if case .shipSprite = source { return nil }
        source = selectShipOnly(in: resources)
        return render(source, resources)
    }

    private static func selectShipOnly(in resources: ResourceCollection) -> Source {
        var stripped = ResourceCollection()
        for t in [NovaType.ship, NovaType.shan, NovaType.spin, NovaType.rleD] {
            for r in resources.resources(of: t) { stripped.add(r) }
        }
        return selectSource(in: stripped)
    }

    private static func render(_ source: Source, _ resources: ResourceCollection) -> Data? {
        let sheet: SpriteSheet?
        switch source {
        case .cicn(let id):
            sheet = resources.resource(NovaType.cicn, id).flatMap { try? CICN.decode($0.data) }
        case .pict(let id):
            sheet = resources.resource(NovaType.pict, id).flatMap { try? PICT.decode($0.data) }
        case .shipSprite(_, let rle):
            sheet = resources.resource(NovaType.rleD, rle).flatMap { try? RLED.decode($0.data) }?.singleFrame(0)
        case .none:
            sheet = nil
        }
        return sheet?.pngData()
    }

    // MARK: - Installed plug-in + disk cache

    /// Icon PNG for installed plug-in `id`: from `cacheDir` when present,
    /// else generated from the files in `pluginsRoot/<id>` and cached (a
    /// zero-byte file records "nothing usable" so it isn't rescanned).
    public static func iconPNG(for id: String, pluginsRoot: URL, cacheDir: URL? = nil) -> Data? {
        let dir = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NovaSwift/PluginGeneratedIcons", isDirectory: true)
        let stamp = PluginInstaller.info(id: id, in: pluginsRoot)?.installedAt.timeIntervalSince1970 ?? 0
        let file = dir.appendingPathComponent("\(id)-\(Int(stamp)).png")
        if let cached = try? Data(contentsOf: file) { return cached.isEmpty ? nil : cached }

        var collection = ResourceCollection()
        let folder = pluginsRoot.appendingPathComponent(id, isDirectory: true).resolvingSymlinksInPath()
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in e where ["rez", "ndat"].contains(url.pathExtension.lowercased()) {
                if let c = try? ResourceFile.read(contentsOf: url) { collection.overlay(c) }
            }
        }
        let png = renderPNG(from: collection)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (png ?? Data()).write(to: file, options: .atomic)
        return png
    }
}
