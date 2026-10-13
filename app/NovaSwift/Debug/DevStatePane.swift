import SwiftUI

/// The console's **State** tab: the live pilot / ship / world editor
/// (`DebugGameStateView`) embedded as a full-width pane instead of a sheet.
/// Every field there writes the pilot or pushes into the live scene directly,
/// exactly as it did in the sheet — only the chrome changes.
struct DevStatePane: View {
    @EnvironmentObject private var model: AppModel
    let debug: DebugController

    var body: some View {
        DebugGameStateView(debug: debug, embedded: true)
            .environmentObject(model.pilot)
    }
}
