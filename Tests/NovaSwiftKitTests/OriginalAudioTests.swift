import XCTest
@testable import NovaSwiftKit

/// Pins the original's sound rules (render_ui_sound sweep, section D).
final class OriginalAudioTests: XCTestCase {

    // MARK: D-2 positional volume (0x004692e0 + nv_PlaySound)

    func testFullVolumeWithin200Pixels() {
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 0, master: 128), 128)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 120, dy: 160, master: 128), 128, "d = 200 exactly")
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: -199, dy: 0, master: 128), 128)
    }

    func testFarSoundsNeverDropBelowAnEighth() {
        // (0, 3000): 128·722500/9e6 = 10 → floored at 128/8 = 16.
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 3000, master: 128), 16)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 50_000, dy: 50_000, master: 128), 16)
    }

    func testOffAxisSideUsesTheNearLawAndIsAveraged() {
        // (300, 0): far side clamps to v, near = v·40000/90000 = 56; mono avg.
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 300, dy: 0, master: 128), (128 + 56 + 1) / 2)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: -300, dy: 0, master: 128), (128 + 56 + 1) / 2, "mirrored, still mono")
        // On the vertical axis both channels use 850²/d²: full volume out to 850 px.
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 850, master: 128), 128)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 1700, master: 128), 32)
    }

    func testMasterVolumeFromPreference() {
        XCTAssertEqual(OriginalAudio.masterVolume(preference: 7), 56)
        XCTAssertEqual(OriginalAudio.masterVolume(preference: 40), 256)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 0, master: 0), 0)
        XCTAssertEqual(OriginalAudio.spatialVolume(dx: 0, dy: 9000, master: 4), 1, "floor is at least 1")
    }

    // MARK: D-3 voice list (0x004d6550)

    func testOnlyTheFirstEightVoicesAreMixed() {
        XCTAssertTrue(OriginalAudio.VoiceList<Int>.isAudible(index: 7))
        XCTAssertFalse(OriginalAudio.VoiceList<Int>.isAudible(index: 8))
    }

    func testInsertSkipsSlotsWithHigherPriorityOrLouderVolume() {
        var list = OriginalAudio.VoiceList<Int>()
        _ = list.insert(soundID: 200, priority: 4, volume: 64, payload: 0)
        _ = list.insert(soundID: 201, priority: 6, volume: 128, payload: 1)
        XCTAssertEqual(list.voices.map(\.soundID), [201, 200], "higher priority and louder goes first")
        // Higher priority but quieter than slot 0: skips it (volume test), lands before 200.
        _ = list.insert(soundID: 202, priority: 10, volume: 100, payload: 2)
        XCTAssertEqual(list.voices.map(\.soundID), [201, 202, 200])
        // Priority 0 counts as 1; volume over 128 clamps to 128.
        _ = list.insert(soundID: 203, priority: 0, volume: 500, payload: 3)
        XCTAssertEqual(list.voices.last?.priority, 1)
        XCTAssertEqual(list.voices.last?.volumeSum, 256)
    }

    func testAFullListDropsALowerSoundAndEvictsTheSixteenth() {
        var list = OriginalAudio.VoiceList<Int>()
        for i in 0..<16 { _ = list.insert(soundID: 300 + i, priority: 6, volume: 128, payload: i) }
        guard case .dropped = list.insert(soundID: 999, priority: 4, volume: 128, payload: 99) else {
            return XCTFail("ranked below all 16: not played")
        }
        XCTAssertEqual(list.voices.count, 16)
        guard case let .inserted(index, evicted) = list.insert(soundID: 777, priority: 32000, volume: 128, payload: 77) else {
            return XCTFail("the warp-up outranks everything")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(evicted?.soundID, 300, "equal-ranked voices insert ahead, so the oldest falls off the end")
        XCTAssertEqual(list.voices.count, 16)
    }

    func testCountActiveMatchesTheSoundOrEverything() {
        var list = OriginalAudio.VoiceList<Int>()
        _ = list.insert(soundID: 130, priority: 0x32, volume: 128, payload: 0)
        _ = list.insert(soundID: 130, priority: 0x32, volume: 128, payload: 1)
        _ = list.insert(soundID: 150, priority: 1, volume: 128, payload: 2)
        XCTAssertEqual(list.count(soundID: 130), 2)
        XCTAssertEqual(list.count(soundID: 0), 3)
        list.remove { $0.soundID == 130 }
        XCTAssertEqual(list.count(soundID: 130), 0)
    }

    func testPlayerWeaponPriorities() {
        let P = OriginalAudio.Priority.self
        XCTAssertEqual(P.playerWeapon(guidance: -1, flags: 0), 5)
        XCTAssertEqual(P.playerWeapon(guidance: 0, flags: 0), 6, "beam")
        XCTAssertEqual(P.playerWeapon(guidance: 3, flags: 0), 6, "turreted beam")
        XCTAssertEqual(P.playerWeapon(guidance: 99, flags: 0), 6, "carried ship")
        XCTAssertEqual(P.playerWeapon(guidance: 1, flags: 0x0002), 6)
        XCTAssertEqual(P.npcWeapon, 4)
    }

    // MARK: D-8 / D-9 data ranges

    func testWeaponAndBoomSoundRanges() {
        XCTAssertEqual(OriginalAudio.weaponSoundID(raw: 0), 200)
        XCTAssertNil(OriginalAudio.weaponSoundID(raw: -1))
        XCTAssertNil(OriginalAudio.weaponSoundID(raw: -2), "not snd 198")
        XCTAssertEqual(OriginalAudio.boomSoundID(raw: 63), 363)
        XCTAssertNil(OriginalAudio.boomSoundID(raw: 64))
        XCTAssertNil(OriginalAudio.boomSoundID(raw: -2), "not snd 298")
    }

    func testVoiceBankCountsContiguousVariantsUpToNine() {
        let present: Set<Int> = [1100, 1101, 1103, 1110, 1111, 1112, 1113, 1114, 1115, 1116, 1117, 1118, 1119]
        XCTAssertEqual(OriginalAudio.voiceVariants(base: 1100) { present.contains($0) }, [1100, 1101], "stops at the gap")
        XCTAssertEqual(OriginalAudio.voiceVariants(base: 1110) { present.contains($0) }.count, 9, "at most 9")
        XCTAssertEqual(OriginalAudio.voiceVariants(base: 1120) { present.contains($0) }, [])
    }

    func testChatterPicksByBankAndGender() {
        let first: (Int) -> Int = { _ in 0 }
        let last: (Int) -> Int = { $0 - 1 }
        XCTAssertEqual(OriginalAudio.chatterSoundID(bank: 2, voiceType: 3, gender: -1, variantCount: 3, random: last), 1322)
        XCTAssertEqual(OriginalAudio.chatterSoundID(bank: 0, voiceType: 1, gender: 1, variantCount: 2, random: first), 1101)
        XCTAssertEqual(OriginalAudio.chatterSoundID(bank: 1, voiceType: 1, gender: 1, variantCount: 4, random: last), 1113,
                       "even count: odd variants for gender 1")
        XCTAssertEqual(OriginalAudio.chatterSoundID(bank: 1, voiceType: 1, gender: 0, variantCount: 5, random: last), 1114,
                       "odd count: any variant")
        XCTAssertNil(OriginalAudio.chatterSoundID(bank: 0, voiceType: -1, gender: 0, variantCount: 2, random: first))
        XCTAssertNil(OriginalAudio.chatterSoundID(bank: 0, voiceType: 1, gender: 0, variantCount: 0, random: first))
    }

    // MARK: D-6 music

    func testMusicLooksInPluginsFirst() {
        let c = OriginalAudio.musicCandidates(name: "Nova Music")
        XCTAssertEqual(c.map(\.folder), ["Nova Plug-ins", "Nova Plug-ins", "Nova Plug-ins",
                                        "Nova Files", "Nova Files", "Nova Files"])
        XCTAssertEqual(c.map(\.file), ["Nova Music", "Nova Music.mov", "Nova Music.mp3",
                                      "Nova Music", "Nova Music.mov", "Nova Music.mp3"])
    }

    func testMusicVolumes() {
        XCTAssertEqual(OriginalAudio.musicStartVolume(preference: 4), 192)
        XCTAssertEqual(OriginalAudio.musicPlayingVolume(preference: 4), 128)
        XCTAssertEqual(OriginalAudio.musicStartVolume(preference: 8), 256, "clamped")
        XCTAssertEqual(OriginalAudio.musicFadeTicks(preference: 4), 16, "−8 per tick from 128")
    }
}
