import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// Edits one `.evpilot` slot from the pilot list. The fields are the ones
/// `PilotEdit` round-trips through `PilotSaves.write` (`PilotArchive.save`).
struct PilotEditorView: View {
    @EnvironmentObject private var model: AppModel
    let slotID: UUID
    var onClose: () -> Void = {}

    @State private var name = ""
    @State private var nickname = ""
    @State private var isMale = true
    @State private var strictPlay = false
    @State private var shipType = 0
    @State private var shipName = ""
    @State private var creditsText = ""
    @State private var ratingText = ""
    @State private var shipIDs: [Int] = []
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        NovaDialog(title: "Edit Pilot", width: 480, buttons: [
            NovaDialogButton(title: "Cancel") { onClose() },
            NovaDialogButton(title: "Save", isDefault: true, enabled: loaded) { commit() },
        ]) {
            VStack(alignment: .leading, spacing: 12) {
                if loaded { fields }
                else if error.isEmpty {
                    NovaText("Reading the pilot…", size: 13, color: .secondary)
                }
                if !error.isEmpty {
                    NovaText(error, size: 11, color: .red, width: 440)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("Full Name:") {
                NovaTextField(placeholder: "Captain", text: $name)
            }
            labeled("Nickname:") {
                NovaTextField(placeholder: "", text: $nickname)
            }
            HStack(spacing: 12) {
                NovaText("Gender:", size: 13, width: 84)
                NovaSegmentedPicker(selection: $isMale, options: [true, false]) {
                    $0 ? "Male" : "Female"
                }
                .frame(width: 200)
            }
            Toggle("Strict Play", isOn: $strictPlay)
                .toggleStyle(NovaToggleStyle())
                .frame(width: 200)
            if shipIDs.isEmpty {
                labeled("Ship:") {
                    NovaText(shipLabel(shipType), size: 13, color: .secondary)
                }
            } else {
                NovaMenuPicker(title: "Ship", selection: $shipType, options: shipIDs, label: shipLabel)
            }
            labeled("Ship Name:") {
                NovaTextField(placeholder: "", text: $shipName)
            }
            labeled("Credits:") {
                NovaTextField(placeholder: "0", text: $creditsText)
            }
            labeled("Rating:") {
                NovaTextField(placeholder: "0", text: $ratingText)
            }
            NovaText(CombatRating.title(forRating: Int(ratingText) ?? 0), size: 11, color: .secondary)
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder field: () -> V) -> some View {
        HStack(spacing: 10) {
            NovaText(title, size: 13, width: 84)
            field()
        }
    }

    private func shipLabel(_ id: Int) -> String {
        model.data.game?.ship(id)?.displayName ?? "Ship \(id)"
    }

    private func load() {
        model.prepareAudioAndData()
        guard let game = model.data.game else {
            error = "Import your EV Nova game data first; a pilot can only be edited against the game's ships."
            return
        }
        guard let save = try? model.roster.archive.load(id: slotID) else {
            error = "Could not open that pilot."
            return
        }
        let edit = PilotEdit(save: save)
        name = edit.name
        nickname = edit.nickname
        isMale = edit.isMale
        strictPlay = edit.strictPlay
        shipType = edit.shipType
        shipName = edit.shipName
        creditsText = String(edit.credits)
        ratingText = String(edit.combatRating)
        var ids = game.ships()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map(\.id)
        if !ids.contains(shipType) { ids.insert(shipType, at: 0) }
        shipIDs = ids
        loaded = true
    }

    private func commit() {
        guard let game = model.data.game else { return }
        let creditsTrimmed = creditsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ratingTrimmed = ratingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credits = Int(creditsTrimmed), credits >= 0 else {
            error = "Credits have to be a whole number, zero or more."
            model.audio.play(.uiError)
            return
        }
        guard let rating = Int(ratingTrimmed), rating >= 0 else {
            error = "Combat rating has to be a whole number, zero or more."
            model.audio.play(.uiError)
            return
        }
        let edit = PilotEdit(name: name, nickname: nickname, isMale: isMale, strictPlay: strictPlay,
                             shipType: shipType, shipName: shipName, credits: credits, combatRating: rating)
        let message = PilotSaves.write(edit, slot: slotID, archive: model.roster.archive, game: game)
        if !message.isEmpty {
            error = message
            model.audio.play(.uiError)
            return
        }
        if model.pilot.started, let live = model.pilot.rosterID,
           let written = try? model.roster.archive.load(id: live) {
            if live == slotID {
                // The same edit on the in-memory pilot, so progress since the last save survives.
                var s = written
                s.player = model.pilot.state
                if PilotSaves.apply(edit, to: &s, game: game).isEmpty { model.pilot.state = s.player }
                model.pilot.state.rosterID = live
            } else {
                model.pilot.state.pilotName = written.player.pilotName
            }
        }
        model.roster.refresh()
        model.audio.play(.uiSelect)
        onClose()
    }
}
