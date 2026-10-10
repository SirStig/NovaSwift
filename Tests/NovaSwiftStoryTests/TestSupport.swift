import Foundation
import NovaSwiftKit
@testable import NovaSwiftStory

// Builders that synthesise real-layout mïsn / crön / shïp / dësc resource bytes,
// so the engine can be exercised without shipping any copyrighted game data. The
// byte offsets here are the same ones the decoders read — the builders therefore
// double as a round-trip check of the decoder.

enum Bytes {
    static func i16(_ buf: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        buf[off] = UInt8(u >> 8); buf[off + 1] = UInt8(u & 0xFF)
    }
    static func i32(_ buf: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        buf[off] = UInt8(u >> 24); buf[off + 1] = UInt8((u >> 16) & 0xFF)
        buf[off + 2] = UInt8((u >> 8) & 0xFF); buf[off + 3] = UInt8(u & 0xFF)
    }
    static func cstr(_ buf: inout [UInt8], _ off: Int, _ s: String) {
        let bytes = Array(s.data(using: .macOSRoman) ?? Data())
        for (i, b) in bytes.enumerated() { buf[off + i] = b }
        // remainder already zero (NUL terminator)
    }
}

struct MissionSpec {
    var id: Int
    var name = "Test Mission"
    var availStellar = -1
    var availLocation = 0        // mission computer
    var availRecord = 0
    var availRating = 0
    var availRandom = 100
    var availShipType = -1
    var travelStellar = -1
    var returnStellar = -1
    var cargoType = 0
    var cargoQty = 0
    var cargoPickup = -1
    var cargoDropoff = -1
    var pay = 0
    var shipCount = 0
    var shipGoal = -1
    var shipSystem = -1
    var shipDude = -1
    var shipNameStrID = -1
    var shipSubtitleStrID = -1
    var auxShipCount = 0
    var auxShipDude = -1
    var auxShipSystem = -1
    var quickBriefText = -1
    var offerAcceptButton = ""
    var offerRefuseButton = ""
    var displayWeight = 0
    var compRewardGovt = -1
    var compLegalReward = 0
    var timeLimit = -1
    var canAbort = true
    var flags1 = 0
    var flags2 = 0
    var datePostIncrement = 0
    var completionText = -1
    var loadCargoText = -1
    var dropCargoText = -1
    var shipDoneText = -1
    var briefText = -1
    var availBits = ""
    var onAccept = ""
    var onRefuse = ""
    var onSuccess = ""
    var onFailure = ""
    var onAbort = ""
    var onShipDone = ""

    func resource() -> Resource {
        var b = [UInt8](repeating: 0, count: 1970)
        Bytes.i16(&b, 0, availStellar)
        Bytes.i16(&b, 4, availLocation)
        Bytes.i16(&b, 6, availRecord)
        Bytes.i16(&b, 8, availRating)
        Bytes.i16(&b, 10, availRandom)
        Bytes.i16(&b, 12, travelStellar)
        Bytes.i16(&b, 14, returnStellar)
        Bytes.i16(&b, 16, cargoType)
        Bytes.i16(&b, 18, cargoQty)
        Bytes.i16(&b, 20, cargoPickup)
        Bytes.i16(&b, 22, cargoDropoff)
        Bytes.i32(&b, 28, pay)
        Bytes.i16(&b, 32, shipCount)
        Bytes.i16(&b, 34, shipSystem)
        Bytes.i16(&b, 36, shipDude)
        Bytes.i16(&b, 38, shipGoal)
        Bytes.i16(&b, 42, shipNameStrID)
        Bytes.i16(&b, 50, shipSubtitleStrID)
        Bytes.i16(&b, 54, quickBriefText)
        Bytes.i16(&b, 72, auxShipCount)
        Bytes.i16(&b, 74, auxShipDude)
        Bytes.i16(&b, 76, auxShipSystem)
        Bytes.cstr(&b, 1887, offerAcceptButton)
        Bytes.cstr(&b, 1919, offerRefuseButton)
        Bytes.i16(&b, 1952, displayWeight)
        Bytes.i16(&b, 46, compRewardGovt)
        Bytes.i16(&b, 48, compLegalReward)
        Bytes.i16(&b, 52, briefText)
        Bytes.i16(&b, 56, loadCargoText)
        Bytes.i16(&b, 58, dropCargoText)
        Bytes.i16(&b, 60, completionText)
        Bytes.i16(&b, 68, shipDoneText)
        Bytes.i16(&b, 64, timeLimit)
        Bytes.i16(&b, 66, canAbort ? 1 : 0)
        Bytes.i16(&b, 80, flags1)
        Bytes.i16(&b, 82, flags2)
        Bytes.i16(&b, 90, availShipType)
        Bytes.cstr(&b, 92, availBits)
        Bytes.cstr(&b, 347, onAccept)
        Bytes.cstr(&b, 602, onRefuse)
        Bytes.cstr(&b, 857, onSuccess)
        Bytes.cstr(&b, 1112, onFailure)
        Bytes.cstr(&b, 1367, onAbort)
        Bytes.i16(&b, 1630, datePostIncrement)
        Bytes.cstr(&b, 1632, onShipDone)
        return Resource(type: NovaType.mission, id: id, name: name, data: Data(b))
    }
}

