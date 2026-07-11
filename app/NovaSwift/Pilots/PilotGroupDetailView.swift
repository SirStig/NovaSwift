import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// A single pilot's detail screen: which save slot to play (our own native
/// format supports up to `PilotRoster.maxSlotsPerPilot` independent slots per
/// pilot, unlike a single obfuscated `.plt`), plus access to every slot's
/// full backup history. Reached by tapping a row in `PilotListView` — replaces
/// what used to be an immediate "load the most recent save" tap.
struct PilotGroupDetailView: View {
    @EnvironmentObject private var model: AppModel
    let group: PilotRoster.PilotGroup
    /// Dismisses just this screen, back to the pilot list.
    var onClose: () -> Void = {}
    /// Collapses the *entire* pilot-selection flow — called once a slot is
    /// actually chosen to play (mirrors `PilotListView`'s own `onClose`).
    var onPlay: () -> Void = {}

    @State private var showBackups = false
    @State private var renamingText: String?
    @State private var pendingDeleteSlot: PilotSave?

    private var pilotName: String { group.mostRecent.displayName }
    private var scenarioName: String { group.mostRecent.scenarioName }
    /// Oldest-first, matching `group.slots` — "Slot 1" is always the original.
    private var slots: [PilotSave] { group.slots }

    var body: some View {
        ZStack {
            NovaDialog(title: pilotName, width: 480, buttons: [
                NovaDialogButton(title: "Back") { onClose() },
                NovaDialogButton(title: "Continue", isDefault: true) { play(group.mostRecent) },
            ]) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    savesSection
                    if group.canAddSlot { newSlotButton }
                    backupsButton
                }
            }
            if showBackups {
                PilotBackupsView(group: group, onClose: { showBackups = false }, onPlay: onPlay)
                    .transition(.opacity)
            }
        }
        .alert("Rename Pilot", isPresented: Binding(get: { renamingText != nil },
                                                    set: { if !$0 { renamingText = nil } })) {
            TextField("Pilot name", text: Binding(get: { renamingText ?? "" }, set: { renamingText = $0 }))
            Button("Save") {
                if let text = renamingText, !text.isEmpty {
                    model.roster.renameGroup(group.id, to: text, game: model.data.game)
                }
                renamingText = nil
            }
            Button("Cancel", role: .cancel) { renamingText = nil }
        }
        .alert("Delete this save slot?", isPresented: Binding(get: { pendingDeleteSlot != nil },
                                                              set: { if !$0 { pendingDeleteSlot = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = pendingDeleteSlot { model.roster.delete(s.id) }
                pendingDeleteSlot = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSlot = nil }
        } message: {
            Text("This slot and its backups will be removed. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                NovaText(scenarioName.isEmpty ? "Pilot" : scenarioName, size: 11, color: .secondary)
            }
            Spacer()
            Button { renamingText = pilotName } label: {
                Label("Rename", systemImage: "pencil").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(novaAmber)
        }
    }

    private var savesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            NovaText("SAVES", size: 10, color: Color(white: 0.5))
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, save in
                slotRow(index: i, save: save)
            }
        }
    }

    private func slotRow(index: Int, save: PilotSave) -> some View {
        Button { play(save) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    NovaText("Slot \(index + 1)", size: 12, weight: .bold)
                    NovaText("\(save.snapshot.shipName) · \(save.snapshot.systemName.isEmpty ? "—" : save.snapshot.systemName)",
                             size: 11, color: .secondary)
                    NovaText("\(save.snapshot.credits.formatted()) cr · \(save.snapshot.ratingTitle) · \(PilotListView.relative(save.updatedAt))",
                             size: 10, color: Color(white: 0.5))
                }
                Spacer(minLength: 0)
                if slots.count > 1 {
                    Button { pendingDeleteSlot = save } label: {
                        Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: "play.circle.fill").foregroundStyle(novaAmber)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.24)))
        }
        .buttonStyle(.plain)
    }

    private var newSlotButton: some View {
        Button {
            model.audio.play(.uiSelect)
            _ = model.roster.addSlot(to: group.id, from: group.mostRecent.id)
        } label: {
            Label("New Save Slot (\(slots.count)/\(PilotRoster.maxSlotsPerPilot))", systemImage: "plus.square.on.square")
                .font(.caption).foregroundStyle(novaAmber)
        }
        .buttonStyle(.plain)
    }

    private var backupsButton: some View {
        Button {
            model.audio.play(.uiSelect); showBackups = true
        } label: {
            Label("View All Backups", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func play(_ save: PilotSave) {
        Log.pilot.debug("PilotGroupDetailView: play slot \(save.id, privacy: .public) of group \(group.id, privacy: .public)")
        model.audio.play(.uiSelect); onPlay(); model.play(save)
    }
}
