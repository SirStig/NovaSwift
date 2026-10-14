import XCTest
@testable import NovaSwiftKit

final class PluginGameplayTests: XCTestCase {
    private func gameplay(_ name: String) -> Bool {
        let code: NovaSwiftKit.FourCharCode = NovaSwiftKit.FourCharCode(name)!
        return PluginGameplay.isGameplay(type: code)
    }

    func testGameplayVersusCosmeticTypes() {
        let play = ["shïp", "oütf", "wëap", "sÿst", "spöb", "gövt", "mïsn", "crön", "përs", "düde", "flët", "chär", "ränk", "jünk", "öops", "röid", "nëbu"]
        let cosmetic = ["PICT", "rlë8", "rlëD", "spïn", "cicn", "snd ", "STR#", "dësc", "shän", "bööm", "cölr", "ïntf"]
        XCTAssertEqual(play.filter { !gameplay($0) }, [])
        XCTAssertEqual(cosmetic.filter { gameplay($0) }, [])
    }

    func testUnknownTypesCountAsGameplay() {
        XCTAssertTrue(gameplay("zzzz"))
    }
}
