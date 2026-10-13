import XCTest
@testable import NovaSwiftStory

final class TutorialCurriculumTests: XCTestCase {
    private func labels(_ a: TutorialAction) -> String { "<\(a.rawValue)>" }

    func testFullCourseOrderAndGoals() {
        let steps = TutorialCurriculum.build(style: .keyboard, label: labels, hasAfterburner: true, hasSecondary: true)
        XCTAssertEqual(steps.map(\.id), ["welcome", "fly", "turn", "afterburner", "target", "fire", "weapon", "land", "done"])
        XCTAssertEqual(steps.compactMap(\.goal), [.fly, .turn, .afterburner, .target, .fire, .changeWeapon, .land])
        XCTAssertTrue(steps.first!.isManual)
        XCTAssertTrue(steps.last!.isManual)
    }

    func testStepsTheShipCannotDoAreDropped() {
        let steps = TutorialCurriculum.build(style: .keyboard, label: labels, hasAfterburner: false, hasSecondary: false)
        XCTAssertEqual(steps.map(\.id), ["welcome", "fly", "turn", "target", "fire", "land", "done"])
    }

    func testTextNamesTheControlsOfTheActiveStyle() {
        let kb = TutorialCurriculum.build(style: .keyboard, label: labels, hasAfterburner: true, hasSecondary: true)
        XCTAssertTrue(kb[1].body.contains("<accelerate>") && kb[1].body.contains("<turnLeft>"))
        XCTAssertTrue(kb.first { $0.id == "land" }!.body.contains("<land>"))
        let pad = TutorialCurriculum.build(style: .pad, label: labels, hasAfterburner: true, hasSecondary: true)
        XCTAssertTrue(pad[1].body.contains("left stick"))
        XCTAssertTrue(pad.first { $0.id == "target" }!.body.contains("<targetNext>"))
        XCTAssertTrue(pad.first { $0.id == "weapon" }!.body.contains("<selectSecondaryPrev>"))
        let touch = TutorialCurriculum.build(style: .touch(.tilt), label: labels, hasAfterburner: true, hasSecondary: true)
        XCTAssertTrue(touch[1].body.contains("Tilt"))
        XCTAssertFalse(touch.contains { $0.body.contains("<") }, "touch wording names no key")
    }

    func testProgressionOnlyAdvancesOnTheCurrentGoal() {
        var run = TutorialProgression()
        run.configure(TutorialCurriculum.build(style: .keyboard, label: labels, hasAfterburner: false, hasSecondary: false))
        XCTAssertEqual(run.current?.id, "welcome")
        run.complete(.fly)                       // the welcome card is manual: a stray goal does nothing
        XCTAssertEqual(run.index, 0)
        run.advance()                            // Continue
        XCTAssertEqual(run.current?.goal, .fly)
        run.complete(.fire)                      // not the current goal
        XCTAssertEqual(run.current?.goal, .fly)
        run.complete(.fly)
        XCTAssertEqual(run.current?.goal, .turn)
        for _ in 0..<20 { run.advance() }
        XCTAssertTrue(run.finished)
        XCTAssertTrue(run.isLast)
        let n = run.index
        run.advance()
        XCTAssertEqual(run.index, n, "finished stays finished")
    }
}

final class GameHintCatalogTests: XCTestCase {
    func testIdsAreUniqueAndStable() {
        XCTAssertEqual(NovaHints.all.map(\.id), ["spaceport.services", "missionBBS.howto", "outfitter.howto"])
        XCTAssertEqual(NovaHints.storageKey("outfitter.howto"), "novaswift.hint.outfitter.howto")
    }

    func testShouldShowIsOnceAndContextGated() {
        XCTAssertTrue(NovaHints.shouldShow(active: true, dismissed: false, seen: false))
        XCTAssertFalse(NovaHints.shouldShow(active: false, dismissed: false, seen: false), "tutorial hints off / wrong context")
        XCTAssertFalse(NovaHints.shouldShow(active: true, dismissed: true, seen: false))
        XCTAssertFalse(NovaHints.shouldShow(active: true, dismissed: false, seen: true), "never again once seen")
    }

    func testSpaceportScreenMapping() {
        XCTAssertEqual(NovaHints.hint(forSpaceportScreen: "hub"), NovaHints.spaceportServices)
        XCTAssertEqual(NovaHints.hint(forSpaceportScreen: "bbs"), NovaHints.missionBBS)
        XCTAssertEqual(NovaHints.hint(forSpaceportScreen: "outfitter"), NovaHints.outfitter)
        XCTAssertNil(NovaHints.hint(forSpaceportScreen: "trade"))
    }
}

final class PilotGroupsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for r in roots { try? FileManager.default.removeItem(at: r) } }

    private func tempArchive() -> PilotArchive {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-groups-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return PilotArchive(location: .local(root))
    }

    func testSlotsGroupAndBackupsRestore() throws {
        let a = tempArchive()
        var base = PilotSave(displayName: "Ada", scenarioName: "", player: PlayerState(pilotName: "Ada", credits: 100), snapshot: .init())
        base.createdAt = Date(timeIntervalSinceNow: -100)   // saves round dates to the second
        base = try a.save(base, backup: false)
        var edited = base
        edited.player.credits = 500
        edited = try a.save(edited, backup: true)         // rotates the 100-credit file into Backups
        let slot2 = try a.createSlot(from: base.id)
        _ = try a.save(PilotSave(displayName: "Bo", scenarioName: "", player: PlayerState(), snapshot: .init()), backup: false)

        let groups = PilotGroups.groups(a.list())
        XCTAssertEqual(groups.count, 2)
        let ada = try XCTUnwrap(groups.first { $0.mostRecent.displayName == "Ada" })
        XCTAssertEqual(ada.slots.count, 2)
        XCTAssertEqual(ada.slots.first?.id, base.id, "Slot 1 is the original")
        XCTAssertTrue(ada.canAddSlot)

        let history = PilotGroups.history(of: ada, in: a)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].slotID, base.id)
        XCTAssertEqual(history[0].save.player.credits, 100)
        let restored = try a.restore(id: base.id, from: history[0].url)
        XCTAssertEqual(restored.player.credits, 100)
        XCTAssertEqual(try a.load(id: base.id).player.credits, 100)
        _ = slot2
    }

    func testStrictPlayDeathRemovesEverySlotAndBackup() throws {
        let a = tempArchive()
        var s = PilotSave(displayName: "Doomed", scenarioName: "", player: PlayerState(), snapshot: .init())
        s = try a.save(s, backup: false)
        s = try a.save(s, backup: true)
        let slot = try a.createSlot(from: s.id)
        let other = try a.save(PilotSave(displayName: "Other", scenarioName: "", player: PlayerState(), snapshot: .init()), backup: false)
        let gone = PilotGroups.deleteGroupAfterStrictPlayDeath(id: s.id, in: a)
        XCTAssertEqual(Set(gone), Set([s.id, slot.id]))
        XCTAssertFalse(a.exists(id: s.id))
        XCTAssertFalse(a.exists(id: slot.id))
        XCTAssertTrue(a.backups(for: s.id).isEmpty)
        XCTAssertTrue(a.exists(id: other.id))
    }
}
