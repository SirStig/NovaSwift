import Foundation

/// One plug-in's persisted enabled flag; the array order of a persisted list *is*
/// the load order. Keyed by `PluginBundle.id` (stable folder / file name).
public struct PluginEnableState: Codable, Equatable, Sendable {
    public let id: String
    public let isEnabled: Bool
    public init(id: String, isEnabled: Bool) { self.id = id; self.isEnabled = isEnabled }
}

/// Frontend-independent plug-in set management: how a freshly discovered plug-in
/// list is combined with the persisted enable/order state, and how the manual
/// enable switch / load-order move behave. Shared by the Apple app
/// (`GameDataController`) and the Godot bridge so both load plug-ins identically.
public enum PluginSet {

    /// Folds persisted state (and `inMemoryEnabled`, the ids enabled earlier this
    /// session) into `discovered`, restores load order and resolves the original
    /// vs. manual-order rules (`GameLibrary.originalPluginOrder`).
    ///
    /// Persisted state wins for order (the only durable record of a reorder);
    /// plug-ins never seen before fall after all known ones, alphabetically.
    public static func arrange(discovered: [PluginBundle], persisted: [PluginEnableState],
                               inMemoryEnabled: Set<String> = [], manual: Bool) -> [PluginBundle] {
        var discovered = discovered
        let persistedOrder = Dictionary(persisted.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let previouslyEnabled = inMemoryEnabled.union(persisted.filter(\.isEnabled).map(\.id))
        for i in discovered.indices where previouslyEnabled.contains(discovered[i].id) {
            discovered[i].isEnabled = true
        }
        discovered.sort { a, b in
            switch (persistedOrder[a.id], persistedOrder[b.id]) {
            case let (ai?, bi?): return ai < bi
            case (nil, nil): return (a.id.uppercased(), a.id) < (b.id.uppercased(), b.id)
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        if manual {
            // A total conversion replaces the base scenario, so at most one is selected.
            var seenTC = false
            for i in discovered.indices.reversed() where discovered[i].isTotalConversion && discovered[i].isEnabled {
                if seenTC { discovered[i].isEnabled = false }
                seenTC = true
            }
        }
        return manual ? discovered : GameLibrary.originalPluginOrder(discovered)
    }

    /// The enable switch. Only the manual-order enhancement may toggle ordinary
    /// plug-ins; a total conversion may always be chosen (one at a time).
    /// Returns false (nothing changed) when the request is not allowed.
    @discardableResult
    public static func setEnabled(_ plugins: inout [PluginBundle], id: String, enabled: Bool, manual: Bool) -> Bool {
        guard let i = plugins.firstIndex(where: { $0.id == id }),
              manual || plugins[i].isTotalConversion else { return false }
        plugins[i].isEnabled = enabled
        if enabled && plugins[i].isTotalConversion {
            for j in plugins.indices where j != i && plugins[j].isTotalConversion { plugins[j].isEnabled = false }
        }
        return true
    }

    /// Moves `id` by `offset` places (negative = earlier / lower priority). Only
    /// meaningful with manual order; false when not applicable or it would run off an end.
    @discardableResult
    public static func move(_ plugins: inout [PluginBundle], id: String, by offset: Int, manual: Bool) -> Bool {
        guard manual, let i = plugins.firstIndex(where: { $0.id == id }) else { return false }
        let j = i + offset
        guard plugins.indices.contains(j) else { return false }
        plugins.swapAt(i, j)
        return true
    }

    public static func persistedState(of plugins: [PluginBundle]) -> [PluginEnableState] {
        plugins.map { PluginEnableState(id: $0.id, isEnabled: $0.isEnabled) }
    }
}
