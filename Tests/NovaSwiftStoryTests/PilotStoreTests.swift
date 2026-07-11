import XCTest
import Foundation
import NovaSwiftKit
@testable import NovaSwiftStory

final class PilotStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-pilottests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func archive(maxBackups: Int = 8, clock: (() -> Date)? = nil) -> PilotArchive {
        PilotArchive(location: .local(tempRoot), maxBackupsPerPilot: maxBackups,
                     now: clock ?? { Date() })
    }

    private func makeSave(name: String) -> PilotSave {
        let player = PlayerState(pilotName: name, shipType: 128, shipName: "Shuttle",
                                 credits: 25000, currentSystem: 128)
        return PilotSave(displayName: name, scenarioName: "Trader", player: player,
                         snapshot: .init(shipName: "Shuttle", systemName: "Kania",
                                         credits: 25000, ratingTitle: "Harmless"))
    }

    func testSaveLoadRoundTrip() throws {
        let store = archive()
        let save = makeSave(name: "Ripley")
        try store.save(save)
        let loaded = try store.load(id: save.id)
        XCTAssertEqual(loaded.id, save.id)
        XCTAssertEqual(loaded.displayName, "Ripley")
        XCTAssertEqual(loaded.player.credits, 25000)
        XCTAssertEqual(loaded.player.pilotName, "Ripley")
    }

    func testUnlimitedPilotsListedNewestFirst() throws {
        var t = Date(timeIntervalSince1970: 1_000_000)
        let store = archive(clock: { t })
        // Save three pilots at increasing times.
        for name in ["A", "B", "C"] {
            t = t.addingTimeInterval(10)
            try store.save(makeSave(name: name))
        }
        let list = store.list()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.map(\.displayName), ["C", "B", "A"])  // newest first
    }

    func testBackupRotationKeepsFirstAndNewest() throws {
        var t = Date(timeIntervalSince1970: 2_000_000)
        let store = archive(maxBackups: 3, clock: { t = t.addingTimeInterval(1); return t })
        var save = makeSave(name: "Vet")
        try store.save(save, backup: false)   // initial write, no backup yet
        // Ten overwrites → ten backups requested, pruned to first + newest (maxBackups-1).
        for i in 1...10 {
            save.player.credits = i * 1000
            save = try store.save(save)
        }
        let backups = store.backups(for: save.id)
        XCTAssertEqual(backups.count, 3, "keep newest 3 (incl. the always-kept first)")
        // The oldest surviving backup is the very first one taken.
        XCTAssertLessThan(store.backupTimestamp(backups.first!),
                          store.backupTimestamp(backups.last!))
    }

    func testDuplicateCreatesIndependentCopy() throws {
        let store = archive()
        let original = try store.save(makeSave(name: "Orig"))
        let copy = try store.duplicate(id: original.id, newName: "Clone")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.displayName, "Clone")
        XCTAssertEqual(store.list().count, 2)
        // Editing the copy doesn't touch the original.
        var edited = copy
        edited.player.credits = 999
        try store.save(edited)
        XCTAssertEqual(try store.load(id: original.id).player.credits, 25000)
    }

    func testDeleteRemovesFileAndBackups() throws {
        var t = Date(timeIntervalSince1970: 3_000_000)
        let store = archive(clock: { t = t.addingTimeInterval(1); return t })
        var save = try store.save(makeSave(name: "Doomed"), backup: false)
        save.player.credits = 1
        save = try store.save(save)   // creates a backup
        XCTAssertFalse(store.backups(for: save.id).isEmpty)
        try store.delete(id: save.id)
        XCTAssertFalse(store.exists(id: save.id))
        XCTAssertTrue(store.backups(for: save.id).isEmpty)
    }

    func testResilientDecodeOfMinimalSave() throws {
        // A save file missing every optional key but the player payload still loads.
        let player = PlayerState(pilotName: "Legacy", shipType: 128)
        let json = try JSONEncoder().encode(["player": player])
        let store = archive()
        let id = UUID()
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try json.write(to: store.fileURL(for: id))
        // list() should decode it (id regenerated, defaults filled).
        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.player.pilotName, "Legacy")
        // No pilotGroupID key in the minimal JSON either — an old save on disk
        // from before slots existed should decode as its own group of one.
        XCTAssertEqual(list.first?.pilotGroupID, list.first?.id)
    }

    // MARK: Save slots (pilotGroupID)

    func testFreshSaveDefaultsPilotGroupIDToItsOwnID() throws {
        let save = makeSave(name: "Solo")
        XCTAssertEqual(save.pilotGroupID, save.id)
    }

    func testDuplicateAssignsAFreshGroupIDNotTheSourcesGroup() throws {
        let store = archive()
        let original = try store.save(makeSave(name: "Orig"))
        let copy = try store.duplicate(id: original.id, newName: "Clone")
        XCTAssertNotEqual(copy.pilotGroupID, original.pilotGroupID,
                          "a duplicate forks an independent pilot, not another slot of the same one")
        XCTAssertEqual(copy.pilotGroupID, copy.id, "the fork is its own singleton group")
    }

    func testCreateSlotPreservesDisplayNameAndGroupIDButNotID() throws {
        let store = archive()
        let original = try store.save(makeSave(name: "Vet"))
        let slot = try store.createSlot(from: original.id)
        XCTAssertNotEqual(slot.id, original.id, "a new independent save file")
        XCTAssertEqual(slot.pilotGroupID, original.pilotGroupID, "same pilot identity")
        XCTAssertEqual(slot.displayName, original.displayName, "slots share the pilot's name, unlike Duplicate")
        XCTAssertEqual(store.list().count, 2, "the original and the new slot are both independently listed")
    }
}