struct CronSpec {
    var id: Int
    var name = "Test Cron"
    var firstDay = 0, firstMonth = 0, firstYear = 0
    var lastDay = 0, lastMonth = 0, lastYear = 0
    var random = 100
    var duration = 0
    var preHoldoff = 0
    var postHoldoff = 0
    var flags = 0
    var enableOn = ""
    var onStart = ""
    var onEnd = ""
    var independentNews = -1
    var newsGovts: [Int] = []
    var govtNewsStrs: [Int] = []

    func resource() -> Resource {
        var b = [UInt8](repeating: 0, count: 822)
        Bytes.i16(&b, 20, independentNews)
        for i in 0..<4 {
            Bytes.i16(&b, 806 + i * 2, i < newsGovts.count ? newsGovts[i] : -1)
            Bytes.i16(&b, 814 + i * 2, i < govtNewsStrs.count ? govtNewsStrs[i] : -1)
        }
        Bytes.i16(&b, 0, firstDay)
        Bytes.i16(&b, 2, firstMonth)
        Bytes.i16(&b, 4, firstYear)
        Bytes.i16(&b, 6, lastDay)
        Bytes.i16(&b, 8, lastMonth)
        Bytes.i16(&b, 10, lastYear)
        Bytes.i16(&b, 12, random)
        Bytes.i16(&b, 14, duration)
        Bytes.i16(&b, 16, preHoldoff)
        Bytes.i16(&b, 18, postHoldoff)
        Bytes.i16(&b, 22, flags)
        Bytes.cstr(&b, 24, enableOn)
        Bytes.cstr(&b, 279, onStart)
        Bytes.cstr(&b, 534, onEnd)
        return Resource(type: NovaType.cron, id: id, name: name, data: Data(b))
    }
}

/// A minimal ship resource so cargo-space / ship lookups resolve.
func shipResource(id: Int, cargo: Int) -> Resource {
    var b = [UInt8](repeating: 0, count: 128)
    Bytes.i16(&b, 0, cargo)
    return Resource(type: NovaType.ship, id: id, name: "Ship \(id)", data: Data(b))
}

/// A `sÿst` owned by `govt` (−1 independent) at map position (`x`, `y`) with
/// declared `links` — enough for the per-system legal record (EC-02).
func ownedSystemResource(id: Int, govt: Int, links: [Int] = [], x: Int? = nil, y: Int = 0) -> Resource {
    var b = [UInt8](repeating: 0, count: 420)
    Bytes.i16(&b, 0, x ?? id)
    Bytes.i16(&b, 2, y)
    for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, i < links.count ? links[i] : -1) }
    Bytes.i16(&b, 102, govt)
    return Resource(type: NovaType.syst, id: id, name: "Sys \(id)", data: Data(b))
}

/// A spob with a government and landing pict, so stellar matching resolves.
func spobResource(id: Int, govt: Int) -> Resource {
    var b = [UInt8](repeating: 0, count: 40)
    Bytes.i16(&b, 20, govt)
    Bytes.i16(&b, 24, 1000)   // landingPictID > 0 → "inhabited"
    return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
}

