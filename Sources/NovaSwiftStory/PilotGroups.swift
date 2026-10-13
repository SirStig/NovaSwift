import Foundation

/// Pilot identities over the flat list of saves: every save sharing a
/// `pilotGroupID` is one pilot's save slots (up to `maxSlotsPerPilot`), oldest
/// first so "Slot 1" is always the original. The Godot frontend's pilot slots and
/// backups screens use this; it mirrors the Apple roster's `PilotRoster.groups`
/// (`app/NovaSwift/Pilots/PilotRoster.swift`).
public enum PilotGroups {
    /// Our native save format supports up to 3 independent slots per pilot.
    public static let maxSlotsPerPilot = 3

    public struct Group: Identifiable, Sendable {
        public let id: UUID          // == pilotGroupID
        public let slots: [PilotSave]
        public var mostRecent: PilotSave { slots.max { $0.updatedAt < $1.updatedAt } ?? slots[0] }
        public var canAddSlot: Bool { slots.count < PilotGroups.maxSlotsPerPilot }
    }

    /// Every pilot grouped by `pilotGroupID`, sorted by each group's most recently played slot.
    public static func groups(_ saves: [PilotSave]) -> [Group] {
        Dictionary(grouping: saves, by: \.pilotGroupID)
            .map { Group(id: $0.key, slots: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.mostRecent.updatedAt > $1.mostRecent.updatedAt }
    }

    /// Every backup across every slot of `group`, newest first, tagged with its slot.
    public static func history(of group: Group, in archive: PilotArchive)
        -> [(slotID: UUID, slotIndex: Int, url: URL, save: PilotSave)] {
        group.slots.enumerated()
            .flatMap { i, slot in archive.loadBackups(for: slot.id).map { (slot.id, i, $0.url, $0.save) } }
            .sorted { $0.save.updatedAt > $1.save.updatedAt }
    }

    /// Strict Play death without a pod (FL-03): the pilot is gone for good — every
    /// save slot of its group, with every backup (`PilotRoster.deleteAfterStrictPlayDeath`).
    /// Returns the slot ids removed.
    @discardableResult
    public static func deleteGroupAfterStrictPlayDeath(id: UUID, in archive: PilotArchive) -> [UUID] {
        let group = archive.list().first { $0.id == id }?.pilotGroupID
        let ids = group.map { g in archive.list().filter { $0.pilotGroupID == g }.map(\.id) } ?? [id]
        for slot in ids { PilotArchive.deleteEverywhere(id: slot, archives: [archive]) }
        return ids
    }
}
