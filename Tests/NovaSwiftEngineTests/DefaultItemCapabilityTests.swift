import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// OS-01 / OS-09: an NPC's stats ignore its hull's DefaultItems, but its
/// capabilities read them; jamming, multi-jump and max guns/turrets add once
/// per owned def, not per unit.
final class DefaultItemCapabilityTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    /// An outfit with up to four (ModType, ModVal) slots.
    private func outfit(_ id: Int, _ mods: [(Int, Int)]) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        for (slot, (type, value)) in zip([6, 18, 22, 26], mods) {
            put16(&b, slot, type); put16(&b, slot + 2, value)
        }
        return Resource(type: NovaType.outfit, id: id, name: "Outfit \(id)", data: Data(b))
    }

    /// Hull 128 (shield 100) whose DefaultItems are a cloak (200), a shield
    /// booster (201), a jammer ×2 (202) and a multi-jump drive (203).
    private func makeGame() -> NovaGame {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 1860)
        put16(&ship, 2, 100)    // shield
        put16(&ship, 6, 300)    // speed
        put16(&ship, 14, 80)    // armor
        put16(&ship, 42, 2)     // max guns
        put16(&ship, 78, 200); put16(&ship, 86, 1)
        put16(&ship, 80, 201); put16(&ship, 88, 1)
        put16(&ship, 82, 202); put16(&ship, 90, 2)
        put16(&ship, 84, 203); put16(&ship, 92, 1)
        col.add(Resource(type: NovaType.ship, id: 128, name: "Cloaker", data: Data(ship)))
        col.add(outfit(200, [(17, 0x0010)]))            // cloak, 1 fuel/s
        col.add(outfit(201, [(4, 50)]))                 // +50 shield
        col.add(outfit(202, [(33, 20), (45, 1)]))       // 20-point type-1 jammer, +1 gun
        col.add(outfit(203, [(32, 2)]))                 // multi-jump +2
        return NovaGame(col)
    }

    func testNPCCapabilitiesComeFromDefaultItemsButStatsDoNot() throws {
        let galaxy = Galaxy(game: makeGame())
        let npc = try XCTUnwrap(galaxy.makeLoadedShip(128, includeDefaultItems: false,
                                                      defaultItemCapabilities: true))
        XCTAssertEqual(npc.cloakFlags, 0x0010, "the default-item cloak is a real device")
        XCTAssertEqual(npc.jamming, [20, 0, 0, 0], "jammer counted once, not ×2")
        XCTAssertEqual(npc.maxShield, 100 * galaxy.combatTuning.hpScale,
                       "max shield is the class base: the booster is a stat")

        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128, includeDefaultItems: false,
                                              defaultItemCapabilities: true))
        XCTAssertEqual(lo.multiJumpDepth, 3)
        XCTAssertEqual(lo.maxJumpHops, 2, "depth − 1 route systems")
        XCTAssertEqual(lo.maxGuns, 2, "ModType 45 is a stat; NPCs don't get it")

        let bare = try XCTUnwrap(galaxy.makeLoadedShip(128, includeDefaultItems: false))
        XCTAssertEqual(bare.cloakFlags, 0, "the player path (both flags off) reads nothing from DefaultItems")
    }

    func testOwnedOutfitsStackOncePerDef() throws {
        let galaxy = Galaxy(game: makeGame())
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128, extraOutfits: [202: 2, 203: 3],
                                              includeDefaultItems: false))
        XCTAssertEqual(lo.jamming, [20, 0, 0, 0], "two units of a 20-point jammer jam at 20")
        XCTAssertEqual(lo.multiJumpDepth, 3, "max(1, 1 + Σ ModVal) over owned defs")
        XCTAssertEqual(lo.maxGuns, 3, "ModType 45 adds once per def")
    }

    func testEnhancementsDecodeMissingKeysAsOff() throws {
        let decoded = try JSONDecoder().decode(GameplayEnhancements.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, GameplayEnhancements())
        XCTAssertEqual(GameplayEnhancements().enabledCount, 0, "every enhancement defaults off")

        var on = GameplayEnhancements()
        on.manualPluginOrder = true
        let round = try JSONDecoder().decode(GameplayEnhancements.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(round, on)
        XCTAssertEqual(Set(GameplayEnhancements.catalog.map(\.key)).count, GameplayEnhancements.catalog.count)
    }

    /// A settings blob saved before 17 enhancements were removed still loads:
    /// the removed keys are ignored and the surviving toggles keep their values.
    func testEnhancementsIgnoreRemovedKeys() throws {
        let removed = ["portFlightTuning", "retroThrustReverse", "npcAfterburners", "freeMunitionsRefill",
                       "playerBlastImmunity", "forgivingEscapePod", "starterIFF", "piracyPolice",
                       "planetLaunchArrivals", "hypergateTraffic", "reinforcementShortcut", "targetArmorReadout",
                       "extraStatusMessages", "largerEscortWing", "immediateMissionEscortLink",
                       "sweptShotContact", "novaSwiftAI"]
        XCTAssertTrue(Set(removed).isDisjoint(with: GameplayEnhancements.catalog.map(\.key)))
        XCTAssertEqual(GameplayEnhancements.catalog.map(\.key).sorted(),
                       ["autoRoutePlotting", "forgivingLanding", "formationFlying", "frequentAutosave",
                        "manualPluginOrder", "modernKeyBindings", "nearestFirstTargeting", "quickHyperjump"])
        var blob: [String: Bool] = Dictionary(uniqueKeysWithValues: removed.map { ($0, true) })
        blob["frequentAutosave"] = true
        blob["quickHyperjump"] = false
        let settings = try JSONSerialization.data(withJSONObject: ["difficulty": "normal", "enhancements": blob])

        struct SettingsBlob: Decodable { var enhancements: GameplayEnhancements }
        let decoded = try JSONDecoder().decode(SettingsBlob.self, from: settings).enhancements
        var expected = GameplayEnhancements()
        expected.frequentAutosave = true
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.enabledCount, 1)
    }
}