/// A landable spöb (Flags 0x0001, plus `flags`) at a map position, so the
/// original's random-destination rules accept it.
func landableSpob(id: Int, govt: Int, x: Int = 0, y: Int = 0, flags: Int = 0) -> Resource {
    var b = [UInt8](repeating: 0, count: 40)
    Bytes.i16(&b, 0, x)
    Bytes.i16(&b, 2, y)
    Bytes.i32(&b, 6, 0x0001 | flags)
    Bytes.i16(&b, 20, govt)
    Bytes.i16(&b, 24, 1000)
    return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
}

/// A sÿst at a map position with links, stellars, a government and an
/// optional NCB visibility test.
func systemResource(id: Int, x: Int? = nil, y: Int = 0, links: [Int] = [], spobs: [Int] = [],
                    govt: Int = -1, visibility: String = "") -> Resource {
    var b = [UInt8](repeating: 0, count: 500)
    Bytes.i16(&b, 0, x ?? id * 10)
    Bytes.i16(&b, 2, y)
    for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, i < links.count ? links[i] : -1) }
    for i in 0..<16 { Bytes.i16(&b, 36 + i * 2, i < spobs.count ? spobs[i] : -1) }
    Bytes.i16(&b, 102, govt)
    Bytes.cstr(&b, 150, visibility)
    return Resource(type: NovaType.syst, id: id, name: "System \(id)", data: Data(b))
}

/// A government with class, ally and enemy slots (@24/@32/@40) and Flags1
/// (@2); unused slots are -1.
func govtResource(id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [], flags: Int = 0) -> Resource {
    var b = [UInt8](repeating: 0, count: 176)
    Bytes.i16(&b, 2, flags)
    for i in 0..<4 { Bytes.i16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1) }
    for i in 0..<4 { Bytes.i16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1) }
    for i in 0..<4 { Bytes.i16(&b, 40 + i * 2, i < enemies.count ? enemies[i] : -1) }
    return Resource(type: NovaType.govt, id: id, name: "Govt \(id)", data: Data(b))
}

/// A STR# resource from a list of strings.
func stringListResource(_ id: Int, _ items: [String]) -> Resource {
    var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xff)]
    for s in items {
        let bytes = Array(s.data(using: .macOSRoman) ?? Data())
        b.append(UInt8(bytes.count)); b += bytes
    }
    return Resource(type: NovaType.strList, id: id, name: "STR#\(id)", data: Data(b))
}

/// A ränk: weight @0, govt @2, salary @6, flags @22.
func rankResource(id: Int, govt: Int = 128, weight: Int = 0, salary: Int = 0, flags: Int = 0) -> Resource {
    var b = [UInt8](repeating: 0, count: 152)
    Bytes.i16(&b, 0, weight)
    Bytes.i16(&b, 2, govt)
    Bytes.i32(&b, 6, salary)
    Bytes.i16(&b, 22, flags)
    return Resource(type: NovaType.rank, id: id, name: "Rank \(id)", data: Data(b))
}

/// An IFF outfit (ModType 14).
func iffOutfit(id: Int) -> Resource {
    var b = [UInt8](repeating: 0, count: 1012)
    for pos in [6, 18, 22, 26] { Bytes.i16(&b, pos, -1) }
    Bytes.i16(&b, 6, 14)
    Bytes.i16(&b, 8, 1)
    return Resource(type: NovaType.outfit, id: id, name: "IFF", data: Data(b))
}

/// A government with a real `mapColor` (LCOL, `0x00RRGGBB` @164) so palette /
/// territory-color logic can be tested without a black (unset) fallback.
func govtResource(id: Int, name: String = "Test Govt", mapColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)) -> Resource {
    var b = [UInt8](repeating: 0, count: 176)
    b[164] = 0
    b[165] = mapColor.r
    b[166] = mapColor.g
    b[167] = mapColor.b
    return Resource(type: NovaType.govt, id: id, name: name, data: Data(b))
}

