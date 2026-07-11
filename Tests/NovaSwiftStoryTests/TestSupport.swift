import Foundation
import EVNovaKit
@testable import EVNovaStory

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
    var compRewardGovt = -1
    var compLegalReward = 0
    var timeLimit = -1
    var canAbort = true
    var flags1 = 0
    var flags2 = 0
    var datePostIncrement = 0
    var completionText = -1
    var briefText = -1
    var availBits = ""
    var onAccept = ""
    var onRefuse = ""
    var onSuccess = ""
    var onFailure = ""
    var onAbort = ""

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
        Bytes.i16(&b, 38, shipGoal)
        Bytes.i16(&b, 46, compRewardGovt)
        Bytes.i16(&b, 48, compLegalReward)
        Bytes.i16(&b, 52, briefText)
        Bytes.i16(&b, 60, completionText)
        Bytes.i16(&b, 64, timeLimit)
        Bytes.i16(&b, 66, canAbort ? 1 : 0)
        Bytes.i16(&b, 78, flags1)
        Bytes.i16(&b, 80, flags2)
        Bytes.i16(&b, 88, availShipType)
        Bytes.cstr(&b, 92, availBits)
        Bytes.cstr(&b, 347, onAccept)
        Bytes.cstr(&b, 602, onRefuse)
        Bytes.cstr(&b, 857, onSuccess)
        Bytes.cstr(&b, 1112, onFailure)
        Bytes.cstr(&b, 1367, onAbort)
        Bytes.i16(&b, 1630, datePostIncrement)
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

    func resource() -> Resource {
        var b = [UInt8](repeating: 0, count: 822)
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

/// A spob with a government and landing pict, so stellar matching resolves.
func spobResource(id: Int, govt: Int) -> Resource {
    var b = [UInt8](repeating: 0, count: 40)
    Bytes.i16(&b, 20, govt)
    Bytes.i16(&b, 24, 1000)   // landingPictID > 0 → "inhabited"
    return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
}

/// Build a NovaGame from a set of resources.
func makeGame(_ resources: [Resource]) -> NovaGame {
    var col = ResourceCollection()
    for r in resources { col.add(r) }
    return NovaGame(col)
}
