import Foundation

/// A single resource: a typed, numbered, optionally-named blob of bytes.
public struct Resource: Hashable {
    public let type: FourCharCode
    public let id: Int
    public let name: String
    public let attributes: Int
    public let data: Data
    /// Which layer contributed this resource in the merged collection: ""
    /// for the base game, else the owning `PluginBundle.id` — stamped by
    /// `ResourceCollection.overlay(_:tag:)` during `GameLibrary.merge`.
    public var pluginID: String = ""

    public init(type: FourCharCode, id: Int, name: String = "", attributes: Int = 0, data: Data) {
        self.type = type
        self.id = id
        self.name = name
        self.attributes = attributes
        self.data = data
    }
}

/// The parsed contents of one or more resource containers, indexed by (type, id).
///
/// Plug-ins layer over the base game: applying a plug-in's resources with the
/// same (type, id) as a base resource replaces it — which is exactly how EV Nova
/// plug-ins override content. Use `overlay(_:)` to build that chain.
public struct ResourceCollection {
    public private(set) var byType: [FourCharCode: [Int: Resource]] = [:]

    public init() {}

    public mutating func add(_ resource: Resource) {
        byType[resource.type, default: [:]][resource.id] = resource
    }

    /// Merge another collection on top of this one (its resources win on collision).
    /// `tag`, when non-empty, stamps every incoming resource's `pluginID` —
    /// used by `GameLibrary.merge` to record which plug-in (if any) last
    /// contributed each `(type, id)`.
    public mutating func overlay(_ other: ResourceCollection, tag: String = "") {
        for (_, resources) in other.byType {
            for (_, resource) in resources {
                var r = resource
                if !tag.isEmpty { r.pluginID = tag }
                add(r)
            }
        }
    }

    public func resource(_ type: FourCharCode, _ id: Int) -> Resource? {
        byType[type]?[id]
    }

    /// All resources of a type, sorted by id (ascending).
    public func resources(of type: FourCharCode) -> [Resource] {
        (byType[type] ?? [:]).values.sorted { $0.id < $1.id }
    }

    public var types: [FourCharCode] {
        byType.keys.sorted()
    }

    public var totalCount: Int {
        byType.values.reduce(0) { $0 + $1.count }
    }

    /// (type, count) pairs, sorted by type code.
    public var typeCounts: [(type: FourCharCode, count: Int)] {
        byType.map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.type < $1.type }
    }
}
