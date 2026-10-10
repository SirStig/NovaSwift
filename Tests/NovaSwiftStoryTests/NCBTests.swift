import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

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
        // 0x00447f20: only an empty string is always true; a leading space is false.
        XCTAssertFalse(NCBTest("   ").evaluate(Ctx()))
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

    // Regressions grounded in the EV Nova CE Windows executable's tokenizer and
    // evaluator at 0x448BE0 / 0x449020, rather than conventional precedence.
    func testCountedSetsCompareAndNegate() {
        var c = Ctx(); c.bits = [1, 2]
        XCTAssertTrue(NCBTest("( [b1 b2 b3] = 2 )").evaluate(c))
        XCTAssertTrue(NCBTest("( [b1 b2 b3] > 1 )").evaluate(c))
        XCTAssertTrue(NCBTest("( [b1 b2 b3] < 3 )").evaluate(c))
        XCTAssertFalse(NCBTest("( [b1 b2 b3] = 1 )").evaluate(c))
        XCTAssertTrue(NCBTest("( [!b1 !b2 !b3] = 1 )").evaluate(c))
        XCTAssertTrue(NCBTest("!( [b4 b5] > 0 )").evaluate(c))
        // Its cursor scan also makes an adjacent '(' / '[' behave differently.
        XCTAssertFalse(NCBTest("([b1 b2 b3] = 2)").evaluate(c))
        // 0x447F20 rejects a bare leading '['; parentheses are required.
        XCTAssertFalse(NCBTest("[b1 b2] = 2").evaluate(c))
    }

    func testMixedOperatorsUseOriginalAccumulator() {
        var c = Ctx(); c.bits = [1]
        XCTAssertFalse(NCBTest("b1 | b2 & b3").evaluate(c))
        XCTAssertTrue(NCBTest("b1 | (b2 & b3)").evaluate(c))
        c.bits = [2]
        XCTAssertTrue(NCBTest("b1 & b2 | b3").evaluate(c))
        XCTAssertFalse(NCBTest("(b1 & b2) | b3").evaluate(c))
        // Every new operator starts from the latest operand, even the same
        // operator. Grouping is what preserves an earlier accumulated value.
        c.bits = [2, 3]
        XCTAssertTrue(NCBTest("b1 & b2 & b3").evaluate(c))
        XCTAssertFalse(NCBTest("(b1 & b2) & b3").evaluate(c))
    }

    func testRepeatedOperatorsCollapseToOneToken() {
        var c = Ctx(); c.bits = [1, 2]
        XCTAssertTrue(NCBTest("b1 &&& b2").evaluate(c))
        c.bits = [2]
        XCTAssertFalse(NCBTest("b1 && b2").evaluate(c))
        XCTAssertTrue(NCBTest("b1 ||| b2").evaluate(c))
        c.bits = []
        XCTAssertFalse(NCBTest("b1 || b2").evaluate(c))
    }

    func testRepeatedNegationKeepsOnePendingFlag() {
        var c = Ctx(); c.bits = [1]
        XCTAssertFalse(NCBTest("!!b1").evaluate(c))
        XCTAssertFalse(NCBTest("!!!(b1 | b2)").evaluate(c))
        XCTAssertTrue(NCBTest("!(!b1)").evaluate(c))
        c.bits = []
        XCTAssertTrue(NCBTest("!!b1").evaluate(c))
    }

    func testReferencedBitsIncludeCountedSetsAndPendingNegation() {
        let bits = NCBTest("!([!!b1 b2 !b3] = 2)").referencedBits
        XCTAssertEqual(bits.map(\.bit), [1, 2, 3])
        XCTAssertEqual(bits.map(\.negated), [false, true, false])
    }

    func testReferencedBitsUsesAdjacentASCIIDigits() {
        let expression = NCBTest("b 1")
        XCTAssertEqual(expression.referencedBits.map(\.bit), [0])
        var c = Ctx(); c.bits = [1]
        XCTAssertFalse(expression.evaluate(c))
        c.bits = [0]
        XCTAssertTrue(expression.evaluate(c))
    }

    func testReferencedBitsSharesSigned16BitNumberWrapping() {
        let expression = NCBTest("b65537")
        XCTAssertEqual(expression.referencedBits.map(\.bit), [1])
        var c = Ctx(); c.bits = [1]
        XCTAssertTrue(expression.evaluate(c))
        c.bits = []
        XCTAssertFalse(expression.evaluate(c))
    }

    func testReferencedBitsPreservesGroupedAndRepeatedNegation() {
        let bits = NCBTest("!!(b1 | !(!b2)) & !!!b3").referencedBits
        XCTAssertEqual(bits.map(\.bit), [1, 2, 3])
        XCTAssertEqual(bits.map(\.negated), [true, true, true])
    }

    // MARK: SET expressions

    func testDigitLeadingGraphemeClusterDoesNotHang() {
        // "1\u{FE0F}\u{20E3}" is one Character that starts with a digit but is
        // not an ASCII digit. It must not stall the tokenizer.
        var c = Ctx(); c.bits = [1]
        let test = NCBTest("b1 & 1\u{FE0F}\u{20E3}")
        XCTAssertFalse(test.evaluate(c))
        XCTAssertEqual(test.referencedBits.map(\.bit), [1])
    }

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
        // Each op of R(a b) only runs on one coin flip.
        XCTAssertEqual(NCBSet.parse("R(b1 b2)"), [.random([.setBit(1)]), .random([.setBit(2)])])
    }

    // MARK: - SET interpreter quirks (Mission_ExecuteMisnScriptEngine, 0x00449370)

    private func run(_ text: String, flips: [Int] = []) -> [NCBSetOp] {
        var queue = flips
        return NCBSet.resolve(text, pick: { queue.isEmpty ? 0 : queue.removeFirst() })
    }

    func testSetOpcodesAreCaseInsensitive() {
        XCTAssertEqual(run("k148 g252 l143"), [.activateRank(148), .grantOutfit(252), .deactivateRank(143)])
    }

    func testSetSecondOpcodeBeforeDelimiterReplacesTheFirst() {
        XCTAssertEqual(run("S862S863"), [.startMission(863)])
    }

    func testSetBitPrefixesAndBareForms() {
        XCTAssertEqual(run("!b45 !45 ^b46 ^46"),
                       [.clearBit(45), .clearBit(45), .toggleBit(46), .toggleBit(46)])
        XCTAssertEqual(run("b10001 b9999"), [.setBit(9999)])
    }

    func testSetIgnoresOperandsOutsideEachCommandsRange() {
        XCTAssertEqual(run("G640 G639 K256 K255 S1128 S1127"),
                       [.grantOutfit(639), .activateRank(255), .startMission(1127)])
    }

    func testSetRandomRunsExactlyOneOfTwo() {
        XCTAssertEqual(run("d358 R(g374 g261)", flips: [0]), [.removeOutfit(358), .grantOutfit(261)])
        XCTAssertEqual(run("d358 R(g374 g261)", flips: [1]), [.removeOutfit(358), .grantOutfit(374)])
    }

    func testSetRandomSpacingQuirks() {
        // A space after "(" means flip 0 skips the space, not the opcode: both run.
        XCTAssertEqual(run("R( g374 g261)", flips: [0]), [.grantOutfit(374), .grantOutfit(261)])
        // A lone R(b5) that fires leaves the coin armed: the next delimiter is
        // swallowed. After ") " that's the space, harmless; with no space it
        // eats the following op. (Outputs taken from running 0x00449370.)
        XCTAssertEqual(run("R(b5) b6 b7", flips: [1]), [.setBit(5), .setBit(6), .setBit(7)])
        XCTAssertEqual(run("R(b5)b6 b7", flips: [1]), [.setBit(5), .setBit(7)])
        XCTAssertEqual(run("R(b5)b6 b7", flips: [0]), [.setBit(6), .setBit(7)])
        XCTAssertEqual(run("R( b1 b2)", flips: [1]), [.setBit(1)])
        // A second "b" re-zeroes the operand without executing.
        XCTAssertEqual(run("b1b2 b3"), [.setBit(2), .setBit(3)])
    }

    func testSetSkipsGarbageTokens() {
        // Unknown tokens are dropped, valid ones kept.
        XCTAssertEqual(NCBSet.parse("b1 ??? b2"), [.setBit(1), .setBit(2)])
    }

    func testReferencedBitsReportsEachEffect() {
        let bits = NCBSet.referencedBits("b1 !b2 ^b3 G152")
        XCTAssertEqual(bits.map(\.bit), [1, 2, 3])          // G152 contributes no bit
        XCTAssertEqual(bits.map(\.effect), [.set, .clear, .toggle])
    }

    /// A bit written only inside `R( … )` must still be reported: it's reachable,
    /// just not every time. Missing this made such bits look unreachable to
    /// anything building a "what changes this bit" index.
    func testReferencedBitsReachesInsideRandom() {
        let bits = NCBSet.referencedBits("R(b800 !b900)")
        XCTAssertEqual(bits.map(\.bit), [800, 900])
        XCTAssertEqual(bits.map(\.effect), [.set, .clear])
    }

    func testReferencedBitsIgnoresNonBitOps() {
        XCTAssertTrue(NCBSet.referencedBits("S781 G152 K128 Q25059").isEmpty)
    }
}
