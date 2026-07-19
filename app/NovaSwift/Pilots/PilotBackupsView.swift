import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// Every backup across every save slot of one pilot, newest first — the
/// full-screen "Backups" browser reached from `PilotGroupDetailView`,
/// replacing the old "Load Earlier Save" long-press submenu. Restoring a
/// backup rolls that specific slot back to that point and plays it.
struct PilotBackupsView: View {
    @EnvironmentObject private var model: AppModel
    let group: PilotRoster.PilotGroup
    var onClose: () -> Void = {}
    var onPlay: () -> Void = {}

    private var entries: [PilotRoster.GroupHistoryEntry] { model.roster.groupHistory(for: group.id) }
    /// slot id → "Slot N" (position in `group.slots`, oldest-first).
    private var slotLabels: [UUID: String] {
        Dictionary(uniqueKeysWithValues: group.slots.enumerated().map { ($1.id, "Slot \($0 + 1)") })
    }

    var body: some View {
        NovaDialog(title: "Backups", width: 480, buttons: [
            NovaDialogButton(title: "Close") { onClose() },
        ]) {
            if entries.isEmpty {
                NovaText("No backups yet — they're made automatically on landing, jumping, or manual save.",
                         size: 11, color: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entries) { row($0) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private func row(_ entry: PilotRoster.GroupHistoryEntry) -> some View {
        Button {
            Log.pilot.debug("PilotBackupsView: restoring slot \(entry.slotID, privacy: .public) from \(entry.entry.url.lastPathComponent, privacy: .public)")
            model.audio.play(.uiSelect)
            if let restored = model.roster.restore(entry.slotID, from: entry.entry) {
                onPlay(); model.play(restored)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        NovaText(slotLabels[entry.slotID] ?? "Slot", size: 11, weight: .bold)
                        NovaText(entry.entry.save.snapshot.systemName.isEmpty ? "—" : entry.entry.save.snapshot.systemName,
                                 size: 11, color: .secondary)
                    }
                    NovaText("\(entry.entry.save.snapshot.credits.formatted()) cr · \(PilotListView.relative(entry.entry.save.updatedAt))",
                             size: 10, color: Color(white: 0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(novaAmber)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.24)))
        }
        .buttonStyle(.novaPlain)
    }
}
