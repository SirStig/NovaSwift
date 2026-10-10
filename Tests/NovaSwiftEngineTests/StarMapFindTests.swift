import XCTest
@testable import NovaSwiftEngine

/// S-8: the original Find's matching rules (0x004aab30).
final class StarMapFindTests: XCTestCase {
    func testFindNormalisesAndPrefersTheLongestPrefix() {
        let systems = [(id: 1, name: "New Ireland"), (id: 2, name: "New Kansas"), (id: 3, name: "Sol")]
        XCTAssertEqual(StarMapFind.find("new-ireland", in: systems), 1)
        XCTAssertEqual(StarMapFind.find("New K", in: systems), 2)
        XCTAssertEqual(StarMapFind.find("s", in: systems), 3, "a single unique one-letter match")
        XCTAssertNil(StarMapFind.find("n", in: systems), "one letter, two matches: beep")
        XCTAssertNil(StarMapFind.find("xyz", in: systems))
        XCTAssertEqual(StarMapFind.find("new", in: systems), 2, "a tie goes to the shorter name")
    }
}
