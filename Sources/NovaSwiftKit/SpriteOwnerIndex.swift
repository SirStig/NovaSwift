import Foundation

/// Which game objects draw with each sprite id: hulls (and which `shän` layer),
/// stellars (and the systems they sit in), weapon shots, explosions, asteroids,
/// and the remaining `spïn`s. It walks the resource tables only — no sprite is
/// decoded — so building it once per loaded game is cheap. The HD viewer uses
/// it to show real names instead of bare sprite ids.
///
/// The id each type resolves to is the one the game itself draws with:
/// `shän` layer ids directly; `spöb` → `spïn` (Graphic + 1000, falling back to
/// an `rlëD` of that id, as `NovaGame.collisionMask` does); `wëap` → `spïn`
/// (+3000); `bööm` → `spïn` (+400); `röid` → `spïn` (röidID + 672).
public struct SpriteOwnerIndex: Sendable {
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case ships = "Ships", stellars = "Stellars", weapons = "Weapons"
        case explosions = "Explosions", asteroids = "Asteroids", other = "Other"
        public var id: String { rawValue }
    }

    /// Which `shän` layer a hull draws a sprite with.
    public enum ShipLayer: String, CaseIterable, Sendable {
        case base, alt, engine, lights, weapons, shield
    }

    public struct Owner: Hashable, Sendable {
        public let category: Category
        /// The owning resource's id (shïp / spöb / wëap / bööm / röid / spïn).
        public let resourceID: Int
        public let name: String
        /// Set for ships only.
        public let layer: ShipLayer?
        /// Systems a stellar sits in (id, name), sorted by id.
        public let systems: [SystemRef]
        /// The `spïn` the sprite was reached through, nil for ship layers.
        public let spinID: Int?

        public struct SystemRef: Hashable, Sendable {
            public let id: Int
            public let name: String
        }
    }

    public struct Entry: Identifiable, Sendable {
        public var id: Int { spriteID }
        public let spriteID: Int
        /// Every owner, primary-category owners first, then by id.
        public let owners: [Owner]
        public var category: Category { owners.first?.category ?? .other }
        /// One owner per resource of the entry's own category (what the title
        /// counts; a hull using the sprite on two layers counts once).
        public var primaryOwners: [Owner] {
            var seen = Set<Int>()
            return owners.filter { $0.category == category && seen.insert($0.resourceID).inserted }
        }

        /// "Kestrel", "Kestrel (+3 variants)", "Earth (+1 more)".
        public var title: String {
            SpriteOwnerIndex.title(names: primaryOwners.map(\.name), category: category)
        }
        /// Lower-cased text the search field matches: names, ids, system names.
        public var searchText: String {
            var parts = ["\(spriteID)", "#\(spriteID)"]
            for o in owners {
                parts.append(o.name); parts.append("\(o.resourceID)")
                parts.append(contentsOf: o.systems.map(\.name))
                if let l = o.layer { parts.append(l.rawValue) }
            }
            return parts.joined(separator: " ").lowercased()
        }
        public var systems: [Owner.SystemRef] {
            var seen = Set<Int>(), out: [Owner.SystemRef] = []
            for s in owners.flatMap(\.systems) where seen.insert(s.id).inserted { out.append(s) }
            return out.sorted { $0.id < $1.id }
        }
        /// Distinct hull ids that draw this sprite (any layer), by id.
        public var shipIDs: [Int] {
            Array(Set(owners.filter { $0.category == .ships }.map(\.resourceID))).sorted()
        }
        /// The `spïn` this sprite was reached through, if any.
        public var spinID: Int? { owners.lazy.compactMap(\.spinID).first }
    }

    public let entries: [Int: Entry]

    public init(entries: [Int: Entry]) { self.entries = entries }

    public subscript(spriteID: Int) -> Entry? { entries[spriteID] }

    /// Entries sorted by category, then name, then id.
    public var sorted: [Entry] {
        entries.values.sorted {
            if $0.category != $1.category { return Category.allCases.firstIndex(of: $0.category)! < Category.allCases.firstIndex(of: $1.category)! }
            let a = $0.title.localizedLowercase, b = $1.title.localizedLowercase
            return a != b ? a < b : $0.spriteID < $1.spriteID
        }
    }

    // MARK: Pure helpers

    public static func title(names: [String], category: Category) -> String {
        guard let first = names.first else { return "" }
        let extra = names.count - 1
        guard extra > 0 else { return first }
        let noun = category == .ships ? (extra == 1 ? "variant" : "variants") : "more"
        return "\(first) (+\(extra) \(noun))"
    }

    // MARK: Build

    public init(game: NovaGame) {
        var owners: [Int: [Owner]] = [:]
        func add(_ sprite: Int, _ owner: Owner) {
            guard sprite > 0 else { return }
            owners[sprite, default: []].append(owner)
        }
        /// A spïn's sprite id, or nil when the spïn doesn't exist.
        func spinSprite(_ spinID: Int) -> Int? { game.spin(spinID)?.spriteID }

        // Hulls, per shän layer. A shän shares its id with its shïp.
        for ship in game.ships() {
            guard let shan = game.shan(ship.id) else { continue }
            let layers: [(ShipLayer, Int)] = [
                (.base, shan.baseSpriteID), (.alt, shan.hasAltLayer ? shan.altSpriteID : 0),
                (.engine, shan.engineSpriteID), (.lights, shan.lightSpriteID),
                (.weapons, shan.weaponGlowSpriteID), (.shield, shan.shieldSpriteID),
            ]
            for (layer, id) in layers {
                add(id, Owner(category: .ships, resourceID: ship.id, name: ship.displayName,
                              layer: layer, systems: [], spinID: nil))
            }
        }

        // Stellars, with the systems that place them.
        var systemsOf: [Int: [Owner.SystemRef]] = [:]
        for s in game.systems() {
            for spob in s.spobs { systemsOf[spob, default: []].append(.init(id: s.id, name: s.displayName)) }
        }
        for spob in game.spobs() {
            let sprite: Int?
            if let spin = game.spin(spob.graphicSpinID) { sprite = spin.spriteID }
            else if game.resources.resource(NovaType.rleD, spob.graphicSpinID) != nil { sprite = spob.graphicSpinID }
            else { sprite = nil }
            guard let sprite else { continue }
            add(sprite, Owner(category: .stellars, resourceID: spob.id, name: spob.displayName, layer: nil,
                              systems: (systemsOf[spob.id] ?? []).sorted { $0.id < $1.id },
                              spinID: game.spin(spob.graphicSpinID) != nil ? spob.graphicSpinID : nil))
        }

        for w in game.weapons() {
            guard let spin = w.graphicSpinID, let sprite = spinSprite(spin) else { continue }
            add(sprite, Owner(category: .weapons, resourceID: w.id, name: w.name, layer: nil, systems: [], spinID: spin))
        }
        for r in game.resources.resources(of: NovaType.boom) {
            let b = BoomRes(r)
            guard let sprite = spinSprite(b.graphicSpinID) else { continue }
            add(sprite, Owner(category: .explosions, resourceID: b.id, name: b.name, layer: nil, systems: [], spinID: b.graphicSpinID))
        }
        for a in game.roids() {
            let spin = a.id + 672
            guard let sprite = spinSprite(spin) else { continue }
            add(sprite, Owner(category: .asteroids, resourceID: a.id, name: a.name, layer: nil, systems: [], spinID: spin))
        }

        // Every other spïn (UI art, starfield, …), named by its own resource.
        for r in game.resources.resources(of: NovaType.spin) {
            let sprite = SpinRes(r).spriteID
            guard sprite > 0, owners[sprite] == nil else { continue }
            let name = r.name.isEmpty ? (r.id == 700 ? "Stars (background)" : "spïn #\(r.id)") : r.name
            add(sprite, Owner(category: .other, resourceID: r.id, name: name, layer: nil, systems: [], spinID: r.id))
        }

        var entries: [Int: Entry] = [:]
        for (sprite, list) in owners {
            // Primary category: first by Category order, preferring hulls' base layer.
            let sorted = list.sorted { a, b in
                let ai = Category.allCases.firstIndex(of: a.category)!, bi = Category.allCases.firstIndex(of: b.category)!
                if ai != bi { return ai < bi }
                let ab = a.layer == .base ? 0 : 1, bb = b.layer == .base ? 0 : 1
                if ab != bb { return ab < bb }
                return a.resourceID < b.resourceID
            }
            entries[sprite] = Entry(spriteID: sprite, owners: sorted)
        }
        self.entries = entries
    }
}
