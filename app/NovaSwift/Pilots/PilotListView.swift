import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The saved-pilot roster, presented as an authentic EV Nova dialog (the real
/// game used the OS file dialog to open a `.plt`, so a multi-save browser is a
/// port addition — drawn in the game's idiom via `NovaDialog`). Each row is a
/// **pilot identity** (`PilotRoster.PilotGroup`), which may have up to 3
/// independent save slots — tapping a row opens `PilotGroupDetailView` to
/// choose a slot (or Continue) rather than jumping straight into the game.
struct PilotListView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this dialog (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}
    @State private var showNewPilot = false
    @State private var openGroupID: UUID?
    @State private var pendingDeleteGroup: PilotRoster.PilotGroup?

    var body: some View {
        ZStack {
            NovaDialog(title: "Select a Pilot", width: 480, buttons: buttons) {
                if model.roster.isEmpty { emptyState }
                else { pilotList }
            }
            if showNewPilot {
                NewPilotView(onClose: { showNewPilot = false })
                    .transition(.opacity)
            }
            if let openGroupID, let group = model.roster.groups.first(where: { $0.id == openGroupID }) {
                PilotGroupDetailView(group: group, onClose: { self.openGroupID = nil }, onPlay: onClose)
                    .transition(.opacity)
            }
        }
        .alert("Delete pilot?", isPresented: Binding(get: { pendingDeleteGroup != nil },
                                                     set: { if !$0 { pendingDeleteGroup = nil } })) {
            Button("Delete", role: .destructive) {
                if let g = pendingDeleteGroup {
                    Log.pilot.notice("PilotListView: deleting pilot group \(g.id, privacy: .public) \"\(g.mostRecent.displayName, privacy: .public)\"")
                    model.roster.deleteGroup(g.id)
                }
                pendingDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteGroup = nil }
        } message: {
            let g = pendingDeleteGroup
            let slotWord = (g?.slots.count ?? 1) > 1 ? "\(g?.slots.count ?? 1) save slots" : "save"
            Text("“\(g?.mostRecent.displayName ?? "")” — its \(slotWord) and all backups will be removed. This can't be undone.")
        }
        .onAppear {
            model.roster.refresh()
            Log.pilot.debug("PilotListView: appeared with \(model.roster.groups.count) pilot(s)")
        }
    }

    private var buttons: [NovaDialogButton] {
        [
            NovaDialogButton(title: "New Pilot", isDefault: model.roster.isEmpty) {
                Log.pilot.debug("PilotListView: opening New Pilot sheet")
                showNewPilot = true
            },
            NovaDialogButton(title: "Close") { onClose() },
        ]
    }

    private var pilotList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.roster.groups) { pilotRow($0) }
            }
            .padding(.vertical, 2)
        }
        .frame(height: min(CGFloat(model.roster.groups.count) * 68 + 8, 320))
    }

    private func pilotRow(_ group: PilotRoster.PilotGroup) -> some View {
        let save = group.mostRecent
        return CursorButton {
            Log.pilot.debug("PilotListView: open pilot group \(group.id, privacy: .public) \"\(save.displayName, privacy: .public)\"")
            model.audio.play(.uiSelect); openGroupID = group.id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        NovaText(save.displayName, size: 14, weight: .bold)
                        if group.slots.count > 1 {
                            NovaText("\(group.slots.count) slots", size: 9, color: Color(white: 0.5))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(white: 0.16), in: Capsule())
                        }
                    }
                    NovaText("\(save.snapshot.shipName) · \(save.snapshot.systemName.isEmpty ? "—" : save.snapshot.systemName)",
                             size: 11, color: .secondary)
                    NovaText("\(save.snapshot.credits.formatted()) cr · \(save.snapshot.ratingTitle) · \(relative(save.updatedAt))",
                             size: 10, color: Color(white: 0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.title3).foregroundStyle(novaAmber)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.26)))
        }
        .buttonStyle(.novaPlain)
        .contextMenu {
            Button {
                Log.pilot.debug("PilotListView: duplicate pilot \(save.id, privacy: .public)")
                model.roster.duplicate(save.id)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { pendingDeleteGroup = group } label: { Label("Delete", systemImage: "trash") }
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

    /// Shared by the pilot list and the group/backups detail screens.
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    private func relative(_ date: Date) -> String { Self.relative(date) }
}
