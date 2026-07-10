import XCTest
@testable import EVNovaKit

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

    /// A name that is *only* an annotation would render blank; keep it raw so the
    /// UI shows something rather than an empty row.
    func testDisplayNameKeepsLeadingSemicolonNameRaw() {
        XCTAssertEqual(";internal".novaDisplayName, ";internal")
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
