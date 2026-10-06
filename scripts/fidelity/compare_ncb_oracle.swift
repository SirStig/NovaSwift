import Foundation
struct OracleCase: Decodable {
 let mission: Int?
 let expression: String
 let bits: [Int]
 let atom: Bool
 let result: Bool
}
struct OracleContext: NCBTestContext {
 let bits: Set<Int>
 let atom: Bool
 func isBitSet(_ n: Int) -> Bool { bits.contains(n) }
 func hasOutfit(_ id: Int) -> Bool { atom }
 func isSystemExplored(_ id: Int) -> Bool { atom }
 var playerIsMale: Bool { atom }
 var unregisteredDays: Int { atom ? 0 : 1 }
}
@main
struct NCBOracleComparison {
    static func main() throws {
        var count = 0
        var failures = 0
        for path in CommandLine.arguments.dropFirst() {
         let cases = try JSONDecoder().decode([OracleCase].self, from: Data(contentsOf: URL(fileURLWithPath:path)))
         for test in cases {
          count += 1
          let actual = NCBTest(test.expression).evaluate(OracleContext(bits: Set(test.bits), atom: test.atom))
          if actual != test.result {
           failures += 1
           if failures <= 20 { print("MISMATCH mission=\(String(describing:test.mission)) bits=\(test.bits) atom=\(test.atom) expression=\(test.expression) x86=\(test.result) Swift=\(actual)") }
          }
         }
        }
        print("Compared \(count) cases: \(failures) mismatches.")
        if failures != 0 { exit(1) }
    }
}
