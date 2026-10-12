import XCTest
@testable import NovaSwiftKit

/// Schema integrity (always runs) and schema-vs-decoder agreement on the real
/// base data under `data/base` (skipped when the user-supplied game data isn't
/// present). The real-data tests are the spec for the field layouts: every
/// schema field must read what the typed decoders read, and reading then
/// writing every field must reproduce the record byte for byte.
final class EditingSchemaTests: XCTestCase {

    // MARK: Integrity

    func testEveryGameTypeHasASchemaOrSpecialEditor() {
        let expected = ["shïp", "oütf", "wëap", "spöb", "sÿst", "gövt", "dësc", "mïsn", "crön", "përs", "düde",
                        "flët", "chär", "bööm", "spïn", "shän", "jünk", "öops", "nëbu", "ränk", "röid", "ïntf", "cölr"]
        for code in expected {
            let t = FourCharCode(code)!
            XCTAssertNotNil(ResourceSchemas.schema(for: t), "no schema for \(code)")
        }
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.strList), .text)
        XCTAssertEqual(ResourceSchemas.editorKind(for: FourCharCode("STR ")!), .text)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.pict), .graphic)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.rleD), .graphic)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.rle8), .graphic)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.cicn), .graphic)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.snd), .sound)
        XCTAssertEqual(ResourceSchemas.editorKind(for: NovaType.ship), .form)
        XCTAssertEqual(ResourceSchemas.editorKind(for: FourCharCode("zzzz")!), .raw)
    }

    func testSchemasAreInternallyConsistent() {
        for s in ResourceSchemas.all {
            XCTAssertGreaterThanOrEqual(s.minimumSize, NovaType.minimumRecordSize[s.type] ?? 0, "\(s.displayName) min size")
            XCTAssertLessThanOrEqual(s.declaredExtent, s.minimumSize, "\(s.displayName) fields run past its record")
            var keys = Set<String>()
            for f in s.fields {
                XCTAssertTrue(keys.insert(f.key).inserted, "\(s.displayName): duplicate key \(f.key)")
                XCTAssertFalse(f.label.isEmpty)
                XCTAssertFalse(f.group.isEmpty)
            }
            // Byte ownership: only bit-slices of one container may share bytes.
            var owner: [Int: String] = [:]
            for f in s.fields {
                var isSlice = false
                if case .bits = f.kind { isSlice = true }
                for i in 0..<f.count {
                    for b in 0..<f.kind.byteSize {
                        let at = f.offset + i * f.stride + b
                        if let other = owner[at], !isSlice {
                            XCTFail("\(s.displayName): \(f.key) overlaps \(other) at byte \(at)")
                        }
                        if !isSlice { owner[at] = f.key }
                    }
                }
            }
        }
    }

    func testDefaultsAreWellFormedAndRoundTrip() {
        for s in ResourceSchemas.all {
            let blank = s.makeDefault()
            XCTAssertEqual(blank.count, s.minimumSize, s.displayName)
            var copy = blank
            for f in s.fields { FieldCodec.write(FieldCodec.read(f, from: blank), field: f, into: &copy) }
            XCTAssertEqual(copy, blank, "\(s.displayName) default doesn't round-trip")
        }
    }

    func testFieldCodecPrimitives() {
        var d = Data(count: 16)
        FieldCodec.writeUInt(&d, 0, 2, 0xFFFE)
        XCTAssertEqual(FieldCodec.readInt(d, 0, 2, signed: true), -2)
        XCTAssertEqual(FieldCodec.readInt(d, 0, 2, signed: false), 0xFFFE)
        FieldCodec.writeUInt(&d, 4, 4, UInt64(bitPattern: -50_000))
        XCTAssertEqual(FieldCodec.readInt(d, 4, 4, signed: true), -50_000)

        // Bit slices share a container and don't disturb neighbours.
        var flags = Data([0x12, 0x34, 0x56, 0x78])
        let food = FieldKind.bits(.w32, shift: 28, width: 4)
        XCTAssertEqual(FieldCodec.readElement(food, from: flags, at: 0), .int(1))
        FieldCodec.writeElement(.int(4), kind: food, into: &flags, at: 0)
        XCTAssertEqual(flags, Data([0x42, 0x34, 0x56, 0x78]))

        // Strings: only owned bytes change; garbage after the NUL survives.
        var s = Data([0x41, 0x42, 0x00, 0x99, 0x99, 0x99])
        FieldCodec.writeElement(.string("ABC"), kind: .cString(6), into: &s, at: 0)
        XCTAssertEqual(s, Data([0x41, 0x42, 0x43, 0x00, 0x99, 0x99]))
        FieldCodec.writeElement(.string("A"), kind: .cString(6), into: &s, at: 0)
        XCTAssertEqual(Array(s.prefix(4)), [0x41, 0x00, 0x00, 0x00])
        // Overlong text is clipped to leave room for the terminator.
        FieldCodec.writeElement(.string("HELLOWORLD"), kind: .cString(4), into: &s, at: 0)
        XCTAssertEqual(FieldCodec.readCString(s, 0, 4), "HEL")

        // Mac Roman text and colours keep their high byte.
        var m = Data(count: 16)
        FieldCodec.writeElement(.string("Mïsn"), kind: .cString(8), into: &m, at: 0)
        XCTAssertEqual(m[1], 0x95)
        XCTAssertEqual(FieldCodec.readElement(.cString(8), from: m, at: 0), .string("Mïsn"))
        var c = Data([0xAB, 1, 2, 3])
        FieldCodec.writeElement(.color(r: 9, g: 8, b: 7), kind: .color, into: &c, at: 0)
        XCTAssertEqual(c, Data([0xAB, 9, 8, 7]))

        // Reads past the end are zeros; writes grow the record.
        XCTAssertEqual(FieldCodec.readInt(Data([1]), 0, 4, signed: true), 0x01000000)
        var short = Data()
        FieldCodec.writeElement(.int(7), kind: .i16, into: &short, at: 10)
        XCTAssertEqual(short.count, 12)
    }

    func testRangeEncodedReferences() throws {
        let m = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.mission))
        let f = try XCTUnwrap(m.field("availStel"))
        // 10005 = stellar of govt (10005 - 10000 + 128) = govt 133
        let r = try XCTUnwrap(f.reference(for: 10005))
        XCTAssertEqual(r.type, NovaType.govt); XCTAssertEqual(r.id, 133)
        XCTAssertEqual(f.reference(for: 250)?.type, NovaType.spob)
        XCTAssertNil(f.reference(for: -1))        // "any inhabited stellar"
        // Descending range: sÿst dude slot -130 = flët 130.
        let sy = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.syst))
        let dt = try XCTUnwrap(sy.field("dudeTypes"))
        let fl = try XCTUnwrap(dt.reference(for: -130))
        XCTAssertEqual(fl.type, NovaType.fleet); XCTAssertEqual(fl.id, 130)
        XCTAssertEqual(dt.reference(for: 140)?.type, NovaType.dude)
        // Index-style ref: bööm sound 0 → snd 300.
        let b = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.boom)?.field("soundIndex"))
        XCTAssertEqual(b.reference(for: 0)?.id, 300)
        XCTAssertNil(b.reference(for: -1))
        // Option round trip.
        let opt = try XCTUnwrap(f.option(for: 10005))
        XCTAssertEqual(opt.value(forPayload: opt.payload(for: 10005)), 10005)
    }

    func testOutfitModValueIsContextual() throws {
        let o = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.outfit))
        var d = o.makeDefault()
        o.write(.int(1), key: "modType", into: &d)      // weapon
        o.write(.int(133), key: "modValue", into: &d)
        let r = Resource(type: NovaType.outfit, id: 130, data: d)
        let refs = ResourceReferences.references(of: r)
        XCTAssertTrue(refs.contains { $0.target == ResourceKey(NovaType.weapon, 133) })
        o.write(.int(2), key: "modType", into: &d)      // cargo space: plain number
        let r2 = Resource(type: NovaType.outfit, id: 130, data: d)
        XCTAssertFalse(ResourceReferences.references(of: r2).contains { $0.target.type == NovaType.weapon })
    }

    // MARK: Real data

    private func stockCollection() throws -> ResourceCollection {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = repo.appendingPathComponent("data/base")
        let files = GameLibrary.discoverResourceFiles(in: base)
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return try GameLibrary.merge(baseFiles: files)
    }

    private func c(_ x: NovaColor) -> FieldValue { .color(r: x.r, g: x.g, b: x.b) }
    private func i(_ x: Int) -> FieldValue { .int(x) }
    private func ints(_ x: [Int]) -> FieldValue { .array(x.map(FieldValue.int)) }

    /// Reads every stock resource of `type` through both the schema and the
    /// typed decoder and requires the named fields to agree.
    private func verify<T>(_ type: NovaSwiftKit.FourCharCode, in coll: ResourceCollection,
                           decode: (Resource) -> T, _ pairs: [(String, (T) -> FieldValue)],
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try XCTUnwrap(ResourceSchemas.schema(for: type), file: file, line: line)
        let all = coll.resources(of: type)
        XCTAssertFalse(all.isEmpty, "no \(schema.displayName) in stock data", file: file, line: line)
        var bad: [String] = []
        for r in all {
            let model = decode(r)
            for (key, expect) in pairs {
                guard let f = schema.field(key) else { XCTFail("schema \(schema.displayName) has no field \(key)", file: file, line: line); continue }
                let got = FieldCodec.read(f, from: r.data)
                let want = expect(model)
                if got != want, bad.count < 8 { bad.append("\(schema.displayName) #\(r.id) \(key): schema=\(got) decoder=\(want)") }
            }
        }
        XCTAssertTrue(bad.isEmpty, bad.joined(separator: "\n"), file: file, line: line)
    }

    func testSchemaAgreesWithTypedDecoders() throws {
        let coll = try stockCollection()
        try verify(NovaType.ship, in: coll, decode: ShipRes.init, [
            ("cargoSpace", { self.i($0.cargoSpace) }), ("shield", { self.i($0.shield) }),
            ("acceleration", { self.i($0.acceleration) }), ("speed", { self.i($0.speed) }),
            ("turnRate", { self.i($0.turnRate) }), ("fuel", { self.i($0.fuelCapacity) }),
            ("freeMass", { self.i($0.freeMass) }), ("armor", { self.i($0.armor) }),
            ("shieldRecharge", { self.i($0.shieldRecharge) }), ("maxGuns", { self.i($0.maxGuns) }),
            ("maxTurrets", { self.i($0.maxTurrets) }), ("techLevel", { self.i($0.techLevel) }),
            ("dispWeight", { self.i($0.displayWeight) }), ("cost", { self.i($0.cost) }),
            ("deathDelay", { self.i($0.deathDelay) }), ("armorRecharge", { self.i($0.armorRecharge) }),
            ("mass", { self.i($0.mass) }), ("length", { self.i($0.length) }), ("inherentAI", { self.i($0.inherentAI) }),
            ("crew", { self.i($0.crew) }), ("strength", { self.i($0.strength) }),
            ("inherentGovt", { self.i($0.inherentGovt) }), ("flags", { self.i(Int($0.flags)) }),
            ("podCount", { self.i($0.podCount) }), ("fuelRegen", { self.i($0.fuelRegen) }),
            ("flags2", { self.i(Int($0.flags2)) }), ("deionize", { self.i($0.deionize) }),
            ("ionizeMax", { self.i($0.ionizeMax) }), ("keyCarried", { self.i($0.keyCarriedShipID) }),
            ("contribute", { .uint64($0.contribute) }), ("require", { .uint64($0.require) }),
            ("availability", { .string($0.availBits) }), ("appearOn", { .string($0.appearOn) }),
            ("onPurchase", { .string($0.onPurchase) }), ("onCapture", { .string($0.onCapture) }),
            ("onRetire", { .string($0.onRetire) }), ("subtitle", { .string($0.subtitle) }),
            ("flags3", { self.i(Int($0.flags3)) }), ("upgradeTo", { self.i($0.escortUpgradesTo) }),
            ("upgradeCost", { self.i($0.escortUpgradeCost) }), ("sellValue", { self.i($0.escortSellValue) }),
            ("escortType", { self.i($0.escortCategory) }),
        ])
        // Stock weapon/outfit tables (the decoder drops unused slots; compare the used ones).
        let shipSchema = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.ship))
        for r in coll.resources(of: NovaType.ship) {
            let m = ShipRes(r)
            var fromSchema: [(Int, Int, Int)] = []
            for (t, cnt, am) in [("weaponTypes", "weaponCounts", "ammoLoads"), ("weaponTypes2", "weaponCounts2", "ammoLoads2")] {
                guard case let .array(ts) = shipSchema.read(t, from: r.data)!, case let .array(cs) = shipSchema.read(cnt, from: r.data)!,
                      case let .array(ams) = shipSchema.read(am, from: r.data)! else { return XCTFail() }
                for k in 0..<4 where (ts[k].intValue ?? 0) >= 128 { fromSchema.append((ts[k].intValue!, cs[k].intValue!, ams[k].intValue!)) }
            }
            XCTAssertEqual(fromSchema.map { "\($0.0),\($0.1),\($0.2)" }, m.weapons.map { "\($0.id),\($0.count),\($0.ammo)" }, "ship #\(r.id) weapons")
        }

        try verify(NovaType.outfit, in: coll, decode: OutfRes.init, [
            ("dispWeight", { self.i($0.displayWeight) }), ("mass", { self.i($0.mass) }), ("techLevel", { self.i($0.techLevel) }),
            ("maximum", { self.i($0.maxInstallable) }), ("cost", { self.i($0.cost) }), ("flags", { self.i(Int($0.flags)) }),
            ("modType", { self.i($0.firstSlot.type) }), ("modValue", { self.i($0.firstSlot.value) }),
            ("contribute", { .uint64($0.contribute) }), ("require", { .uint64($0.require) }),
            ("availability", { .string($0.availBits) }), ("onPurchase", { .string($0.onPurchase) }),
            ("onSell", { .string($0.onSell) }), ("shortName", { .string($0.outfitterName) }),
            ("lowercaseName", { .string($0.lowercaseName) }), ("lowercasePlural", { .string($0.lowercasePlural) }),
            ("itemClass", { self.i($0.itemClass) }), ("scanMask", { self.i(Int($0.scanMask)) }),
            ("requireGovt", { self.i($0.requireGovt) }),
        ])

        try verify(NovaType.weapon, in: coll, decode: WeapRes.init, [
            ("reload", { self.i($0.reload) }), ("duration", { self.i($0.duration) }),
            ("massDamage", { self.i($0.armorDamage) }), ("energyDamage", { self.i($0.shieldDamage) }),
            ("guidance", { self.i($0.guidanceRaw) }), ("speed", { self.i($0.speed) }), ("ammoType", { self.i($0.ammoType) }),
            ("impact", { self.i($0.impact) }), ("proxRadius", { self.i($0.proxRadius) }), ("blastRadius", { self.i($0.blastRadius) }),
            ("flags", { self.i(Int($0.flagsRaw)) }), ("seekerFlags", { self.i($0.seekerFlagsRaw) }),
            ("smokeSet", { self.i($0.smokeSet) }), ("decay", { self.i($0.decay) }),
            ("beamLength", { self.i($0.beamLength) }), ("beamWidth", { self.i($0.beamWidth) }),
            ("coronaFalloff", { self.i($0.coronaFalloff) }), ("beamColor", { self.c($0.beamColor) }),
            ("coronaColor", { self.c($0.coronaColor) }), ("subCount", { self.i($0.subCount) }), ("subType", { self.i($0.subID) }),
            ("subTheta", { self.i($0.subTheta) }), ("subLimit", { self.i($0.subLimit) }), ("proxSafety", { self.i($0.proxSafety) }),
            ("flags2", { self.i(Int($0.flags2Raw)) }), ("ionization", { self.i($0.ionization) }),
            ("exitType", { self.i($0.exitType) }), ("burstCount", { self.i($0.burstCount) }),
            ("burstReload", { self.i($0.burstReload) }), ("flags3", { self.i(Int($0.flags3Raw)) }),
            ("durability", { self.i($0.durability) }), ("guidedTurn", { self.i($0.turnRate) }), ("maxAmmo", { self.i($0.maxAmmo) }),
            ("liDensity", { self.i($0.lightningDensity) }), ("liAmplitude", { self.i($0.lightningAmplitude) }),
            ("particles", { self.i($0.trailParticles.count) }), ("hitParticles", { self.i($0.hitParticles.count) }),
        ])

        try verify(NovaType.spob, in: coll, decode: SpobRes.init, [
            ("position", { .point($0.x, $0.y) }), ("type", { self.i($0.graphicRaw) }),
            ("flags", { self.i(Int($0.flags & 0xFF)) }), ("techLevel", { self.i($0.techLevel) }), ("tribute", { self.i($0.tribute) }),
            ("govt", { self.i($0.government) }), ("minStatus", { self.i($0.minStatus) }),
            ("custPicID", { self.i($0.landingPictID & 0xFFFF) }),
            ("defenseDude", { self.i($0.defenseDude) }), ("defCount", { self.i($0.defenseCountRaw) }),
            ("flags2", { self.i(Int($0.flags2)) }), ("animDelay", { self.i($0.animationDelay) }), ("frame0Bias", { self.i($0.frame0Bias) }),
            ("onDominate", { .string($0.onDominate) }), ("onRelease", { .string($0.onRelease) }),
            ("onDestroy", { .string($0.onDestroy) }), ("onRegen", { .string($0.onRegen) }),
            ("fee", { self.i($0.landingFee) }), ("gravity", { self.i($0.gravity) }), ("weapon", { self.i($0.defenseWeaponRaw) }),
            ("strength", { self.i($0.strength) }), ("deadType", { self.i($0.destroyedGraphicRaw) }),
            ("explodeType", { self.i($0.explosionRaw) }),
        ])

        try verify(NovaType.syst, in: coll, decode: SystRes.init, [
            ("position", { .point($0.x, $0.y) }), ("avgShips", { self.i($0.averageShips) }), ("govt", { self.i($0.government) }),
            ("message", { self.i($0.message) }), ("interference", { self.i($0.interference) }), ("murk", { self.i($0.murk) }),
            ("background", { self.c($0.backgroundColor) }), ("visibility", { .string($0.visibility) }),
            ("reinfFleet", { self.i($0.reinforcementFleet) }), ("reinfTime", { self.i($0.reinforcementDelay) }),
            ("reinfInterval", { self.i($0.reinforcementRegen) }),
        ])
        // Link / stellar lists and asteroid bits (the decoder filters unused slots).
        let sys = try XCTUnwrap(ResourceSchemas.schema(for: NovaType.syst))
        for r in coll.resources(of: NovaType.syst) {
            let m = SystRes(r)
            func list(_ k: String) -> [Int] {
                guard case let .array(a) = sys.read(k, from: r.data)! else { return [] }
                return a.compactMap(\.intValue).filter { $0 >= 128 }
            }
            XCTAssertEqual(list("links"), m.links, "syst #\(r.id) links")
            XCTAssertEqual(list("navDefaults"), m.spobs, "syst #\(r.id) stellars")
            let bits = sys.read("astTypes", from: r.data)!.intValue!
            var ids: [Int] = []
            for b in 0..<8 where (bits >> b) & 1 == 1 { ids.append(128 + b) }
            for b in 0..<8 where (bits >> (8 + b)) & 1 == 1 { ids.append(136 + b) }
            XCTAssertEqual(ids, m.asteroidTypeIDs, "syst #\(r.id) asteroid types")
        }

        try verify(NovaType.govt, in: coll, decode: GovtRes.init, [
            ("voiceType", { self.i($0.voiceType) }), ("flags", { self.i(Int($0.flags1)) }), ("flags2", { self.i(Int($0.flags2)) }),
            ("scanFine", { self.i($0.scanFine) }), ("crimeTolerance", { self.i($0.crimeTolerance) }),
            ("smugglePenalty", { self.i($0.smugglePenalty) }), ("disablePenalty", { self.i($0.disablePenalty) }),
            ("boardPenalty", { self.i($0.boardPenalty) }), ("killPenalty", { self.i($0.killPenalty) }),
            ("shootPenalty", { self.i($0.shootPenalty) }), ("initialRecord", { self.i($0.initialRecord) }),
            ("maxOdds", { self.i($0.maxOdds) }), ("classes", { self.ints($0.classSlots) }),
            ("scanMask", { self.i(Int($0.scanMask)) }), ("require", { .uint64($0.require) }),
            ("inherentJam", { self.ints($0.jamming) }), ("mediumName", { .string($0.mediumName) }),
            ("color", { self.c($0.mapColor) }), ("shipColor", { self.c($0.shipColor) }),
            ("interface", { self.i($0.interface) }), ("newsPicture", { self.i($0.newsPic) }),
        ])

        try verify(NovaType.mission, in: coll, decode: MissionRes.init, [
            ("availRecord", { self.i($0.availRecord) }), ("availRating", { self.i($0.availRating) }),
            ("availRandom", { self.i($0.availRandom) }), ("availBits", { .string($0.availBits) }),
            ("cargoQty", { self.i($0.cargoQty) }), ("scanMask", { self.i($0.scanMask) }), ("payVal", { self.i($0.pay) }),
            ("shipCount", { self.i($0.shipCount) }), ("shipSyst", { self.i($0.shipSystem) }), ("shipDude", { self.i($0.shipDude) }),
            ("shipBehav", { self.i($0.shipBehavior) }), ("shipStart", { self.i($0.shipStart) }),
            ("auxShipCount", { self.i($0.auxShipCount) }), ("auxShipDude", { self.i($0.auxShipDude) }),
            ("auxShipSyst", { self.i($0.auxShipSystem) }), ("briefText", { self.i($0.briefText) }),
            ("quickBrief", { self.i($0.quickBriefText) }), ("loadCargText", { self.i($0.loadCargoText) }),
            ("dumpCargoText", { self.i($0.dropCargoText) }), ("compText", { self.i($0.completionText) }),
            ("failText", { self.i($0.failureText) }), ("shipDoneText", { self.i($0.shipDoneText) }),
            ("refuseText", { self.i($0.refuseText) }), ("timeLimit", { self.i($0.timeLimit) }),
            ("flags", { self.i($0.flags1) }), ("flags2", { self.i($0.flags2) }),
            ("datePostInc", { self.i($0.datePostIncrement) }), ("onAccept", { .string($0.onAccept) }),
            ("onRefuse", { .string($0.onRefuse) }), ("onSuccess", { .string($0.onSuccess) }),
            ("onFailure", { .string($0.onFailure) }), ("onAbort", { .string($0.onAbort) }),
            ("onShipDone", { .string($0.onShipDone) }), ("require", { .uint64($0.require) }),
            ("travelStel", { self.i($0.travelStellar) }), ("returnStel", { self.i($0.returnStellar) }),
            ("compGovt", { self.i($0.compRewardGovt) }), ("compReward", { self.i($0.compLegalReward) }),
        ])

        try verify(NovaType.cron, in: coll, decode: CronRes.init, [
            ("firstDay", { self.i($0.firstDay) }), ("firstMonth", { self.i($0.firstMonth) }), ("firstYear", { self.i($0.firstYear) }),
            ("lastDay", { self.i($0.lastDay) }), ("lastMonth", { self.i($0.lastMonth) }), ("lastYear", { self.i($0.lastYear) }),
            ("random", { self.i($0.random) }), ("duration", { self.i($0.duration) }),
            ("independentNews", { self.i($0.independentNewsStrID) }), ("flags", { self.i($0.flags) }),
            ("contribute", { .uint64($0.contribute) }), ("require", { .uint64($0.require) }),
            ("newsGovts", { self.ints($0.newsGovts) }), ("newsStrings", { self.ints($0.govtNewsStrs) }),
        ])

        try verify(NovaType.pers, in: coll, decode: PersRes.init, [
            ("linkSystem", { self.i($0.linkSyst) }), ("govt", { self.i($0.govt) }), ("aiType", { self.i($0.aiType) }),
            ("aggression", { self.i($0.aggression) }), ("coward", { self.i($0.coward) }), ("shipType", { self.i($0.shipType) }),
            ("weaponTypes", { self.ints($0.weapType) }), ("weaponCounts", { self.ints($0.weapCount) }),
            ("ammoLoads", { self.ints($0.ammoLoad) }), ("credits", { self.i($0.credits) }), ("shieldMod", { self.i($0.shieldMod) }),
            ("hailPict", { self.i($0.hailPict) }), ("commQuote", { self.i($0.commQuote) }), ("hailQuote", { self.i($0.hailQuote) }),
            ("linkMission", { self.i($0.linkMission) }), ("flags", { self.i(Int($0.flags)) }), ("flags2", { self.i(Int($0.flags2)) }),
            ("grantClass", { self.i($0.grantClass) }), ("grantProb", { self.i($0.grantProb) }), ("grantCount", { self.i($0.grantCount) }),
        ])

        try verify(NovaType.dude, in: coll, decode: DudeRes.init, [
            ("aiType", { self.i($0.aiTypeRaw) }), ("govt", { self.i($0.govt) }), ("booty", { self.i(Int($0.flags)) }),
        ])
        try verify(NovaType.fleet, in: coll, decode: FleetRes.init, [
            ("leadShip", { self.i($0.leadShip) }), ("govt", { self.i($0.govt) }), ("linkSystem", { self.i($0.linkSystem) }),
            ("appearOn", { .string($0.appearOn) }), ("quote", { self.i($0.hailQuote) }), ("flags", { self.i(Int($0.flags)) }),
        ])
        try verify(NovaType.rank, in: coll, decode: RankRes.init, [
            ("weight", { self.i($0.weight) }), ("affilGovt", { self.i($0.govt) }), ("priceMod", { self.i($0.priceModifier) }),
            ("salary", { self.i($0.salary) }), ("salaryCap", { self.i($0.salaryCap) }), ("contribute", { .uint64($0.contribute) }),
            ("flags", { self.i($0.flags) }), ("convName", { .string($0.conversationName) }), ("shortName", { .string($0.shortName) }),
        ])
        try verify(NovaType.roid, in: coll, decode: RoidRes.init, [
            ("strength", { self.i($0.strength) }), ("spinRate", { self.i($0.spinRate) }), ("yieldType", { self.i($0.yieldType) }),
            ("yieldQty", { self.i($0.yieldQty) }), ("partCount", { self.i($0.partCount) }), ("partColor", { self.c($0.partColor) }),
            ("fragType1", { self.i($0.fragType1) }), ("fragType2", { self.i($0.fragType2) }), ("fragCount", { self.i($0.fragCount) }),
            ("explodeType", { self.i($0.explodeType) }), ("mass", { self.i($0.mass) }),
        ])
        try verify(NovaType.junk, in: coll, decode: JunkRes.init, [
            ("basePrice", { self.i($0.basePrice) }), ("flags", { self.i(Int($0.flags)) }), ("scanMask", { self.i(Int($0.scanMask)) }),
            ("lowercaseName", { .string($0.lowercaseName) }), ("buyOn", { .string($0.buyOn) }), ("sellOn", { .string($0.sellOn) }),
        ])
        try verify(NovaType.oops, in: coll, decode: OopsRes.init, [
            ("stellar", { self.i($0.stellar) }), ("commodity", { self.i($0.commodity) }), ("priceDelta", { self.i($0.priceDelta) }),
            ("duration", { self.i($0.duration) }), ("frequency", { self.i($0.freq) }), ("activateOn", { .string($0.activateOn) }),
        ])
        try verify(NovaType.boom, in: coll, decode: BoomRes.init, [
            ("animationSpeed", { self.i($0.animationRate) }), ("graphicIndex", { self.i($0.graphicSpinID - 400) }),
        ])
        try verify(NovaType.nebula, in: coll, decode: NebuRes.init, [
            ("position", { .point($0.x, $0.y) }), ("size", { .point($0.width, $0.height) }),
            ("activeOn", { .string($0.activeOn) }), ("onExplore", { .string($0.onExplore) }),
        ])
        try verify(NovaType.spin, in: coll, decode: SpinRes.init, [
            ("spriteID", { self.i($0.spriteID) }), ("maskID", { self.i($0.maskID) }),
            ("tileSize", { .point($0.tileWidth, $0.tileHeight) }), ("tileGrid", { .point($0.tilesAcross, $0.tilesDown) }),
        ])
        try verify(NovaType.shan, in: coll, decode: ShanRes.init, [
            ("baseSprite", { self.i($0.baseSpriteID) }), ("baseMask", { self.i($0.baseMaskID) }),
            ("baseSetCount", { self.i($0.baseSetCount) }), ("baseSize", { .point($0.baseWidth, $0.baseHeight) }),
            ("altSprite", { self.i($0.altSpriteID) }), ("glowSprite", { self.i($0.engineSpriteID) }),
            ("glowSize", { .point($0.engineWidth, $0.engineHeight) }), ("lightSprite", { self.i($0.lightSpriteID) }),
            ("weapSprite", { self.i($0.weaponGlowSpriteID) }), ("shieldSprite", { self.i($0.shieldSpriteID) }),
            ("flags", { self.i($0.extraFrameFlags) }), ("animDelay", { self.i($0.animDelay) }),
            ("weapDecay", { self.i($0.weapDecay) }), ("blinkMode", { self.i($0.blinkMode) }),
            ("gunX", { self.ints($0.gunPoints.map(\.x)) }), ("gunY", { self.ints($0.gunPoints.map(\.y)) }),
            ("gunZ", { self.ints($0.gunPoints.map(\.z)) }), ("turretX", { self.ints($0.turretPoints.map(\.x)) }),
            ("guidedY", { self.ints($0.guidedPoints.map(\.y)) }), ("beamZ", { self.ints($0.beamPoints.map(\.z)) }),
        ])
        try verify(NovaType.char, in: coll, decode: CharRes.init, [
            ("cash", { self.i($0.cash) }), ("shipType", { self.i($0.shipID) }), ("kills", { self.i($0.kills) }),
            ("onStart", { .string($0.onStart) }), ("flags", { self.i($0.flags) }), ("startDay", { self.i($0.startDay) }),
            ("startMonth", { self.i($0.startMonth) }), ("startYear", { self.i($0.startYear) }),
            ("datePrefix", { .string($0.datePrefix) }), ("dateSuffix", { .string($0.dateSuffix) }),
        ])
        try verify(NovaType.colr, in: coll, decode: ColrRes.init, [
            ("menuFont", { .string($0.menuFont) }), ("menuFontSize", { self.i($0.menuFontSize) }),
            ("buttonFont", { .string($0.buttonFont) }), ("buttonFontSz", { self.i($0.buttonFontSz) }),
            ("buttonUp", { self.c($0.buttonUp) }), ("buttonDown", { self.c($0.buttonDown) }), ("menuBrightColor", { self.c($0.menuColor1) }),
        ])
        try verify(NovaType.intf, in: coll, decode: IntfRes.init, [
            ("statusFont", { .string($0.statusFont) }), ("statusFontSize", { self.i($0.statusFontSize) }),
            ("subtitleSize", { self.i($0.subtitleFontSize) }), ("brightTextColor", { self.c($0.brightText) }),
            ("radarArea", { .rect($0.radarArea.top, $0.radarArea.left, $0.radarArea.bottom, $0.radarArea.right) }),
        ])
    }

    func testReadingThenWritingEveryFieldReproducesStockBytes() throws {
        let coll = try stockCollection()
        var checked = 0
        for s in ResourceSchemas.all where s.editorKind == .form {
            for r in coll.resources(of: s.type) {
                let original = s.padded(r.data)
                var copy = original
                for f in s.fields { FieldCodec.write(FieldCodec.read(f, from: original), field: f, into: &copy) }
                if copy != original {
                    let diff = zip(copy, original).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                    XCTFail("\(s.displayName) #\(r.id): rewrite differs at byte \(diff)")
                    break
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// A non-zero byte no schema field covers is a field the schema forgot.
    func testSchemasCoverEveryNonZeroStockByte() throws {
        let coll = try stockCollection()
        for s in ResourceSchemas.all where s.editorKind == .form {
            var covered = [Bool](repeating: false, count: s.minimumSize)
            for f in s.fields {
                for i in 0..<f.count { for b in 0..<f.kind.byteSize { covered[f.offset + i * f.stride + b] = true } }
            }
            var gaps = Set<Int>()
            for r in coll.resources(of: s.type) {
                for (idx, byte) in r.data.enumerated() where byte != 0 && (idx >= covered.count || !covered[idx]) { gaps.insert(idx) }
            }
            XCTAssertTrue(gaps.isEmpty, "\(s.displayName): stock data has non-zero bytes outside the schema at \(gaps.sorted().prefix(10))")
        }
    }

    func testStockStringListsAndDescsRoundTrip() throws {
        let coll = try stockCollection()
        var lists = 0, descs = 0
        for r in coll.resources(of: NovaType.strList) {
            let decoded = TextResourceCodec.decodeStringList(r.data)
            // Exact for well-formed lists (no stray bytes after the last string).
            let encoded = TextResourceCodec.encodeStringList(decoded)
            if encoded == r.data { lists += 1 } else {
                XCTAssertEqual(TextResourceCodec.decodeStringList(encoded), decoded, "STR# #\(r.id)")
            }
        }
        for r in coll.resources(of: NovaType.desc) {
            XCTAssertEqual(DescRecord(r.data).encode(), r.data, "dësc #\(r.id)")
            descs += 1
        }
        XCTAssertGreaterThan(lists, 10)
        XCTAssertGreaterThan(descs, 500)
    }
}
