import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

final class SoundCuesTests: XCTestCase {
    func testBeepsMapTo150Through154AtPriorityOne() {
        XCTAssertEqual((1...5).compactMap { SoundCues.beep($0)?.soundID }, [150, 151, 152, 153, 154])
        XCTAssertNil(SoundCues.beep(0)); XCTAssertNil(SoundCues.beep(6))
        XCTAssertEqual(SoundCues.beep(1)?.priority, OriginalAudio.Priority.beep)
    }

    func testEventsMapToTheOriginalsCallSites() {
        let at = Vec2(10, 20)
        XCTAssertEqual(SoundCues.cues(for: .explosion(at: at, radius: 30, soundID: 300, boomID: 1), game: nil),
                       [SoundCue(soundID: 300, priority: OriginalAudio.Priority.explosion, position: at)])
        XCTAssertTrue(SoundCues.cues(for: .explosion(at: at, radius: 30, soundID: nil, boomID: 1), game: nil).isEmpty)
        // Player weapon fire is centred; an NPC's is positional at priority 4.
        let player = SoundCues.cues(for: .weaponFired(shooterID: 0, at: at, heading: 0, soundID: 200, weaponID: -1), game: nil)
        XCTAssertNil(player.first?.position)
        let npc = SoundCues.cues(for: .weaponFired(shooterID: 7, at: at, heading: 0, soundID: 200, weaponID: -1), game: nil)
        XCTAssertEqual(npc.first?.position, at)
        XCTAssertEqual(npc.first?.priority, OriginalAudio.Priority.npcWeapon)
        XCTAssertEqual(SoundCues.cues(for: .playerCloakChanged(engaging: true), game: nil).first?.soundID, 381)
        XCTAssertEqual(SoundCues.cues(for: .interfaceBeep(soundID: 153), game: nil).first?.soundID, 153)
        XCTAssertTrue(SoundCues.cues(for: .shipLanded(entityID: 5, spobID: 1, at: at), game: nil).isEmpty)
        XCTAssertEqual(SoundCues.cues(for: .shipLanded(entityID: 0, spobID: 1, at: at), game: nil).first?.soundID, 390)
    }

    func testVoiceBoardRanksAndGuards() {
        let board = SoundVoiceBoard()
        let origin = Vec2()
        XCTAssertTrue(board.play(SoundCues.hyperspaceArrive, listener: origin, duration: 2, now: 0))
        // Warp out is guarded while one sounds.
        XCTAssertFalse(board.play(SoundCues.hyperspaceArrive, listener: origin, duration: 2, now: 0.5))
        // More than 8 voices: only the first 8 are audible.
        for _ in 0..<10 { board.play(SoundCue(soundID: 200, priority: 4), listener: origin, duration: 1, now: 0.6) }
        let cmds = board.commands(now: 0.6)
        XCTAssertEqual(cmds.count, 11)
        XCTAssertEqual(cmds.filter { $0.gain > 0 }.count, 8)
        XCTAssertTrue(cmds.allSatisfy { $0.action == .start })
        // Far sounds never drop below the 1/8 floor.
        let far = SoundVoiceBoard()
        far.play(SoundCue(soundID: 200, priority: 4, position: Vec2(100_000, 0)), listener: origin, duration: 1, now: 0)
        XCTAssertEqual(far.commands(now: 0).first?.gain ?? 0, 1.0 / 8, accuracy: 0.01)
        // Voices free at their sample end; stop emits a stop row.
        XCTAssertEqual(board.activeCount(soundID: 0, now: 100), 0)
        board.play(SoundCue(soundID: 5, priority: 4), listener: origin, duration: 5, now: 100)
        _ = board.commands(now: 100)
        board.stop(soundID: 5)
        XCTAssertEqual(board.commands(now: 100).map(\.action), [.stop])
    }

    func testPcm16LittleEndian() {
        let s = NovaSound(sampleRate: 11025, samples: [0, 1, -1, 0.5])
        XCTAssertEqual(s.pcm16LE(), [0, 0, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x3F])
    }
}
