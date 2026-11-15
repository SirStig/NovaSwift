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

    // MARK: Migration (local ⇄ iCloud storage switch)

    private func archive(at root: URL, clock: (() -> Date)? = nil) -> PilotArchive {
        PilotArchive(location: .local(root), maxBackupsPerPilot: 8, now: clock ?? { Date() })
    }

    func testImportPilotsCopiesSavesAndBackups() throws {
        var t = Date(timeIntervalSince1970: 4_000_000)
        let source = archive(at: tempRoot.appendingPathComponent("src"),
                             clock: { t = t.addingTimeInterval(1); return t })
        var save = try source.save(makeSave(name: "Traveller"), backup: false)
        save.player.credits = 5000
        save = try source.save(save)   // produces one backup
        XCTAssertFalse(source.backups(for: save.id).isEmpty)

        let dest = archive(at: tempRoot.appendingPathComponent("dst"))
        let copied = dest.importPilots(from: source)
        XCTAssertEqual(copied, 1)
        // The pilot and its identity survive the move.
        let migrated = try dest.load(id: save.id)
        XCTAssertEqual(migrated.displayName, "Traveller")
        XCTAssertEqual(migrated.player.credits, 5000)
        // Its backup history came along too.
        XCTAssertFalse(dest.backups(for: save.id).isEmpty, "backups migrate with the pilot")
    }

    func testImportPilotsDoesNotOverwriteExistingByDefault() throws {
        let source = archive(at: tempRoot.appendingPathComponent("src"))
        let dest = archive(at: tempRoot.appendingPathComponent("dst"))
        // Same id in both stores, different credits.
        var save = makeSave(name: "Split")
        try source.save(save, backup: false)
        save.player.credits = 111
        try dest.save(save, backup: false)

        let copied = dest.importPilots(from: source, overwrite: false)
        XCTAssertEqual(copied, 0, "an id already present in the destination is left untouched")
        XCTAssertEqual(try dest.load(id: save.id).player.credits, 111, "destination stays authoritative")

        // With overwrite, the source wins.
        let copied2 = dest.importPilots(from: source, overwrite: true)
        XCTAssertEqual(copied2, 1)
        XCTAssertEqual(try dest.load(id: save.id).player.credits, 25000)
    }

    func testImportPilotsMergesDistinctPilots() throws {
        let source = archive(at: tempRoot.appendingPathComponent("src"))
        let dest = archive(at: tempRoot.appendingPathComponent("dst"))
        try source.save(makeSave(name: "FromCloud"), backup: false)
        try dest.save(makeSave(name: "FromLocal"), backup: false)
        dest.importPilots(from: source)
        XCTAssertEqual(Set(dest.list().map(\.displayName)), ["FromCloud", "FromLocal"],
                       "switching stores unions both sides' pilots")
    }

    func testEditorFieldsSurviveSaveAndLoad() throws {
        let game = makeGame([
            shipResource(id: 128, cargo: 10),
            shipResource(id: 129, cargo: 20),
            ownedSystemResource(id: 128, govt: -1),
        ])
        let store = archive()
        var save = makeSave(name: "Ripley")
        save.player.nickname = "Rip"
        save.player.setBits = [7]
        save.player.cargo = [1: 4]
        save.player.hullFittingsGranted = true
        save.player.systemReputation = [:]
        save.player.dominatedStellars = [42]
        save.player.credits = 25000
        try store.save(save, backup: false)
        var sibling = try store.createSlot(from: save.id)
        sibling.player.credits = 10
        try store.save(sibling, backup: false)

        var edit = PilotEdit(save: save)
        edit.name = "Dallas"
        edit.nickname = "Dal"
        edit.isMale = false
        edit.strictPlay = true
        edit.shipType = 129
        edit.shipName = "Nostromo"
        edit.credits = -50
        edit.combatRating = 400
        XCTAssertEqual(PilotSaves.write(edit, slot: save.id, archive: store, game: game), "")

        let loaded = try store.load(id: save.id)
        let prepared = PilotSaves.prepareForPlay(loaded, game: game).state
        XCTAssertEqual(loaded.displayName, "Dallas")
        XCTAssertEqual(prepared.pilotName, "Dallas")
        XCTAssertEqual(prepared.nickname, "Dal")
        XCTAssertFalse(prepared.isMale)
        XCTAssertTrue(prepared.isStrictPlay)
        XCTAssertEqual(prepared.shipType, 129)
        XCTAssertEqual(prepared.shipName, "Nostromo")
        XCTAssertEqual(prepared.credits, 0, "credits clamp at 0")
        XCTAssertEqual(prepared.combatRating, 400)
        XCTAssertEqual(loaded.snapshot.credits, 0)
        XCTAssertEqual(loaded.snapshot.shipName, "Nostromo")
        XCTAssertEqual(loaded.snapshot.ratingTitle, CombatRating.title(forRating: 400))
        XCTAssertEqual(prepared.setBits, [7])
        XCTAssertEqual(prepared.cargo[1], 4)
        XCTAssertEqual(prepared.dominatedStellars, [42])

        let other = try store.load(id: sibling.id)
        XCTAssertEqual(other.displayName, "Dallas")
        XCTAssertEqual(other.player.pilotName, "Dallas")
        XCTAssertEqual(other.player.credits, 10, "another slot keeps its own credits")
        XCTAssertEqual(other.player.shipType, 128)

        edit.name = ""
        XCTAssertFalse(PilotSaves.write(edit, slot: save.id, archive: store, game: game).isEmpty)
        edit.name = "Dallas"
        edit.shipType = 999
        XCTAssertFalse(PilotSaves.write(edit, slot: save.id, archive: store, game: game).isEmpty)
        XCTAssertEqual(try store.load(id: save.id).player.shipType, 129)
    }

    /// Changing the hull in the editor is the same handover as buying one
    /// (`PilotEconomy.buyShip`), minus price and scripts: only oütf Flags
    /// 0x0004 items stay, the old hull's absolute armor/shield/fuel go, and
    /// the hold is shrunk to the new hull.
    func testEditorHullChangeHandsOverLikeBuyingAShip() throws {
        var license = [UInt8](outfitResource(id: 129, name: "License").data)
        Bytes.i16(&license, 12, 0x0004)
        let game = makeGame([
            shipResource(id: 128, cargo: 30),
            shipResource(id: 129, cargo: 5),
            ownedSystemResource(id: 128, govt: -1),
            outfitResource(id: 128, name: "Gun"),
            Resource(type: NovaType.outfit, id: 129, name: "License", data: Data(license)),
        ])
        let store = archive()
        var save = makeSave(name: "Ripley")
        save.player.outfits = [128: 2, 129: 1]
        save.player.armor = 40
        save.player.shield = 30
        save.player.fuel = 100
        save.player.cargo = [1: 20]
        try store.save(save, backup: false)

        var edit = PilotEdit(save: save)
        edit.shipType = 129
        XCTAssertEqual(PilotSaves.write(edit, slot: save.id, archive: store, game: game), "")
        let p = try store.load(id: save.id).player
        XCTAssertEqual(p.shipType, 129)
        XCTAssertNil(p.outfits[128], "an ordinary outfit goes with the old hull")
        XCTAssertEqual(p.outfits[129], 1, "a Flags 0x0004 item stays with the pilot")
        XCTAssertNil(p.armor)
        XCTAssertNil(p.shield)
        XCTAssertNil(p.fuel)
        XCTAssertLessThanOrEqual(p.cargo.values.reduce(0, +), 5, "the hold fits the new hull")
    }
}