/// A `dësc` resource whose narrative body is a plain string (stored as a C
/// string from offset 0, matching `DescRes`). Used to give mission text ids
/// (completion / ship-done / load-cargo / drop-cargo) real bodies in tests.
func descResource(id: Int, text: String) -> Resource {
    let bytes = Array((text.data(using: .macOSRoman) ?? Data())) + [0]
    return Resource(type: NovaType.desc, id: id, name: "Desc \(id)", data: Data(bytes))
}

/// Build a NovaGame from a set of resources.
func makeGame(_ resources: [Resource]) -> NovaGame {
    var col = ResourceCollection()
    for r in resources { col.add(r) }
    return NovaGame(col)
}

/// A ship with preinstalled `DefaultItems` (`shïp` slots @78/@86 — ids and
/// counts) on top of the plain `shipResource` above, plus a real `FreeMass` so
/// outfit-mass accounting has room to work with.
func shipResource(id: Int, cargo: Int, freeMass: Int,
                  defaultItems: [(id: Int, count: Int)] = [],
                  stockWeapons: [(id: Int, count: Int, ammo: Int)] = [],
                  maxGuns: Int = 4, maxTurrets: Int = 4) -> Resource {
    var b = [UInt8](repeating: 0, count: 1860)
    Bytes.i16(&b, 0, cargo)
    Bytes.i16(&b, 12, freeMass)
    Bytes.i16(&b, 42, maxGuns)
    Bytes.i16(&b, 44, maxTurrets)
    // WeapType/WeapCount/AmmoLoad @18/@26/@34 — the hull's stock armament.
    for i in 0..<4 { Bytes.i16(&b, 18 + i * 2, -1) }
    for (i, w) in stockWeapons.prefix(4).enumerated() {
        Bytes.i16(&b, 18 + i * 2, w.id)
        Bytes.i16(&b, 26 + i * 2, w.count)
        Bytes.i16(&b, 34 + i * 2, w.ammo)
    }
    for i in 0..<4 { Bytes.i16(&b, 1742 + i * 2, -1) }
    // DefaultItems/ItemCount @78/@86.
    for i in 0..<4 { Bytes.i16(&b, 78 + i * 2, -1) }
    for (i, item) in defaultItems.prefix(4).enumerated() {
        Bytes.i16(&b, 78 + i * 2, item.id)
        Bytes.i16(&b, 86 + i * 2, item.count)
    }
    for i in 0..<4 { Bytes.i16(&b, 880 + i * 2, -1) }
    return Resource(type: NovaType.ship, id: id, name: "Ship \(id)", data: Data(b))
}

/// A `wëap` just real enough for `Loadout` to mount it.
func weaponResource(id: Int, name: String) -> Resource {
    var b = [UInt8](repeating: 0, count: 400)
    Bytes.i16(&b, 0, 60)      // reload
    Bytes.i16(&b, 2, 300)     // duration/lifetime
    Bytes.i16(&b, 4, 10)      // mass damage
    Bytes.i16(&b, 6, 10)      // energy damage
    Bytes.i16(&b, 8, 500)     // speed
    return Resource(type: NovaType.weapon, id: id, name: name, data: Data(b))
}

/// An `oütf` with a mass and cost, and optionally the "Outfitter Name" string
/// (@811) the shop grid draws.
func outfitResource(id: Int, name: String, mass: Int = 0, cost: Int = 0,
                    outfitterName: String = "",
                    installsWeapon: Int? = nil, ammoFor: Int? = nil,
                    isFixedGun: Bool = false) -> Resource {
    var b = [UInt8](repeating: 0, count: 1012)
    Bytes.i16(&b, 2, mass)
    Bytes.i32(&b, 14, cost)
    for pos in [6, 18, 22, 26] { Bytes.i16(&b, pos, -1) }   // no modifiers
    if let installsWeapon {                                 // ModType 1
        Bytes.i16(&b, 6, 1); Bytes.i16(&b, 8, installsWeapon)
    } else if let ammoFor {                                 // ModType 3
        Bytes.i16(&b, 6, 3); Bytes.i16(&b, 8, ammoFor)
    }
    if isFixedGun { Bytes.i16(&b, 12, 0x0001) }             // Flags: fixed gun
    Bytes.cstr(&b, 811, outfitterName)
    return Resource(type: NovaType.outfit, id: id, name: name, data: Data(b))
}
