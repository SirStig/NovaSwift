import XCTest
@testable import NovaSwiftKit

/// Every case here is either quoted verbatim from the Nova Bible's `dësc`
/// section or taken from a real resource in the shipped data.
final class TextFormattingTests: XCTestCase {

    // MARK: Display names

    func testDisplayNameStripsSemicolonAnnotation() {
        // All four are real resource names from Nova Data 1.rez.
        XCTAssertEqual("Shuttle;Second-Hand - poor".novaDisplayName, "Shuttle")
        XCTAssertEqual("Heavy Shuttle;Second-Hand - upgrade".novaDisplayName, "Heavy Shuttle")
        XCTAssertEqual("Zephyr;Cloaking+fast jump".novaDisplayName, "Zephyr")
        XCTAssertEqual("Recover Stolen Art;Special".novaDisplayName, "Recover Stolen Art")
    }

    /// "Lightning; Wild Geese" has a space after the semicolon.
    func testDisplayNameTrimsTrailingSpace() {
        XCTAssertEqual("Lightning; Wild Geese".novaDisplayName, "Lightning")
    }

    func testDisplayNamePassesThroughPlainNames() {
        XCTAssertEqual("Viper".novaDisplayName, "Viper")
        XCTAssertEqual("Asteroid Miner".novaDisplayName, "Asteroid Miner")
        XCTAssertEqual("".novaDisplayName, "")
    }

    /// 0x004cd230 scans from the end: a name that starts with its only `;` is
    /// stripped to nothing, as in the original.
    func testDisplayNameLeadingSemicolonBecomesEmpty() {
        XCTAssertEqual(";internal".novaDisplayName, "")
    }

    /// The cut is at the **last** `;`, and trailing spaces/semicolons before it
    /// go too; leading spaces stay.
    func testDisplayNameCutsAtLastSemicolon() {
        XCTAssertEqual("A;B;C".novaDisplayName, "A;B")
        XCTAssertEqual("AB ;; note".novaDisplayName, "AB")
        XCTAssertEqual(" Lead;x".novaDisplayName, " Lead")
    }

    // MARK: Grid names (FUN_0046e6d0)

    func testGridNameSplitsOnceOnEitherCase() {
        XCTAssertEqual(#"IR Missile\nLauncher"#.novaGridName, "IR Missile\nLauncher")
        let (a, b) = #"A\NB\nC"#.novaGridLines
        XCTAssertEqual(a, "A")
        XCTAssertEqual(b, "BC")
        XCTAssertNil("Plain".novaGridLines.1)
        // A trailing backslash is literal.
        XCTAssertEqual(#"X\"#.novaGridLines.0, #"X\"#)
    }

    // MARK: Grouped numbers (0x00465af0)

    func testGroupedNumberFormat() {
        XCTAssertEqual(NovaNumberFormat.grouped(0), "0")
        XCTAssertEqual(NovaNumberFormat.grouped(999), "999")
        XCTAssertEqual(NovaNumberFormat.grouped(-5000), "-5000")
        XCTAssertEqual(NovaNumberFormat.grouped(1005), "1,005")
        XCTAssertEqual(NovaNumberFormat.grouped(12345), "12,345")
        XCTAssertEqual(NovaNumberFormat.grouped(999_999), "999,999")
        XCTAssertEqual(NovaNumberFormat.grouped(1_000_000), "1.00M")
        XCTAssertEqual(NovaNumberFormat.grouped(1_239_999), "1.23M")
        XCTAssertEqual(NovaNumberFormat.grouped(25_050_000), "25.05M")
    }

    // MARK: Bit conditionals

    /// Bible: `This is a {b001 "great and terrific" "lousy, terrible"} example.`
    func testBitConditionalBothBranches() {
        let src = #"This is a {b001 "great and terrific" "lousy, terrible"} example."#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 1 })),
                       "This is a great and terrific example.")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { _ in false })),
                       "This is a lousy, terrible example.")
    }

    /// "If there is no second string, nothing will be substituted."
    func testBitConditionalSingleStringSubstitutesNothingWhenFalse() {
        let src = #"You are{b010 " a hero"}."#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 10 })),
                       "You are a hero.")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { _ in false })),
                       "You are.")
    }

    func testNegatedBitTest() {
        let src = #"{!b005 "absent" "present"}"#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { _ in false })), "absent")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 5 })), "present")
    }

    /// The exact shape seen leaking into the outfitter: `…everywhere{b424 "…`
    func testRealOutfitDescriptionShape() {
        let src = #"available nearly everywhere{b424 ", though it is illegal"}."#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { _ in false })),
                       "available nearly everywhere.")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 424 })),
                       "available nearly everywhere, though it is illegal.")
    }

    // MARK: Escapes

    /// Bible: `My name is {b002 "Dave \"pipeline\" Williams"}`
    func testEscapedQuotesInsideStrings() {
        let src = #"My name is {b002 "Dave \"pipeline\" Williams"}"#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 2 })),
                       #"My name is Dave "pipeline" Williams"#)
    }

    // MARK: Gender

    /// Bible: `…the player is {G "a male character" "a female pilot"}.`
    func testGenderConditional() {
        let src = #"the player is {G "a male character" "a female pilot"}."#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isMale: true)),
                       "the player is a male character.")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isMale: false)),
                       "the player is a female pilot.")
    }

    func testNegatedGenderConditional() {
        XCTAssertEqual(NovaDescFormatter.render(#"{!G "she" "he"}"#, context: .init(isMale: true)), "he")
    }

    // MARK: Registration

    /// Bible: `This is a test string you {P "have paid" "haven't paid"}.`
    func testRegistrationConditional() {
        let src = #"you {P "have paid" "haven't paid"}."#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isRegistered: true)), "you have paid.")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isRegistered: false)), "you haven't paid.")
    }

    /// `Pxxx` = registered at least xxx days ago.
    func testRegistrationWithDayCount() {
        let src = #"{P30 "veteran" "newcomer"}"#
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isRegistered: true, daysRegistered: 45)), "veteran")
        XCTAssertEqual(NovaDescFormatter.render(src, context: .init(isRegistered: true, daysRegistered: 10)), "newcomer")
    }

    // MARK: Robustness

    /// A stray brace must survive, not eat the rest of the description.
    func testMalformedSequencesPassThroughVerbatim() {
        XCTAssertEqual(NovaDescFormatter.render("a { b c"), "a { b c")
        XCTAssertEqual(NovaDescFormatter.render(#"{b12 "unterminated"#), #"{b12 "unterminated"#)
        XCTAssertEqual(NovaDescFormatter.render("{zzz \"x\"}"), "{zzz \"x\"}")
        XCTAssertEqual(NovaDescFormatter.render("{b \"no digits\"}"), "{b \"no digits\"}")
        XCTAssertEqual(NovaDescFormatter.render("plain text"), "plain text")
    }

    func testMultipleConditionalsInOneBody() {
        let src = #"{b1 "A" "a"} and {b2 "B" "b"} and {G "M" "F"}"#
        let out = NovaDescFormatter.render(src, context: .init(isBitSet: { $0 == 2 }, isMale: false))
        XCTAssertEqual(out, "a and B and F")
    }

    // MARK: Newlines

    /// Resources are stored with classic-Mac CR line endings.
    func testNormalizesClassicMacNewlines() {
        XCTAssertEqual(NovaDescFormatter.render("one\rtwo"), "one\ntwo")
        XCTAssertEqual(NovaDescFormatter.render("one\r\ntwo"), "one\ntwo")
        XCTAssertEqual(NovaDescFormatter.render("one\ntwo"), "one\ntwo")
    }
}
