#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Story & Bits tool: control-bit index and mission list (left), mission flow
/// graph (centre), bit detail / mission & cron cards (right).
///
/// Analysis (`ControlBitIndex` + `StoryGraph` layout) runs off the main actor,
/// once per document revision, debounced; see `StoryAnalysisModel`.
struct StoryEditorView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var analysis = StoryAnalysisModel()
    @StateObject private var ui = StoryUIState()

    var body: some View {
        HSplitView {
            StoryLeftPane(model: model, analysis: analysis, ui: ui)
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 400)
            StoryGraphView(model: model, analysis: analysis, ui: ui)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            StoryRightPane(model: model, analysis: analysis, ui: ui)
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 620)
        }
        .onAppear { analysis.refresh(model, immediate: true) }
        .onChange(of: model.revision) { _, _ in analysis.refresh(model) }
        .onChange(of: model.selection) { _, sel in
            // Selecting a mission/cron elsewhere carries over.
            if let sel, sel.type == NovaType.mission || sel.type == FourCharCode("crön")!, analysis.graph.indexByKey[sel] != nil {
                ui.inspect = .node(sel)
            }
        }
    }
}
#endif
