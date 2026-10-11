import SwiftUI

/// Shown when HD/3D art turns up (a plug-in installed from the Plugins screen,
/// or a pack found when the game data loads) while HD graphics are off. HD is
/// opt-in, so we ask rather than switch it on. The same choice lives in
/// Settings → Graphics.
struct HDGraphicsPromptView: View {
    let packNames: [String]
    var onEnable: () -> Void
    var onDecline: () -> Void

    private var found: String {
        switch packNames.count {
        case 0: return "A plug-in you installed includes high-resolution art and 3D models."
        case 1: return "\(packNames[0]) includes high-resolution art and 3D models."
        default: return "\(packNames.count) installed plug-ins include high-resolution art and 3D models."
        }
    }

    var body: some View {
        NovaDialog(title: "Enable HD Graphics?", width: 460, buttons: [
            NovaDialogButton(title: "Not Now") { onDecline() },
            NovaDialogButton(title: "Enable", isDefault: true) { onEnable() },
        ]) {
            VStack(alignment: .leading, spacing: 10) {
                Text(found + " Use them in place of the original graphics?")
                    .novaFont(.body).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only the look changes: ships handle and fight exactly as in the original. You can change this any time in Settings → Graphics.")
                    .novaFont(.caption).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
