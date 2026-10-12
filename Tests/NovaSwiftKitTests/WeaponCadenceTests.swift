import XCTest
@testable import NovaSwiftKit

final class WeaponCadenceTests: XCTestCase {

    func testPlainWeaponStaggeredAndSimultaneous() {
        // 1 mount, reload 30 ticks: one shot per second.
        XCTAssertEqual(WeaponCadence.compute(reloadTicks: 30, burstCount: 0, burstReloadTicks: 0, mounts: 1,
                                             simultaneous: false).shotsPerSecond, 1, accuracy: 1e-9)
        // 3 staggered mounts: 3 shots per reload period overall.
        XCTAssertEqual(WeaponCadence.compute(reloadTicks: 30, burstCount: 0, burstReloadTicks: 0, mounts: 3,
                                             simultaneous: false).shotsPerSecond, 3, accuracy: 1e-9)
        // 3 simultaneous mounts: 3 shots per reload period too.
        XCTAssertEqual(WeaponCadence.compute(reloadTicks: 30, burstCount: 0, burstReloadTicks: 0, mounts: 3,
                                             simultaneous: true).shotsPerSecond, 3, accuracy: 1e-9)
    }

    func testReloadZeroIsOneTick() {
        XCTAssertEqual(WeaponCadence.compute(reloadTicks: 0, burstCount: 0, burstReloadTicks: 0, mounts: 1,
                                             simultaneous: false).shotsPerSecond, 30, accuracy: 1e-9)
    }

    func testBurstSingleMount() {
        // 4 shots at reload 3, then burst reload 60: cycle = 3 x 3 + 60 = 69 ticks for 4 shots.
        let c = WeaponCadence.compute(reloadTicks: 3, burstCount: 4, burstReloadTicks: 60, mounts: 1, simultaneous: false)
        XCTAssertEqual(c.shotsPerCycle, 4)
        XCTAssertEqual(c.cycleSeconds, 69.0 / 30, accuracy: 1e-9)
    }

    func testBurstScalesWithMountsWhenStaggered() {
        // 2 staggered mounts: the burst is 2 x 4 = 8 volleys of reload/2 = 3 ticks, then 60.
        let c = WeaponCadence.compute(reloadTicks: 6, burstCount: 4, burstReloadTicks: 60, mounts: 2, simultaneous: false)
        XCTAssertEqual(c.shotsPerCycle, 8)
        XCTAssertEqual(c.cycleSeconds, (7 * 3.0 + 60) / 30, accuracy: 1e-9)
    }

    func testBurstIndependentOfMountsWhenSimultaneous() {
        // 2 simultaneous mounts: 4 volleys of 2 shots each, volley cooldown = reload.
        let c = WeaponCadence.compute(reloadTicks: 6, burstCount: 4, burstReloadTicks: 60, mounts: 2, simultaneous: true)
        XCTAssertEqual(c.shotsPerCycle, 8)
        XCTAssertEqual(c.cycleSeconds, (3 * 6.0 + 60) / 30, accuracy: 1e-9)
    }

    func testBurstCountOneUsesBurstReloadEveryShot() {
        let c = WeaponCadence.compute(reloadTicks: 5, burstCount: 1, burstReloadTicks: 45, mounts: 1, simultaneous: false)
        XCTAssertEqual(c.shotsPerCycle, 1)
        XCTAssertEqual(c.cycleSeconds, 45.0 / 30, accuracy: 1e-9)
    }

    // MARK: Submunitions

    private func graph(_ nodes: [Int: SubmunitionNode]) -> (Int) -> SubmunitionNode? { { nodes[$0] } }

    func testSimpleSubmunitions() {
        let g = graph([
            128: SubmunitionNode(shieldDamage: 10, armorDamage: 10, subID: 129, subCount: 5),
            129: SubmunitionNode(shieldDamage: 4, armorDamage: 2),
        ])
        let t = SubmunitionDamage.total(of: 128, node: g)
        XCTAssertEqual(t.shield, 20); XCTAssertEqual(t.armor, 10); XCTAssertFalse(t.truncated)
        XCTAssertTrue(SubmunitionDamage.total(of: 129, node: g).isEmpty)
    }

    func testNestedSubmunitionsMultiply() {
        let g = graph([
            128: SubmunitionNode(shieldDamage: 0, armorDamage: 0, subID: 129, subCount: 2),
            129: SubmunitionNode(shieldDamage: 1, armorDamage: 1, subID: 130, subCount: 3),
            130: SubmunitionNode(shieldDamage: 5, armorDamage: 7),
        ])
        let t = SubmunitionDamage.total(of: 128, node: g)
        XCTAssertEqual(t.shield, 2 * (1 + 3 * 5)); XCTAssertEqual(t.armor, 2 * (1 + 3 * 7))
    }

    func testSelfSplittingWeaponHonoursSubLimit() {
        // Splits into 2 copies of itself, at most 2 generations deep (SubLimit 2).
        let g = graph([128: SubmunitionNode(shieldDamage: 1, armorDamage: 0, subID: 128, subCount: 2, subLimit: 2)])
        // gen0 -> 2 children (gen1) -> each spawns 2 (gen2) -> gen2 stops (limit 2 <= generation 2).
        // damage = 2 x (1 + 2 x 1) = 6
        let t = SubmunitionDamage.total(of: 128, node: g)
        XCTAssertEqual(t.shield, 6); XCTAssertFalse(t.truncated)
    }

    func testUnboundedRecursionIsCappedAndFlagged() {
        let g = graph([128: SubmunitionNode(shieldDamage: 1, armorDamage: 1, subID: 128, subCount: 1, subLimit: 0)])
        let t = SubmunitionDamage.total(of: 128, depthCap: 3, node: g)
        XCTAssertTrue(t.truncated)
        XCTAssertEqual(t.shield, 3)
    }

    func testBeamAndMissingSubmunitionsAddNothing() {
        let g = graph([
            128: SubmunitionNode(shieldDamage: 1, armorDamage: 1, subID: 129, subCount: 3),
            129: SubmunitionNode(shieldDamage: 50, armorDamage: 50, cannotBeSubmunition: true),
            130: SubmunitionNode(shieldDamage: 1, armorDamage: 1, subID: 999, subCount: 3),
        ])
        XCTAssertTrue(SubmunitionDamage.total(of: 128, node: g).isEmpty)
        XCTAssertTrue(SubmunitionDamage.total(of: 130, node: g).isEmpty)
    }
}
