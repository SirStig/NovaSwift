import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The "Pilot converter" confirmation: shows what an original EV Nova pilot
/// (Windows `.plt` or a classic Mac pilot) contains and what could not be
/// carried over, before it becomes a NovaSwift pilot. The source file is only
/// ever read.
struct PilotImportView: View {
    @EnvironmentObject private var model: AppModel
    let result: EVNovaPilotImportResult
    var onClose: () -> Void

    var body: some View {
        let s = result.summary
        NovaDialog(title: "Import EV Nova Pilot", width: 480, buttons: [
            NovaDialogButton(title: "Cancel") { onClose() },
            NovaDialogButton(title: "Create Pilot", isDefault: true) { create() },
        ]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    NovaText(s.pilotName + (s.nickname.isEmpty ? "" : " “\(s.nickname)”"), size: 16, weight: .bold)
                    NovaText(s.format.rawValue, size: 10, color: Color(white: 0.5))
                    row("Ship", s.shipName.isEmpty || s.shipName == s.hullName ? s.hullName : "\(s.shipName) (\(s.hullName))")
                    row("Credits", "\(s.credits.formatted()) cr")
                    row("Date", result.player.date.description)
                    if !s.location.isEmpty { row("Location", s.location) }
                    row("Combat rating", "\(s.ratingTitle) (\(s.combatRating.formatted()))")
                    row("Story progress", "\(s.controlBits.formatted()) control bits set, \(s.activeMissions) active mission(s)")
                    row("Escorts", "\(s.escorts)")
                    if !s.warnings.isEmpty {
                        NovaText("Warnings", size: 12, color: novaAmber, weight: .bold).padding(.top, 6)
                        ForEach(Array(s.warnings.enumerated()), id: \.offset) { _, w in
                            NovaText("• " + w, size: 11, color: .secondary, width: 430)
                        }
                    }
                    if !s.unmapped.isEmpty {
                        NovaText("Not carried over", size: 12, color: Color(white: 0.7), weight: .bold).padding(.top, 6)
                        ForEach(Array(s.unmapped.enumerated()), id: \.offset) { _, w in
                            NovaText("• " + w, size: 11, color: Color(white: 0.5), width: 430)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            NovaText(label + ":", size: 12, color: Color(white: 0.6), width: 110)
            NovaText(value, size: 12, width: 320)
        }
    }

    private func create() {
        guard let game = model.data.game,
              let save = model.roster.importConverted(result, game: game) else {
            model.audio.play(.uiError)
            return
        }
        model.roster.setSelected(save.id)
        onClose()
    }
}

/// Reads a picked file and converts it. Lives apart from the view so the file
/// picker callback stays small; `error` is user-facing text.
enum PilotImportLoader {
    static func load(_ url: URL, game: NovaGame) -> Result<EVNovaPilotImportResult, Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Result { try EVNovaPilotImporter.importPilot(from: url, game: game) }
    }
}
