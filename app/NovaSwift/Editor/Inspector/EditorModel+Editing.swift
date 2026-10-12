#if os(macOS)
import SwiftUI
import NovaSwiftKit

extension EditorModel {
    /// Replace a resource's bytes (and optionally its name), creating the plug-in
    /// override if needed. Consecutive calls with the same `coalesce` merge into
    /// one undo step.
    @discardableResult
    func writeData(_ data: Data, for key: ResourceKey, name: String? = nil,
                   label: String, coalesce: String? = nil) -> Bool {
        let old = document.resource(key.type, key.id)
        let r = Resource(type: key.type, id: key.id, name: name ?? old?.name ?? "",
                         attributes: old?.attributes ?? 0, data: data)
        return document.put(r, label: label, coalesce: coalesce)
    }

    func rename(_ key: ResourceKey, to name: String) {
        guard let old = document.resource(key.type, key.id), old.name != name else { return }
        document.put(Resource(type: key.type, id: key.id, name: name, attributes: old.attributes, data: old.data),
                     label: "Rename \(key)", coalesce: "name/\(key)")
    }
}

/// What a field row / hex view share: model, label lookup and navigation.
@MainActor
struct EditorEnv {
    let model: EditorModel
    let cache: EditorBrowseCache
    func label(_ type: NovaSwiftKit.FourCharCode, _ id: Int) -> String { cache.label(type, id, model) }
    func exists(_ type: NovaSwiftKit.FourCharCode, _ id: Int) -> Bool { model.effective.resource(type, id) != nil }
    func jump(_ type: NovaSwiftKit.FourCharCode, _ id: Int) { model.navigate(to: ResourceKey(type, id)) }
}

/// Which bytes the hovered form field covers (observed only by the bytes panel).
@MainActor
final class EditorHoverState: ObservableObject {
    @Published var range: Range<Int>?
}
#endif
