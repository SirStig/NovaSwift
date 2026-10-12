#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Tab strip + router for the specialised inspectors. `InspectorView` wraps its normal
/// editor (the schema form / graphic editor) in this; types without a specialised view
/// just get the editor back, untouched.
///
///     shïp  → Overview | Form | HD / 3D        wëap → Overview | Form | HD / 3D
///     oütf  → Overview | Form                  shän → Layers & Hardpoints | Form | HD / 3D
///     spïn, rlëD, PICT, spöb, bööm, röid → Editor | HD / 3D
struct SpecializedInspectorRouter<Fallback: View>: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey
    @ViewBuilder var fallback: () -> Fallback

    /// Remembered per resource type so browsing ships keeps you on the Overview.
    @State private var chosen: [UInt32: SpecTab] = [:]

    static func tabs(for type: NovaSwiftKit.FourCharCode) -> [SpecTab] {
        switch type {
        case NovaType.ship, NovaType.weapon: return [.overview, .form, .hd]
        case NovaType.outfit: return [.overview, .form]
        case NovaType.shan: return [.layers, .form, .hd]
        case NovaType.spin, NovaType.rleD, NovaType.pict, NovaType.spob, NovaType.boom, NovaType.roid:
            return [.editor, .hd]
        default: return []
        }
    }

    var body: some View {
        let tabs = Self.tabs(for: key.type)
        if tabs.isEmpty {
            fallback()
        } else {
            let current = chosen[key.type.rawValue].flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: Binding(get: { current }, set: { chosen[key.type.rawValue] = $0 })) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
                switch current {
                case .overview:
                    switch key.type {
                    case NovaType.ship: ShipOverviewView(model: model, env: env, key: key)
                    case NovaType.weapon: WeaponOverviewView(model: model, env: env, key: key)
                    default: OutfitOverviewView(model: model, env: env, key: key)
                    }
                case .layers: ShanEditorView(model: model, env: env, key: key)
                case .hd: HDTabView(model: model, env: env, key: key)
                case .form, .editor: fallback()
                }
            }
            .id(key)
        }
    }
}
#endif
