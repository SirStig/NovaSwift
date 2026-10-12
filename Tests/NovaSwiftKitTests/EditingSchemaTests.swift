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


    /// Reads every stock resource of `type` through both the schema and the
    /// typed decoder and requires the named fields to agree.
    private func verify<T>(_ type: NovaSwiftKit.FourCharCode, in coll: ResourceCollection,
                           decode: (Resource) -> T, _ probes: Probes<T>,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try XCTUnwrap(ResourceSchemas.schema(for: type), file: file, line: line)
        let all = coll.resources(of: type)
        XCTAssertFalse(all.isEmpty, "no \(schema.displayName) in stock data", file: file, line: line)
        var bad: [String] = []
        for r in all {
            let model = decode(r)
            for (key, expect) in probes.items {
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
        do {
            let p = Probes<ShipRes>()
            p.i("cargoSpace") { $0.cargoSpace }
            p.i("shield") { $0.shield }
            p.i("acceleration") { $0.acceleration }
            p.i("speed") { $0.speed }
            p.i("turnRate") { $0.turnRate }
            p.i("fuel") { $0.fuelCapacity }
            p.i("freeMass") { $0.freeMass }
            p.i("armor") { $0.armor }
            p.i("shieldRecharge") { $0.shieldRecharge }
            p.i("maxGuns") { $0.maxGuns }
            p.i("maxTurrets") { $0.maxTurrets }
            p.i("techLevel") { $0.techLevel }
            p.i("dispWeight") { $0.displayWeight }
            p.i("cost") { $0.cost }
            p.i("deathDelay") { $0.deathDelay }
            p.i("armorRecharge") { $0.armorRecharge }
            p.i("mass") { $0.mass }
            p.i("length") { $0.length }
            p.i("inherentAI") { $0.inherentAI }
            p.i("crew") { $0.crew }
            p.i("strength") { $0.strength }
            p.i("inherentGovt") { $0.inherentGovt }
            p.i("flags") { Int($0.flags) }
            p.i("podCount") { $0.podCount }
            p.i("fuelRegen") { $0.fuelRegen }
            p.i("flags2") { Int($0.flags2) }
            p.i("deionize") { $0.deionize }
            p.i("ionizeMax") { $0.ionizeMax }
            p.i("keyCarried") { $0.keyCarriedShipID }
            p.u("contribute") { $0.contribute }
            p.u("require") { $0.require }
            p.s("availability") { $0.availBits }
            p.s("appearOn") { $0.appearOn }
            p.s("onPurchase") { $0.onPurchase }
            p.s("onCapture") { $0.onCapture }
            p.s("onRetire") { $0.onRetire }
            p.s("subtitle") { $0.subtitle }
            p.i("flags3") { Int($0.flags3) }
            p.i("upgradeTo") { $0.escortUpgradesTo }
            p.i("upgradeCost") { $0.escortUpgradeCost }
            p.i("sellValue") { $0.escortSellValue }
            p.i("escortType") { $0.escortCategory }
            try verify(NovaType.ship, in: coll, decode: ShipRes.init, p)
        }
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

        do {
            let p = Probes<OutfRes>()
            p.i("dispWeight") { $0.displayWeight }
            p.i("mass") { $0.mass }
            p.i("techLevel") { $0.techLevel }
            p.i("maximum") { $0.maxInstallable }
            p.i("cost") { $0.cost }
            p.i("flags") { Int($0.flags) }
            p.i("modType") { $0.firstSlot.type }
            p.i("modValue") { $0.firstSlot.value }
            p.u("contribute") { $0.contribute }
            p.u("require") { $0.require }
            p.s("availability") { $0.availBits }
            p.s("onPurchase") { $0.onPurchase }
            p.s("onSell") { $0.onSell }
            p.s("shortName") { $0.outfitterName }
            p.s("lowercaseName") { $0.lowercaseName }
            p.s("lowercasePlural") { $0.lowercasePlural }
            p.i("itemClass") { $0.itemClass }
            p.i("scanMask") { Int($0.scanMask) }
            p.i("requireGovt") { $0.requireGovt }
            try verify(NovaType.outfit, in: coll, decode: OutfRes.init, p)
        }

        do {
            let p = Probes<WeapRes>()
            p.i("reload") { $0.reload }
            p.i("duration") { $0.duration }
            p.i("massDamage") { $0.armorDamage }
            p.i("energyDamage") { $0.shieldDamage }
            p.i("guidance") { $0.guidanceRaw }
            p.i("speed") { $0.speed }
            p.i("ammoType") { $0.ammoType }
            p.i("impact") { $0.impact }
            p.i("proxRadius") { $0.proxRadius }
            p.i("blastRadius") { $0.blastRadius }
            p.i("flags") { Int($0.flagsRaw) }
            p.i("seekerFlags") { $0.seekerFlagsRaw }
            p.i("smokeSet") { $0.smokeSet }
            p.i("decay") { $0.decay }
            p.i("beamLength") { $0.beamLength }
            p.i("beamWidth") { $0.beamWidth }
            p.i("coronaFalloff") { $0.coronaFalloff }
            p.c("beamColor") { $0.beamColor }
            p.c("coronaColor") { $0.coronaColor }
            p.i("subCount") { $0.subCount }
            p.i("subType") { $0.subID }
            p.i("subTheta") { $0.subTheta }
            p.i("subLimit") { $0.subLimit }
            p.i("proxSafety") { $0.proxSafety }
            p.i("flags2") { Int($0.flags2Raw) }
            p.i("ionization") { $0.ionization }
            p.i("exitType") { $0.exitType }
            p.i("burstCount") { $0.burstCount }
            p.i("burstReload") { $0.burstReload }
            p.i("flags3") { Int($0.flags3Raw) }
            p.i("durability") { $0.durability }
            p.i("guidedTurn") { $0.turnRate }
            p.i("maxAmmo") { $0.maxAmmo }
            p.i("liDensity") { $0.lightningDensity }
            p.i("liAmplitude") { $0.lightningAmplitude }
            p.i("particles") { $0.trailParticles.count }
            p.i("hitParticles") { $0.hitParticles.count }
            try verify(NovaType.weapon, in: coll, decode: WeapRes.init, p)
        }

        do {
            let p = Probes<SpobRes>()
            p.pt("position") { ($0.x, $0.y) }
            p.i("type") { $0.graphicRaw }
            p.i("flags") { Int($0.flags & 0xFF) }
            p.i("techLevel") { $0.techLevel }
            p.i("tribute") { $0.tribute }
            p.i("govt") { $0.government }
            p.i("minStatus") { $0.minStatus }
            p.i("custPicID") { Int(Int16(truncatingIfNeeded: $0.landingPictID)) }
            p.i("defenseDude") { $0.defenseDude }
            p.i("defCount") { $0.defenseCountRaw }
            p.i("flags2") { Int($0.flags2) }
            p.i("animDelay") { $0.animationDelay }
            p.i("frame0Bias") { $0.frame0Bias }
            p.s("onDominate") { $0.onDominate }
            p.s("onRelease") { $0.onRelease }
            p.s("onDestroy") { $0.onDestroy }
            p.s("onRegen") { $0.onRegen }
            p.i("fee") { $0.landingFee }
            p.i("gravity") { $0.gravity }
            p.i("weapon") { $0.defenseWeaponRaw }
            p.i("strength") { $0.strength }
            p.i("deadType") { $0.destroyedGraphicRaw }
            p.i("explodeType") { $0.explosionRaw }
            try verify(NovaType.spob, in: coll, decode: SpobRes.init, p)
        }

        do {
            let p = Probes<SystRes>()
            p.pt("position") { ($0.x, $0.y) }
            p.i("avgShips") { $0.averageShips }
            p.i("govt") { $0.government }
            p.i("message") { $0.message }
            p.i("interference") { $0.interference }
            p.i("murk") { $0.murk }
            p.c("background") { $0.backgroundColor }
            p.s("visibility") { $0.visibility }
            p.i("reinfFleet") { $0.reinforcementFleet }
            p.i("reinfTime") { $0.reinforcementDelay }
            p.i("reinfInterval") { $0.reinforcementRegen }
            try verify(NovaType.syst, in: coll, decode: SystRes.init, p)
        }
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

        do {
            let p = Probes<GovtRes>()
            p.i("voiceType") { $0.voiceType }
            p.i("flags") { Int($0.flags1) }
            p.i("flags2") { Int($0.flags2) }
            p.i("scanFine") { $0.scanFine }
            p.i("crimeTolerance") { $0.crimeTolerance }
            p.i("smugglePenalty") { $0.smugglePenalty }
            p.i("disablePenalty") { $0.disablePenalty }
            p.i("boardPenalty") { $0.boardPenalty }
            p.i("killPenalty") { $0.killPenalty }
            p.i("shootPenalty") { $0.shootPenalty }
            p.i("initialRecord") { $0.initialRecord }
            p.i("maxOdds") { $0.maxOdds }
            p.ints("classes") { $0.classSlots }
            p.i("scanMask") { Int($0.scanMask) }
            p.u("require") { $0.require }
            p.ints("inherentJam") { $0.jamming }
            p.s("mediumName") { $0.mediumName }
            p.c("color") { $0.mapColor }
            p.c("shipColor") { $0.shipColor }
            p.i("interface") { $0.interface }
            p.i("newsPicture") { $0.newsPic }
            try verify(NovaType.govt, in: coll, decode: GovtRes.init, p)
        }

        do {
            let p = Probes<MissionRes>()
            p.i("availRecord") { $0.availRecord }
            p.i("availRating") { $0.availRating }
            p.i("availRandom") { $0.availRandom }
            p.s("availBits") { $0.availBits }
            p.i("cargoQty") { $0.cargoQty }
            p.i("scanMask") { $0.scanMask }
            p.i("payVal") { $0.pay }
            p.i("shipCount") { $0.shipCount }
            p.i("shipSyst") { $0.shipSystem }
            p.i("shipDude") { $0.shipDude }
            p.i("shipBehav") { $0.shipBehavior }
            p.i("shipStart") { $0.shipStart }
            p.i("auxShipCount") { $0.auxShipCount }
            p.i("auxShipDude") { $0.auxShipDude }
            p.i("auxShipSyst") { $0.auxShipSystem }
            p.i("briefText") { $0.briefText }
            p.i("quickBrief") { $0.quickBriefText }
            p.i("loadCargText") { $0.loadCargoText }
            p.i("dumpCargoText") { $0.dropCargoText }
            p.i("compText") { $0.completionText }
            p.i("failText") { $0.failureText }
            p.i("shipDoneText") { $0.shipDoneText }
            p.i("refuseText") { $0.refuseText }
            p.i("timeLimit") { $0.timeLimit }
            p.i("flags") { $0.flags1 }
            p.i("flags2") { $0.flags2 }
            p.i("datePostInc") { $0.datePostIncrement }
            p.s("onAccept") { $0.onAccept }
            p.s("onRefuse") { $0.onRefuse }
            p.s("onSuccess") { $0.onSuccess }
            p.s("onFailure") { $0.onFailure }
            p.s("onAbort") { $0.onAbort }
            p.s("onShipDone") { $0.onShipDone }
            p.u("require") { $0.require }
            p.i("travelStel") { $0.travelStellar }
            p.i("returnStel") { $0.returnStellar }
            p.i("compGovt") { $0.compRewardGovt }
            p.i("compReward") { $0.compLegalReward }
            try verify(NovaType.mission, in: coll, decode: MissionRes.init, p)
        }

        do {
            let p = Probes<CronRes>()
            p.i("firstDay") { $0.firstDay }
            p.i("firstMonth") { $0.firstMonth }
            p.i("firstYear") { $0.firstYear }
            p.i("lastDay") { $0.lastDay }
            p.i("lastMonth") { $0.lastMonth }
            p.i("lastYear") { $0.lastYear }
            p.i("random") { $0.random }
            p.i("duration") { $0.duration }
            p.i("independentNews") { $0.independentNewsStrID }
            p.i("flags") { $0.flags }
            p.u("contribute") { $0.contribute }
            p.u("require") { $0.require }
            p.ints("newsGovts") { $0.newsGovts }
            p.ints("newsStrings") { $0.govtNewsStrs }
            try verify(NovaType.cron, in: coll, decode: CronRes.init, p)
        }

        do {
            let p = Probes<PersRes>()
            p.i("linkSystem") { $0.linkSyst }
            p.i("govt") { $0.govt }
            p.i("aiType") { $0.aiType }
            p.i("aggression") { $0.aggression }
            p.i("coward") { $0.coward }
            p.i("shipType") { $0.shipType }
            p.ints("weaponTypes") { $0.weapType }
            p.ints("weaponCounts") { $0.weapCount }
            p.ints("ammoLoads") { $0.ammoLoad }
            p.i("credits") { $0.credits }
            p.i("shieldMod") { $0.shieldMod }
            p.i("hailPict") { $0.hailPict }
            p.i("commQuote") { $0.commQuote }
            p.i("hailQuote") { $0.hailQuote }
            p.i("linkMission") { $0.linkMission }
            p.i("flags") { Int($0.flags) }
            p.i("flags2") { Int($0.flags2) }
            try verify(NovaType.pers, in: coll, decode: PersRes.init, p)
        }

        do {
            let p = Probes<DudeRes>()
            p.i("aiType") { $0.aiTypeRaw }
            p.i("govt") { $0.govt }
            p.i("booty") { Int($0.flags) }
            try verify(NovaType.dude, in: coll, decode: DudeRes.init, p)
        }
        do {
            let p = Probes<FleetRes>()
            p.i("leadShip") { $0.leadShip }
            p.i("govt") { $0.govt }
            p.i("linkSystem") { $0.linkSystem }
            p.s("appearOn") { $0.appearOn }
            p.i("quote") { $0.hailQuote }
            p.i("flags") { Int($0.flags) }
            try verify(NovaType.fleet, in: coll, decode: FleetRes.init, p)
        }
        do {
            let p = Probes<RankRes>()
            p.i("weight") { $0.weight }
            p.i("affilGovt") { $0.govt }
            p.i("priceMod") { $0.priceModifier }
            p.i("salary") { $0.salary }
            p.i("salaryCap") { $0.salaryCap }
            p.u("contribute") { $0.contribute }
            p.i("flags") { $0.flags }
            p.s("convName") { $0.conversationName }
            p.s("shortName") { $0.shortName }
            try verify(NovaType.rank, in: coll, decode: RankRes.init, p)
        }
        do {
            let p = Probes<RoidRes>()
            p.i("strength") { $0.strength }
            p.i("spinRate") { $0.spinRate }
            p.i("yieldType") { $0.yieldType }
            p.i("yieldQty") { $0.yieldQty }
            p.i("partCount") { $0.partCount }
            p.c("partColor") { $0.partColor }
            p.i("fragType1") { $0.fragType1 }
            p.i("fragType2") { $0.fragType2 }
            p.i("fragCount") { $0.fragCount }
            p.i("explodeType") { $0.explodeType }
            p.i("mass") { $0.mass }
            try verify(NovaType.roid, in: coll, decode: RoidRes.init, p)
        }
        do {
            let p = Probes<JunkRes>()
            p.i("basePrice") { $0.basePrice }
            p.i("flags") { Int($0.flags) }
            p.i("scanMask") { Int($0.scanMask) }
            p.s("lowercaseName") { $0.lowercaseName }
            p.s("buyOn") { $0.buyOn }
            p.s("sellOn") { $0.sellOn }
            try verify(NovaType.junk, in: coll, decode: JunkRes.init, p)
        }
        do {
            let p = Probes<OopsRes>()
            p.i("stellar") { $0.stellar }
            p.i("commodity") { $0.commodity }
            p.i("priceDelta") { $0.priceDelta }
            p.i("duration") { $0.duration }
            p.i("frequency") { $0.freq }
            p.s("activateOn") { $0.activateOn }
            try verify(NovaType.oops, in: coll, decode: OopsRes.init, p)
        }
        do {
            let p = Probes<BoomRes>()
            p.i("animationSpeed") { $0.animationRate }
            p.i("graphicIndex") { $0.graphicSpinID - 400 }
            try verify(NovaType.boom, in: coll, decode: BoomRes.init, p)
        }
        do {
            let p = Probes<NebuRes>()
            p.pt("position") { ($0.x, $0.y) }
            p.pt("size") { ($0.width, $0.height) }
            p.s("activeOn") { $0.activeOn }
            p.s("onExplore") { $0.onExplore }
            try verify(NovaType.nebula, in: coll, decode: NebuRes.init, p)
        }
        do {
            let p = Probes<SpinRes>()
            p.i("spriteID") { $0.spriteID }
            p.i("maskID") { $0.maskID }
            p.pt("tileSize") { ($0.tileWidth, $0.tileHeight) }
            p.pt("tileGrid") { ($0.tilesAcross, $0.tilesDown) }
            try verify(NovaType.spin, in: coll, decode: SpinRes.init, p)
        }
        do {
            let p = Probes<ShanRes>()
            p.i("baseSprite") { $0.baseSpriteID }
            p.i("baseMask") { $0.baseMaskID }
            p.i("baseSetCount") { $0.baseSetCount }
            p.pt("baseSize") { ($0.baseWidth, $0.baseHeight) }
            p.i("altSprite") { $0.altSpriteID }
            p.i("glowSprite") { $0.engineSpriteID }
            p.pt("glowSize") { ($0.engineWidth, $0.engineHeight) }
            p.i("lightSprite") { $0.lightSpriteID }
            p.i("weapSprite") { $0.weaponGlowSpriteID }
            p.i("shieldSprite") { $0.shieldSpriteID }
            p.i("flags") { $0.extraFrameFlags }
            p.i("animDelay") { $0.animDelay }
            p.i("weapDecay") { $0.weapDecay }
            p.i("blinkMode") { $0.blinkMode }
            p.ints("gunX") { $0.gunPoints.map(\.x) }
            p.ints("gunY") { $0.gunPoints.map(\.y) }
            p.ints("gunZ") { $0.gunPoints.map(\.z) }
            p.ints("turretX") { $0.turretPoints.map(\.x) }
            p.ints("guidedY") { $0.guidedPoints.map(\.y) }
            p.ints("beamZ") { $0.beamPoints.map(\.z) }
            try verify(NovaType.shan, in: coll, decode: ShanRes.init, p)
        }
        do {
            let p = Probes<CharRes>()
            p.i("cash") { $0.cash }
            p.i("shipType") { $0.shipID }
            p.i("kills") { $0.kills }
            p.s("onStart") { $0.onStart }
            p.i("flags") { $0.flags }
            p.i("startDay") { $0.startDay }
            p.i("startMonth") { $0.startMonth }
            p.i("startYear") { $0.startYear }
            p.s("datePrefix") { $0.datePrefix }
            p.s("dateSuffix") { $0.dateSuffix }
            try verify(NovaType.char, in: coll, decode: CharRes.init, p)
        }
        do {
            let p = Probes<ColrRes>()
            p.s("menuFont") { $0.menuFont }
            p.i("menuFontSize") { $0.menuFontSize }
            p.s("buttonFont") { $0.buttonFont }
            p.i("buttonFontSize") { $0.buttonFontSz }
            p.c("buttonUp") { $0.buttonUp }
            p.c("buttonDown") { $0.buttonDown }
            p.c("menuBrightColor") { $0.menuColor1 }
            try verify(NovaType.colr, in: coll, decode: ColrRes.init, p)
        }
        do {
            let p = Probes<IntfRes>()
            p.s("statusFont") { $0.statusFont }
            p.i("statusFontSize") { $0.statusFontSize }
            p.i("subtitleSize") { $0.subtitleFontSize }
            p.c("brightTextColor") { $0.brightText }
            p.rc("radarArea") { ($0.radarArea.top, $0.radarArea.left, $0.radarArea.bottom, $0.radarArea.right) }
            try verify(NovaType.intf, in: coll, decode: IntfRes.init, p)
        }
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
            let enc = DescRecord(r.data).encode()
            if enc != r.data {
                let at = zip(enc, r.data).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                XCTFail("dësc #\(r.id) differs at byte \(at): \(at >= 0 ? "\(enc[at]) vs \(r.data[r.data.startIndex + at])" : "")")
            }
            descs += 1
        }
        XCTAssertGreaterThan(lists, 10)
        XCTAssertGreaterThan(descs, 500)
    }
}


/// Statement-per-probe table of (schema key → decoder expression), kept out of
/// array literals so the type checker stays fast.
final class Probes<T> {
    var items: [(String, (T) -> FieldValue)] = []
    func i(_ k: String, _ f: @escaping (T) -> Int) { items.append((k, { .int(f($0)) })) }
    func s(_ k: String, _ f: @escaping (T) -> String) { items.append((k, { .string(f($0)) })) }
    func u(_ k: String, _ f: @escaping (T) -> UInt64) { items.append((k, { .uint64(f($0)) })) }
    func c(_ k: String, _ f: @escaping (T) -> NovaColor) { items.append((k, { .color(r: f($0).r, g: f($0).g, b: f($0).b) })) }
    func ints(_ k: String, _ f: @escaping (T) -> [Int]) { items.append((k, { .array(f($0).map(FieldValue.int)) })) }
    func pt(_ k: String, _ f: @escaping (T) -> (Int, Int)) { items.append((k, { .point(f($0).0, f($0).1) })) }
    func rc(_ k: String, _ f: @escaping (T) -> (Int, Int, Int, Int)) { items.append((k, { let v = f($0); return .rect(v.0, v.1, v.2, v.3) })) }
}
