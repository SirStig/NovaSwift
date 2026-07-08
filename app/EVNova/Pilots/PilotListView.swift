import SwiftUI
import EVNovaKit
import EVNovaStory

/// The saved-pilot roster, presented as an authentic EV Nova dialog (the real
/// game used the OS file dialog to open a `.plt`, so a multi-save browser is a
/// port addition — drawn in the game's idiom via `NovaDialog`). Continue resumes
/// a pilot; the row menu duplicates or deletes.
struct PilotListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPilot = false
    @State private var pendingDelete: PilotSave?

    var body: some View {
        NovaDialog(title: "Select a Pilot", width: 480, buttons: buttons) {
            if model.roster.isEmpty { emptyState }
            else { pilotList }
        }
        .sheet(isPresented: $showNewPilot) { NewPilotView().preferredColorScheme(.dark) }
        .alert("Delete pilot?", isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = pendingDelete { model.roster.delete(d.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(pendingDelete?.displayName ?? "")” and its backups will be removed. This can't be undone.")
        }
        .onAppear { model.roster.refresh() }
    }

    private var buttons: [NovaDialogButton] {
        [
            NovaDialogButton(title: "New Pilot", isDefault: model.roster.isEmpty) {
                showNewPilot = true
            },
            NovaDialogButton(title: "Close") { dismiss() },
        ]
    }

    private var pilotList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.roster.pilots) { pilotRow($0) }
            }
            .padding(.vertical, 2)
        }
        .frame(height: min(CGFloat(model.roster.pilots.count) * 68 + 8, 320))
    }

    private func pilotRow(_ save: PilotSave) -> some View {
        Button {
            model.audio.play(.uiSelect); dismiss(); model.play(save)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    NovaText(save.displayName, size: 14, weight: .bold)
                    NovaText("\(save.snapshot.shipName) · \(save.snapshot.systemName.isEmpty ? "—" : save.snapshot.systemName)",
                             size: 11, color: .secondary)
                    NovaText("\(save.snapshot.credits.formatted()) cr · \(save.snapshot.ratingTitle) · \(relative(save.updatedAt))",
                             size: 10, color: Color(white: 0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(novaAmber)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.26)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.roster.duplicate(save.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { pendingDelete = save } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            NovaText("No pilots yet.", size: 14)
            NovaText("Create a pilot to begin your story.", size: 11, color: .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
