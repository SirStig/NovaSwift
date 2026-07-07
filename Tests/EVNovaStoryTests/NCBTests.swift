import XCTest
import EVNovaKit
@testable import EVNovaStory

/// A trivial context for testing TEST-expression evaluation in isolation.
private struct Ctx: NCBTestContext {
    var bits: Set<Int> = []
    var outfits: Set<Int> = []
    var explored: Set<Int> = []
    var male = true
    var unreg = 0
    func isBitSet(_ n: Int) -> Bool { bits.contains(n) }
    func hasOutfit(_ id: Int) -> Bool { outfits.contains(id) }
    func isSystemExplored(_ id: Int) -> Bool { explored.contains(id) }
    var playerIsMale: Bool { male }
    var unregisteredDays: Int { unreg }
}

final class NCBTests: XCTestCase {

    func testEmptyExpressionIsAlwaysTrue() {
        XCTAssertTrue(NCBTest("").evaluate(Ctx()))
        XCTAssertTrue(NCBTest("   ").isAlwaysTrue)
    }

    func testSingleBit() {
        var c = Ctx()
        XCTAssertFalse(NCBTest("b100").evaluate(c))
        c.bits.insert(100)
        XCTAssertTrue(NCBTest("b100").evaluate(c))
    }

    func testNegation() {
        var c = Ctx()
        XCTAssertTrue(NCBTest("!b5").evaluate(c))
        c.bits.insert(5)
        XCTAssertFalse(NCBTest("!b5").evaluate(c))
    }

    func testAndOr() {
        var c = Ctx(); c.bits = [1, 2]
        XCTAssertTrue(NCBTest("b1 & b2").evaluate(c))
        XCTAssertFalse(NCBTest("b1 & b3").evaluate(c))
        XCTAssertTrue(NCBTest("b1 | b3").evaluate(c))
        XCTAssertFalse(NCBTest("b7 | b3").evaluate(c))
    }

    /// The exact expression from real mission #128: "!(b511 | b515) & !b350".
    func testRealMissionExpression() {
        let expr = NCBTest("!(b511 | b515) & !b350")
        // No bits set → available.
        XCTAssertTrue(expr.evaluate(Ctx()))
        // b350 set (mission already done) → not available.
        var done = Ctx(); done.bits = [350]
        XCTAssertFalse(expr.evaluate(done))
        // b511 set (on a different story path) → not available.
        var alt = Ctx(); alt.bits = [511]
        XCTAssertFalse(expr.evaluate(alt))
    }

    /// Nested precedence: "!(b1 | b2) & (b3 | b4)".
    func testNestedPrecedence() {
        let expr = NCBTest("!(b1 | b2) & (b3 | b4)")
        var c = Ctx(); c.bits = [3]
        XCTAssertTrue(expr.evaluate(c))
        c.bits = [2, 3]                      // b2 set → left side false
        XCTAssertFalse(expr.evaluate(c))
        c.bits = [5]                         // neither b3 nor b4 → right side false
        XCTAssertFalse(expr.evaluate(c))
    }

    func testOutfitAndExploredAndGender() {
        var c = Ctx(); c.outfits = [152]; c.explored = [300]; c.male = false
        XCTAssertTrue(NCBTest("o152").evaluate(c))
        XCTAssertFalse(NCBTest("o999").evaluate(c))
        XCTAssertTrue(NCBTest("e300").evaluate(c))
        XCTAssertFalse(NCBTest("g").evaluate(c))       // female player
        XCTAssertTrue(NCBTest("!g").evaluate(c))
    }

    func testUnregisteredDays() {
        var c = Ctx(); c.unreg = 0
        XCTAssertTrue(NCBTest("p30").evaluate(c))       // 0 <= 30
        c.unreg = 40
        XCTAssertFalse(NCBTest("p30").evaluate(c))      // 40 > 30
    }

    // MARK: SET expressions

    func testSetParsesBitsAndCommands() {
        // Real mission #128 onSuccess: "b350 b6666".
        XCTAssertEqual(NCBSet.parse("b350 b6666"), [.setBit(350), .setBit(6666)])
        XCTAssertEqual(NCBSet.parse("!b12 ^b13"), [.clearBit(12), .toggleBit(13)])
        XCTAssertEqual(NCBSet.parse("S781"), [.startMission(781)])
        XCTAssertEqual(NCBSet.parse("A130 F131"), [.abortMission(130), .failMission(131)])
        XCTAssertEqual(NCBSet.parse("G152 D200"), [.grantOutfit(152), .removeOutfit(200)])
        XCTAssertEqual(NCBSet.parse("K128 L129"), [.activateRank(128), .deactivateRank(129)])
    }

    func testSetParsesLeaveAndRandom() {
        XCTAssertEqual(NCBSet.parse("Q"), [.leaveStellar(messageStr: nil)])
        XCTAssertEqual(NCBSet.parse("Q25059"), [.leaveStellar(messageStr: 25059)])
        // R( ... ) keeps its inner space-separated ops together.
        XCTAssertEqual(NCBSet.parse("R(b1 b2)"), [.random([.setBit(1), .setBit(2)])])
    }

    func testSetSkipsGarbageTokens() {
        // Unknown tokens are dropped, valid ones kept.
        XCTAssertEqual(NCBSet.parse("b1 ??? b2"), [.setBit(1), .setBit(2)])
    }
}
