import Foundation
import NovaSwiftKit
import NovaSwiftEngine

struct ArmorCapture: Decodable { let value: Double }
struct PersonCase: Decodable {
    let id: Int
    let name: String
    let raw_shield_mod: Int
    let synthetic_armor_base: Int
    let oracle_armor: ArmorCapture
}
struct Report: Decodable { let persons: [PersonCase] }

func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
    let raw = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
    bytes[offset] = UInt8(raw >> 8)
    bytes[offset + 1] = UInt8(raw & 255)
}

@main
struct ComparePersonArmor {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: compare-person-armor <person-resource-armor.json>")
            exit(2)
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard !report.persons.isEmpty else {
            print("No person cases to compare.")
            exit(2)
        }
        var failures = 0
        for sample in report.persons {
            var resources = ResourceCollection()
            var hull = [UInt8](repeating: 0, count: 2000)
            put16(&hull, 2, 100)
            put16(&hull, 14, sample.synthetic_armor_base)
            resources.add(Resource(type: NovaType.ship, id: 128, name: "Hull", data: Data(hull)))
            var person = [UInt8](repeating: 0, count: 400)
            put16(&person, 2, -1)
            put16(&person, 4, 1)
            put16(&person, 10, 128)
            put16(&person, 40, sample.raw_shield_mod)
            resources.add(Resource(type: NovaType.pers, id: 500, name: sample.name, data: Data(person)))
            var system = [UInt8](repeating: 0, count: 2000)
            put16(&system, 110, 500)
            resources.add(Resource(type: NovaType.syst, id: 128, name: "System", data: Data(system)))
            let galaxy = Galaxy(game: NovaGame(resources))
            let world = World(player: Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: galaxy.game.system(128)!))
            spawner.populate(world)
            let actual = world.npcs.first { $0.personID == 500 }!.maxArmor
            if Float(actual).bitPattern != Float(sample.oracle_armor.value).bitPattern {
                failures += 1
                if failures <= 10 { print("MISMATCH person=\(sample.id) modifier=\(sample.raw_shield_mod) native=\(actual) x86-f32=\(sample.oracle_armor.value)") }
            }
        }
        print("Compared \(report.persons.count) original Float32 armor captures to native pinned-person spawns: \(failures) mismatches.")
        if failures != 0 { exit(1) }
    }
}
