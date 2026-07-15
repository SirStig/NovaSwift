import Foundation
import NovaSwiftKit
import NovaSwiftStory
import NovaSwiftEngine

// novaswift-extract — inspect EV Nova resource containers (classic fork / .ndat / BRGR .rez).
//
//   novaswift-extract types <file>            Summary: each resource type and count
//   novaswift-extract list  <file> <TYPE>     List resources of a type (id, name, size)
//   novaswift-extract info  <file>            Format + totals

func usage() -> Never {
    let name = "novaswift-extract"
    FileHandle.standardError.write(Data("""
    \(name) — inspect EV Nova resource containers

    USAGE:
      \(name) info    <file>
      \(name) types   <file>
      \(name) list    <file> <TYPE>
      \(name) sprites <file> [outDir]     Decode rlëD sprites → PNG sheets
      \(name) library <baseDir> [plugDir] Discover base + plug-ins; show override effect
      \(name) ship    <baseDir> [id]      Decode ship stats + full loadout + sprite → PNG
      \(name) outfit  <baseDir> [id]      List outfits, or one outfit's modifiers
      \(name) govt    <baseDir> [id]      List governments, or one govt's decoded fields
      \(name) system  <baseDir> [id]      List a system's planets + resolve sprites
      \(name) char    <baseDir> [id]      List starting scenarios (chär), or preview a new pilot
      \(name) sounds  <baseDir>           List all snd resources (id, name, rate, length)
      \(name) sound   <baseDir> <id> [out] Decode one snd → WAV (default: <id>.wav)
      \(name) ai      <baseDir> [sysID] [secs]   Headless AI sim: populate + run a system
      \(name) mission-spawn <baseDir> <sysID> <dudeID> <count> [goal] [behav] [secs]
                                          Spawn mission ships into a live system + run
                                          goal: 0 destroy 1 disable 2 board 3 escort 4 observe 5 rescue 6 chaseOff
                                          behav: -1 std  0 attackPlayer  1 protectPlayer  2 attackStellars

    <TYPE> is a four-char resource code, e.g. shïp  wëap  oütf  sÿst  spöb
    (paste the exact code including accents).

    """.utf8))
    exit(2)
}

func loadCollection(_ path: String) -> (ResourceCollection, ContainerFormat) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        FileHandle.standardError.write(Data("error: cannot read file \(path)\n".utf8))
        exit(1)
    }
    let format = ResourceFile.detectFormat(data) ?? .classic
    do {
        let collection = try ResourceFile.read(data)
        return (collection, format)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Classic Mac dialog resource decoders (DITL / DLOG)

private func be16(_ d: Data, _ off: Int) -> Int {
    let b = d.startIndex + off
    return (Int(d[b]) << 8) | Int(d[b + 1])
}
private func s16(_ d: Data, _ off: Int) -> Int {
    let v = be16(d, off)
    return v >= 0x8000 ? v - 0x10000 : v
}
private func be32(_ d: Data, _ off: Int) -> Int {
    let b = d.startIndex + off
    return (Int(d[b]) << 24) | (Int(d[b+1]) << 16) | (Int(d[b+2]) << 8) | Int(d[b+3])
}

private func ditlTypeName(_ raw: Int) -> String {
    switch raw & 0x7F {
    case 0: return "userItem"
    case 4: return "button"
    case 5: return "checkbox"
    case 6: return "radioButton"
    case 7: return "resControl"
    case 8: return "statText"
    case 16: return "editText"
    case 32: return "icon"
    case 64: return "picture"
    default: return "type\(raw & 0x7F)"
    }
}

/// Decode a DITL resource body and print each item's rect (top,left,bottom,right),
/// type, enabled flag, and payload (text, or a 2-byte resource ID for icon/pic/ctl).
private func printDITL(_ res: Resource) {
    let d = res.data
    print("DITL #\(res.id) \"\(res.name)\"  \(d.count) bytes")
    guard d.count >= 2 else { return }
    let count = s16(d, 0) + 1
    var off = 2
    for i in 0..<count {
        guard off + 4 + 8 + 2 <= d.count else {
            print("  [item \(i)] truncated at offset \(off)"); break
        }
        off += 4 // placeholder handle
        let top = s16(d, off), left = s16(d, off + 2), bottom = s16(d, off + 4), right = s16(d, off + 6)
        off += 8
        let rawType = Int(d[d.startIndex + off]); off += 1
        let enabled = (rawType & 0x80) == 0
        let len = Int(d[d.startIndex + off]); off += 1
        guard off + len <= d.count else {
            print("  [item \(i)] item data truncated"); break
        }
        let payload = d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + len))
        off += len
        if len % 2 == 1 { off += 1 } // pad to even

        let kind = ditlTypeName(rawType)
        var extra = ""
        switch rawType & 0x7F {
        case 8, 16: // statText / editText: raw ASCII/MacRoman text
            extra = "  \"\(String(data: payload, encoding: .macOSRoman) ?? "?")\""
        case 4, 5, 6: // button/checkbox/radio: label text
            extra = "  \"\(String(data: payload, encoding: .macOSRoman) ?? "?")\""
        case 32, 64, 7: // icon/picture/resControl: 2-byte resource id
            if payload.count >= 2 { extra = "  resID=\(be16(payload, 0))" }
        default:
            if !payload.isEmpty { extra = "  bytes=\(payload.count)" }
        }
        let w = right - left, h = bottom - top
        let kindPadded = kind.padding(toLength: max(kind.count, 12), withPad: " ", startingAt: 0)
        let prefix = String(format: "  [%2d] (%4d,%4d)-(%4d,%4d) %dx%d  ", i, left, top, right, bottom, w, h)
        print(prefix + kindPadded + (enabled ? "" : " [disabled]") + extra)
    }
}

/// Byte offset / size table for a DLOG resource, ending in the itemsID field.
private func dlogItemsID(_ res: Resource) -> Int? {
    let d = res.data
    guard d.count >= 20 else { return nil }
    return s16(d, 18) // rect(8)+procID(2)+visible(2)+goAway(2)+refCon(4) = 18
}

private func printDLOG(_ res: Resource) {
    let d = res.data
    print("DLOG #\(res.id) \"\(res.name)\"  \(d.count) bytes")
    guard d.count >= 20 else { return }
    let top = s16(d, 0), left = s16(d, 2), bottom = s16(d, 4), right = s16(d, 6)
    let procID = s16(d, 8)
    let visible = s16(d, 10) != 0
    let goAway = s16(d, 12) != 0
    let refCon = be32(d, 14)
    let itemsID = s16(d, 18)
    var title = ""
    var off = 20
    if off < d.count {
        let tlen = Int(d[d.startIndex + off]); off += 1
        if off + tlen <= d.count {
            title = String(data: d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + tlen)), encoding: .macOSRoman) ?? ""
        }
    }
    print("  bounds=(\(left),\(top))-(\(right),\(bottom)) \(right-left)x\(bottom-top)  procID=\(procID)  visible=\(visible)  goAway=\(goAway)  refCon=\(refCon)")
    print("  title=\"\(title)\"  itemsID(DITL)=\(itemsID)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "info":
    guard args.count == 2 else { usage() }
    let (collection, format) = loadCollection(args[1])
    print("format:       \(format.rawValue)")
    print("total types:  \(collection.types.count)")
    print("total rez:    \(collection.totalCount)")

case "types":
    guard args.count == 2 else { usage() }
    let (collection, format) = loadCollection(args[1])
    print("format: \(format.rawValue)   types: \(collection.types.count)   resources: \(collection.totalCount)")
    print(String(repeating: "-", count: 32))
    for entry in collection.typeCounts {
        let code = entry.type.stringValue
        // Some codes are non-printable; show hex alongside for clarity.
        print(String(format: "  %@  (%@)  x%d", code, entry.type.hexValue, entry.count))
    }

case "list":
    guard args.count == 3 else { usage() }
    let (collection, _) = loadCollection(args[1])
    guard let type = FourCharCode(args[2]) else {
        FileHandle.standardError.write(Data("error: TYPE must be exactly four Mac Roman characters\n".utf8))
        exit(1)
    }
    let resources = collection.resources(of: type)
    if resources.isEmpty {
        print("no resources of type \(type.stringValue) (\(type.hexValue))")
    } else {
        print("\(resources.count) × \(type.stringValue):")
        for r in resources {
            let name = r.name.isEmpty ? "" : "  \"\(r.name)\""
            print(String(format: "  #%-6d %7d bytes%@", r.id, r.data.count, name))
        }
    }

case "sprites":
    guard args.count == 2 || args.count == 3 else { usage() }
    let (collection, _) = loadCollection(args[1])
    let outDir = args.count == 3 ? args[2] : "data/converted/sprites"
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let sprites = collection.resources(of: NovaType.rleD)
    if sprites.isEmpty {
        print("no rlëD sprites in \(args[1])")
        break
    }
    print("decoding \(sprites.count) rlëD sprites → \(outDir)/")
    var ok = 0, failed = 0
    for res in sprites {
        do {
            let sheet = try RLED.decode(res.data)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("rleD_\(res.id).png")
            if sheet.writePNG(to: url) {
                ok += 1
                print(String(format: "  #%-6d %dx%d × %d frames → %@",
                             res.id, sheet.frameWidth, sheet.frameHeight, sheet.frameCount,
                             url.lastPathComponent))
            } else {
                failed += 1
                print("  #\(res.id): PNG encode failed")
            }
        } catch {
            failed += 1
            print("  #\(res.id): \(error)")
        }
    }
    print("done: \(ok) written, \(failed) failed")

case "library":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseDir = URL(fileURLWithPath: args[1])
    let baseFiles = GameLibrary.discoverResourceFiles(in: baseDir)
    print("base data: \(baseFiles.count) resource file(s) under \(baseDir.lastPathComponent)/")
    for f in baseFiles { print("  · \(f.lastPathComponent)") }

    var plugins: [PluginBundle] = []
    if args.count == 3 {
        plugins = GameLibrary.discoverPlugins(in: URL(fileURLWithPath: args[2]))
        print("\nplug-ins discovered: \(plugins.count)")
        for p in plugins {
            print("  [\(p.kind == .unknown ? GameLibrary.classify(p) : p.kind)]  \(p.name)  (\(p.fileURLs.count) file(s))")
        }
    }

    do {
        let baseOnly = try GameLibrary.merge(baseFiles: baseFiles)
        print("\nbase only:            \(baseOnly.totalCount) resources, \(baseOnly.types.count) types")
        if !plugins.isEmpty {
            // Enable every discovered plug-in to demonstrate the override chain.
            let enabled = plugins.map { var p = $0; p.isEnabled = true; return p }
            let merged = try GameLibrary.merge(baseFiles: baseFiles, plugins: enabled)
            let delta = merged.totalCount - baseOnly.totalCount
            print("base + all plug-ins:  \(merged.totalCount) resources, \(merged.types.count) types  (\(delta >= 0 ? "+" : "")\(delta) net after overrides)")
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "ship":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do {
        game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }

    if args.count == 2 {
        // No id: list all ships with a few stats.
        let ships = game.ships()
        print("\(ships.count) ships:")
        for s in ships.prefix(60) {
            print(String(format: "  #%-5d  %-24@  shield %-5d armor %-5d speed %-4d turn %-4d",
                         s.id, s.name as NSString, s.shield, s.armor, s.speed, s.turnRate))
        }
        break
    }

    guard let id = Int(args[2]), let s = game.ship(id) else {
        FileHandle.standardError.write(Data("error: no ship with id \(args[2])\n".utf8)); exit(1)
    }
    print("""
    ship #\(s.id): \(s.name)
      shield \(s.shield)  armor \(s.armor)  mass \(s.mass)
      speed \(s.speed)  accel \(s.acceleration)  turn \(s.turnRate)
      shieldRecharge \(s.shieldRecharge)  armorRecharge \(s.armorRecharge)  fuelRegen \(s.fuelRegen)
      cargo \(s.cargoSpace)t  freeMass \(s.freeMass)t  guns \(s.maxGuns)  turrets \(s.maxTurrets)  crew \(s.crew)  cost \(s.cost)
      fuel \(s.fuelCapacity) (\(s.fuelCapacity / 100) jumps)
    """)
    // The full ship system: aggregate preinstalled outfits into effective stats.
    if let lo = Galaxy(game: game).loadout(shipID: s.id) {
        print("  loadout: shield \(Int(lo.maxShield))  armor \(Int(lo.maxArmor))  fuel \(Int(lo.maxFuel)) (\(lo.jumpRange) jumps)  cargo \(lo.cargoCapacity)t  freeMass \(lo.freeMass)/\(lo.massCapacity)t\(lo.afterburner != nil ? "  +afterburner" : "")")
        if !lo.outfits.isEmpty {
            let names = lo.outfits.sorted { $0.key < $1.key }
                .map { "\(game.outfit($0.key)?.name ?? "oütf \($0.key)")×\($0.value)" }
            print("  outfits: \(names.joined(separator: ", "))")
        }
        for w in lo.weapons {
            let wn = game.weapon(w.id)?.name ?? "wëap \(w.id)"
            print("    weapon \(wn) ×\(w.count)\(w.ammo > 0 ? "  ammo \(w.ammo)" : "")")
        }
    }
    if let shan = game.shan(s.id) {
        print("  shän #\(shan.id): baseSprite spïn \(shan.baseSpriteID)  frames \(shan.baseSetCount)  \(shan.baseWidth)x\(shan.baseHeight)")
        func fmt(_ pts: [ShanExitPoint]) -> String {
            pts.map { "(\($0.x),\($0.y))" }.joined(separator: " ")
        }
        print("    exit gun:    \(fmt(shan.gunPoints))")
        print("    exit turret: \(fmt(shan.turretPoints))")
        print("    exit guided: \(fmt(shan.guidedPoints))")
        print("    exit beam:   \(fmt(shan.beamPoints))")
        print("    compress up \(shan.upCompress) down \(shan.downCompress)")
    }
    if let (spin, rle) = game.shipSpriteData(s.id), let sheet = try? RLED.decode(rle) {
        let outDir = "data/converted/ships"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("ship_\(s.id).png")
        sheet.writePNG(to: url)
        let via = spin.map { "spïn \($0.id)→rlëD \($0.spriteID)" } ?? "rlëD direct"
        print("  sprite: \(sheet.frameWidth)x\(sheet.frameHeight) × \(sheet.frameCount) frames (\(via)) → \(url.path)")
    } else {
        print("  sprite: (could not resolve)")
    }

case "outfit":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    if args.count == 2 {
        let outfits = game.outfits()
        print("\(outfits.count) outfits:")
        for o in outfits.prefix(80) {
            let mods = o.modifiers.map { "\($0.type)=\($0.value)" }.joined(separator: ",")
            print(String(format: "  #%-5d  %-28@  %4dt  %8dcr  [%@]",
                         o.id, o.name as NSString, o.mass, o.cost, mods as NSString))
        }
        break
    }
    guard let id = Int(args[2]), let o = game.outfit(id) else {
        FileHandle.standardError.write(Data("error: no outfit with id \(args[2])\n".utf8)); exit(1)
    }
    print("""
    outfit #\(o.id): \(o.name)
      mass \(o.mass)t  cost \(o.cost)cr  techLevel \(o.techLevel)  max \(o.maxInstallable == 0 ? "∞" : "\(o.maxInstallable)")
    """)
    for (type, value) in o.modifiers { print("    \(type) = \(value)") }

case "weapon":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    let weps: [WeapRes] = {
        if args.count == 3, let id = Int(args[2]), let w = game.weapon(id) { return [w] }
        return game.weapons()
    }()
    for w in weps {
        var tags: [String] = ["guidance=\(w.guidance)", "ammoType=\(w.ammoType)", "maxAmmo=\(w.maxAmmo)"]
        if w.firedBySecondTrigger { tags.append("SECONDARY") }
        if w.usesShipWeaponSprite { tags.append("SHIP-WEAPON-SPRITE") }
        if w.fireSimultaneously { tags.append("SIMUL") }
        if w.isBeam { tags.append("beam(len \(w.beamLength) w \(w.beamWidth) core=\(w.beamColor.r),\(w.beamColor.g),\(w.beamColor.b) corona=\(w.coronaColor.r),\(w.coronaColor.g),\(w.coronaColor.b) falloff=\(w.coronaFalloff))") }
        if w.exitType != -1 { tags.append("exit=\(w.exitType)") }
        if w.burstCount > 0 { tags.append("burst \(w.burstCount)/\(w.burstReload)") }
        if w.proxRadius > 0 { tags.append("prox \(w.proxRadius)+safety\(w.proxSafety)") }
        if w.blastRadius > 0 { tags.append("blast \(w.blastRadius)") }
        if w.decay > 0 { tags.append("decay \(w.decay)") }
        if w.impact > 0 { tags.append("impact \(w.impact)") }
        if w.hasSubmunition { tags.append("sub \(w.subCount)×#\(w.subID)@\(w.subTheta)°/lim\(w.subLimit)") }
        if let g = w.graphicSpinID { tags.append("graphic spïn \(g)\(w.spinShots ? " spin" : "")") }
        print(String(format: "  #%-5d %-26@ dmg %d/%d reload %d speed %d dur %d  [%@]",
                     w.id, w.name as NSString, w.shieldDamage, w.armorDamage, w.reload, w.speed,
                     w.duration, tags.joined(separator: " ") as NSString))
    }

case "govt":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    if args.count == 2 {
        let govts = game.govts()
        print("\(govts.count) governments:")
        for g in govts {
            var tags: [String] = []
            if g.xenophobic { tags.append("XENOPHOBIC") }
            if g.alwaysAttacksPlayer { tags.append("ALWAYS-ATTACKS") }
            if g.neverAttacksPlayer { tags.append("NEVER-ATTACKS") }
            if g.nosy { tags.append("NOSY") }
            if g.roadsideAssistance { tags.append("FREE-REPAIR") }
            print(String(format: "  #%-5d  %-28@  crimeTol %-6d  classes=%@ allies=%@ enemies=%@  [%@]",
                         g.id, g.name as NSString, g.crimeTolerance,
                         "\(g.classes)" as NSString, "\(g.allies)" as NSString, "\(g.enemies)" as NSString,
                         tags.joined(separator: " ") as NSString))
        }
        break
    }
    guard let id = Int(args[2]), let g = game.govt(id) else {
        FileHandle.standardError.write(Data("error: no govt with id \(args[2])\n".utf8)); exit(1)
    }
    print("""
    govt #\(g.id): \(g.name)
      commName "\(g.commName)"  targetCode "\(g.targetCode)"  mediumName "\(g.mediumName)"
      classes \(g.classes)  allies \(g.allies)  enemies \(g.enemies)
      crimeTolerance \(g.crimeTolerance)  initialRecord \(g.initialRecord)  maxOdds \(g.maxOdds)  shipSpeedFactor \(g.shipSpeedFactor)
      penalties: scanFine \(g.scanFine)  smuggle \(g.smugglePenalty)  disable \(g.disablePenalty)  board \(g.boardPenalty)  kill \(g.killPenalty)  shoot(dead) \(g.shootPenalty)
      scanMask 0x\(String(g.scanMask, radix: 16))  require 0x\(String(g.require, radix: 16))  jamming \(g.jamming)
      interface \(g.interface)  newsPic \(g.newsPic)  voiceType \(g.voiceType)
      flags: xenophobic=\(g.xenophobic) nosy=\(g.nosy) alwaysAttacksPlayer=\(g.alwaysAttacksPlayer) immuneToPlayer=\(g.immuneToPlayer) warshipsRetreat=\(g.warshipsRetreat) neverAttacksPlayer=\(g.neverAttacksPlayer) warshipsTakeBribes=\(g.warshipsTakeBribes) cantBeHailed=\(g.cantBeHailed) plundersBeforeKilling=\(g.plundersBeforeKilling) nonTalkative=\(g.nonTalkative) roadsideAssistance=\(g.roadsideAssistance) avoidsHypergates=\(g.avoidsHypergates) prefersHypergates=\(g.prefersHypergates) prefersWormholes=\(g.prefersWormholes)
    """)

case "system":
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    let systemID: Int
    if args.count == 3, let id = Int(args[2]) {
        systemID = id
    } else if let start = game.startingSystem() {
        systemID = start.id
        print("(no id given — using most-populated system)")
    } else {
        print("no systems with stellar objects found"); break
    }

    guard let sys = game.system(systemID) else {
        FileHandle.standardError.write(Data("error: no system \(systemID)\n".utf8)); exit(1)
    }
    print("system #\(sys.id): \(sys.name)  at (\(sys.x),\(sys.y))")
    print("  links → \(sys.links.map(String.init).joined(separator: ", "))")
    let bodies = game.stellarObjects(in: sys.id)
    print("  \(bodies.count) stellar object(s):")
    for (spob, sprite) in bodies {
        let spr = sprite.map { "\($0.frameWidth)x\($0.frameHeight)" } ?? "(no rlëD sprite / PICT)"
        print(String(format: "    #%-5d %-22@ at (%5d,%5d)  gfx spïn %d  sprite %@",
                     spob.id, spob.name as NSString, spob.x, spob.y, spob.graphicSpinID, spr))
    }

case "char":
    // List every starting scenario (chär), or with an id, fully decode one and
    // preview the pilot PilotFactory would create from it.
    guard args.count == 2 || args.count == 3 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    func printScenario(_ ch: CharRes) {
        print("chär #\(ch.id) \"\(ch.name)\"  (\(ch.displayName))\(ch.isDefault ? "  [default]" : "")\(ch.isHidden ? "  [hidden]" : "")")
        print("  credits:   \(ch.cash)")
        let shipName = game.ship(ch.shipID)?.name ?? "?"
        print("  ship:      shïp #\(ch.shipID) \(shipName)")
        let sysNames = ch.startSystems.map { "\($0)(\(game.system($0)?.name ?? "?"))" }
        print("  start sys: \(sysNames.joined(separator: ", "))  (random pick)")
        print("  date:      \(ch.startDay)/\(ch.startMonth)/\(ch.startYear)\(ch.dateSuffix)")
        print("  kills:     \(ch.kills)  (\(CombatRating.title(forRating: ch.kills)))")
        if !ch.govtStatuses.isEmpty {
            let gs = ch.govtStatuses.map { "\($0.govt)(\(game.govt($0.govt)?.name ?? "?"))=\($0.status)" }
            print("  standings: \(gs.joined(separator: ", "))")
        }
        if !ch.introSlides.isEmpty {
            let sl = ch.introSlides.map { "PICT \($0.pictID)@\($0.delaySeconds)s" }
            print("  intro:     \(sl.joined(separator: ", "))\(ch.introTextID.map { "  text dësc \($0)" } ?? "")")
        }
        if !ch.onStart.isEmpty { print("  onStart:   \(ch.onStart)") }
    }

    if args.count == 3, let id = Int(args[2]) {
        guard let ch = game.character(id) else {
            FileHandle.standardError.write(Data("error: no chär \(id)\n".utf8)); exit(1)
        }
        printScenario(ch)
        let pilot = PilotFactory.make(name: "Test Pilot", isMale: true, scenario: ch, game: game)
        print("\n  → new pilot: \(pilot.pilotName), \(pilot.credits)cr, ship #\(pilot.shipType) \"\(pilot.shipName)\", "
              + "system \(pilot.currentSystem) (\(game.system(pilot.currentSystem)?.name ?? "?")), "
              + "date \(pilot.date), bits set: \(pilot.setBits.count)")
    } else {
        let all = game.characters().sorted { $0.id < $1.id }
        print("\(all.count) starting scenario(s):\n")
        for ch in all { printScenario(ch); print("") }
        print("selectable in a new-pilot picker: \(game.selectableScenarios().map(\.displayName).joined(separator: ", "))")
    }

case "sounds":
    guard args.count == 2 else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    let ids = game.soundIDs()
    print("\(ids.count) snd resource(s):")
    for id in ids {
        let name = game.soundName(id) ?? ""
        if let s = game.sound(id) {
            print(String(format: "  #%-6d %-28@ %6.0f Hz  %7d samples  %5.2fs",
                         id, name as NSString, s.sampleRate, s.frameCount, s.duration))
        } else {
            print(String(format: "  #%-6d %-28@ (undecodable)", id, name as NSString))
        }
    }

case "sound":
    guard args.count == 3 || args.count == 4, let id = Int(args[2]) else { usage() }
    let baseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let game: NovaGame
    do { game = NovaGame(try GameLibrary.merge(baseFiles: baseFiles)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    guard let snd = game.sound(id) else {
        FileHandle.standardError.write(Data("error: snd \(id) missing or undecodable\n".utf8)); exit(1)
    }
    let outPath = args.count == 4 ? args[3] : "\(id).wav"
    do {
        try snd.wavData().write(to: URL(fileURLWithPath: outPath))
        print(String(format: "wrote %@  (%.0f Hz, %d samples, %.2fs)",
                     outPath, snd.sampleRate, snd.frameCount, snd.duration))
    } catch {
        FileHandle.standardError.write(Data("error writing WAV: \(error)\n".utf8)); exit(1)
    }

case "raw":
    // Dev tool: dump a resource body as signed 16-bit big-endian words, to
    // reverse-check field offsets against the EV Nova Bible.
    //   novaswift-extract raw <baseDir> <TYPE> <id>
    guard args.count == 4, let type = FourCharCode(args[2]), let id = Int(args[3]) else { usage() }
    let rawBaseFiles = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let rawCol: ResourceCollection
    do { rawCol = try GameLibrary.merge(baseFiles: rawBaseFiles) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    guard let r = rawCol.resource(type, id) else {
        FileHandle.standardError.write(Data("error: no \(type.stringValue) #\(id)\n".utf8)); exit(1)
    }
    print("\(type.stringValue) #\(r.id) \"\(r.name)\"  \(r.data.count) bytes")
    let rd = r.data
    func rawWord(_ off: Int) -> Int {
        let b = rd.startIndex + off
        let v = (Int(rd[b]) << 8) | Int(rd[b + 1])
        return v >= 0x8000 ? v - 0x10000 : v
    }
    var rawOff = 0
    var rawLine = ""
    while rawOff + 2 <= rd.count {
        if rawOff % 16 == 0 { rawLine += String(format: "\n  @%-4d ", rawOff) }
        rawLine += String(format: "%6d ", rawWord(rawOff))
        rawOff += 2
    }
    print(rawLine)
    // ASCII view: printable bytes as-is, others as '.', 64 cols, offset-labelled.
    print("\n  --- ascii ---")
    var aOff = 0
    var aLine = ""
    while aOff < rd.count {
        if aOff % 64 == 0 { aLine += String(format: "\n  @%-4d ", aOff) }
        let byte = rd[rd.startIndex + aOff]
        aLine += (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
        aOff += 1
    }
    print(aLine)

case "tmpl":
    // Dev tool: parse a ResForge/EVN TMPL resource (label PString + 4-char type
    // code pairs) and print each field with its correct running byte offset.
    // Authoritative field layout for the on-disk resource bodies — mirrors the
    // real ResForge TemplateParser's offset semantics (see
    // third_party/ResForge/Plugins/Sources/TemplateEditor/TemplateParser.swift
    // and Elements/*.swift), specifically:
    //   - "Rnnn" (single letter + 3 hex digits) repeats the *next* field nnn
    //     times (hex, not decimal — e.g. R010 = 16, not 10).
    //   - "Cnnn"/"Pnnn"/lowercase-n+hex (NCB strings) are fixed-size string
    //     fields whose *total byte width* is the hex value (Pnnn: value+1).
    //   - A run of consecutive bit-field elements (BBnn/WBnn/LBnn/QBnn, e.g.
    //     the six BB04 commodity-price nibbles in spöb) shares ONE underlying
    //     read of size matching its letter (BB=1, WB=2, LB=4, QB=8 bytes) —
    //     only the first element in the run advances the offset; siblings
    //     that don't fully consume the underlying width leave the reader mid
    //     group until enough sibling bits fill it.
    //   - "PACK"/"DVDR"/"CASE"/"CASR"/"RREF" are structural/cosmetic and cost
    //     zero bytes; they may be printed *before* the concrete field(s) they
    //     describe (ResForge allows a PACK label to preview fields that are
    //     physically declared later in the stream — trust declaration order,
    //     not proximity to the PACK line).
    // NOT handled (rare in the resource types this repo cares about — none of
    // crön/flët/gövt/jünk/öops/oütf/përs/ränk/spöb/sÿst/wëap need them at the
    // top level except oütf's mod-type union and wëap's included Projectile
    // templates): nested "TMPL <name>" includes, and KEYB/KEYE keyed
    // (union-style) sections where only the section matching the preceding
    // key field's value is actually present on disk. Fields after an
    // unhandled construct are printed with "?" rather than a wrong number.
    //   novaswift-extract tmpl <Templates.rsrc> <id>
    guard args.count == 3, let id = Int(args[2]) else { usage() }
    let (tcol, _) = loadCollection(args[1])
    guard let tr = tcol.resource(FourCharCode("TMPL")!, id) else {
        FileHandle.standardError.write(Data("error: no TMPL #\(id)\n".utf8)); exit(1)
    }
    // Byte size of a template field type code (variable/unhandled ones return nil).
    func tmplSize(_ code: String) -> Int? {
        switch code {
        case "DBYT", "UBYT", "HBYT", "CHAR", "BFLG", "FBYT", "BOOL", "BORV": return 1
        case "DWRD", "UWRD", "HWRD", "WFLG", "FWRD", "RSID", "AWRD", "WORV", "WCOL": return 2
        case "DLNG", "ULNG", "HLNG", "LFLG", "FLNG", "PNT ", "TNAM", "LORV", "LCOL", "DATE", "LRID": return 4
        case "RECT": return 8 // 4×DWRD
        case "COLR": return 6 // QuickDraw color
        case "QB64", "QORV": return 8
        default:
            if code.first == "C", let n = Int(code.dropFirst(), radix: 16) { return n } // Cnnn fixed C string
            if code.first == "P", let n = Int(code.dropFirst(), radix: 16) { return n + 1 } // Pnnn pascal
            if code.first == "n", let n = Int(code.dropFirst(), radix: 16) { return n } // NCB string (NovaTools "n")
            if code.first == "F", let n = Int(code.dropFirst(), radix: 16) { return n } // Fnnn filler bytes
            return nil // PSTR/CSTR/HEXD/OCNT/LSTB/LSTE/ZCNT/TMPL/KEYB/KEYE etc — variable/structural/unhandled
        }
    }
    // Bit-field byte width by leading letter(s): BB=1(UInt8) WB=2(UInt16) LB=4(UInt32) QB=8(UInt64).
    func bitFieldGroupWidth(_ code: String) -> Int? {
        guard code.count == 4, let n = Int(code.suffix(2)), n >= 1, n <= 64 else { return nil }
        switch code.prefix(2) {
        case "BB": return 1
        case "WB": return 2
        case "LB": return 4
        case "QB": return 8
        default: return nil
        }
    }
    struct TField { let label: String; let code: String }
    let tdata = tr.data
    var tp = tdata.startIndex
    var rawFields: [TField] = []
    while tp < tdata.endIndex {
        let len = Int(tdata[tp]); tp += 1
        guard tp + len + 4 <= tdata.endIndex else { break }
        let label = String(data: tdata[tp..<tp+len], encoding: .macOSRoman) ?? "?"
        tp += len
        let code = String(data: tdata[tp..<tp+4], encoding: .macOSRoman) ?? "????"
        tp += 4
        rawFields.append(TField(label: label, code: code))
    }
    print("TMPL #\(tr.id) \"\(tr.name)\" — field layout (offset, type, label):")
    var fi = 0
    var tByteOff = 0
    var bitBitsRemaining = 0 // bits left to fill in the currently-open bit-field group
    var sawUnhandled = false
    while fi < rawFields.count {
        let f = rawFields[fi]
        // "Rnnn": repeat the *next* field nnn times (hex).
        if f.code.first == "R", f.code.count == 4, let count = Int(f.code.dropFirst(), radix: 16) {
            guard fi + 1 < rawFields.count else { break }
            let target = rawFields[fi + 1]
            print("  @\(String(format: "%5d", tByteOff))  [\(f.code) → ×\(count)]  \(f.label)")
            let sz = tmplSize(target.code)
            for i in 0..<count {
                let offStr = sz == nil ? "  ?  " : String(format: "%5d", tByteOff)
                print("  @\(offStr)  \(target.code)  \(target.label) [\(i+1)/\(count)]")
                if let s = sz { tByteOff += s } else { sawUnhandled = true }
            }
            fi += 2
            continue
        }
        if let groupWidth = bitFieldGroupWidth(f.code) {
            let bits = Int(f.code.suffix(2)) ?? 0
            if bitBitsRemaining <= 0 { bitBitsRemaining = groupWidth * 8 }
            let offStr = bitBitsRemaining == groupWidth * 8 ? String(format: "%5d", tByteOff) : "  \"  " // mid-group: same underlying read
            print("  @\(offStr)  \(f.code)  \(f.label)  (\(bits) bits)")
            bitBitsRemaining -= bits
            if bitBitsRemaining <= 0 { tByteOff += groupWidth; bitBitsRemaining = 0 }
            fi += 1
            continue
        }
        let sz = tmplSize(f.code)
        let offStr = sz == nil ? "  ?  " : String(format: "%5d", tByteOff)
        print("  @\(offStr)  \(f.code)  \(f.label)")
        if let s = sz { tByteOff += s } else if !["PACK", "DVDR", "CASE", "CASR", "RREF", "FCNT"].contains(f.code) { sawUnhandled = true }
        fi += 1
    }
    print("\ntotal (as computed): \(tByteOff) bytes" + (sawUnhandled ? "  (⚠️ contains TMPL-include/KEYB or another unhandled construct — treat as a lower bound, verify against `raw`)" : ""))

case "strscan":
    // Dev tool: across all resources of a type, find printable ASCII runs (>=3
    // chars) and tally their START offsets — reveals fixed string-field offsets.
    //   novaswift-extract strscan <baseDir> <TYPE>
    guard args.count == 3, let type = FourCharCode(args[2]) else { usage() }
    let ssBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let ssCol: ResourceCollection
    do { ssCol = try GameLibrary.merge(baseFiles: ssBase) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    var startTally: [Int: Int] = [:]
    var sampleAt: [Int: String] = [:]
    for r in ssCol.resources(of: type) {
        let d = r.data
        var i = d.startIndex
        while i < d.endIndex {
            if d[i] >= 32 && d[i] < 127 {
                let start = i - d.startIndex
                var j = i, s = ""
                while j < d.endIndex, d[j] >= 32, d[j] < 127 { s.append(Character(UnicodeScalar(d[j]))); j = d.index(after: j) }
                if s.count >= 3 {
                    startTally[start, default: 0] += 1
                    if sampleAt[start] == nil { sampleAt[start] = s }
                }
                i = j
            } else { i = d.index(after: i) }
        }
    }
    print("printable-run START offsets across \(ssCol.resources(of: type).count) \(type.stringValue):")
    for off in startTally.keys.sorted() {
        print(String(format: "  @%-5d ×%-4d  e.g. %@", off, startTally[off]!, String(sampleAt[off]!.prefix(48))))
    }

case "pict":
    guard args.count == 3 || args.count == 4 else { usage() }
    let (collection, _) = loadCollection(args[1])
    guard let id = Int(args[2]), let res = collection.resource(NovaType.pict, id) else {
        FileHandle.standardError.write(Data("error: no PICT \(args[2]) in \(args[1])\n".utf8)); exit(1)
    }
    do {
        let img = try PICT.decode(res.data)
        let out = args.count == 4 ? args[3] : "data/converted/pict_\(id).png"
        try? FileManager.default.createDirectory(atPath: URL(fileURLWithPath: out).deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        if img.writePNG(to: URL(fileURLWithPath: out)) {
            print("PICT \(id): \(img.frameWidth)x\(img.frameHeight) → \(out)")
        } else {
            print("PICT \(id): decoded \(img.frameWidth)x\(img.frameHeight) but PNG write failed")
        }
    } catch {
        FileHandle.standardError.write(Data("error decoding PICT \(id): \(error)\n".utf8)); exit(1)
    }

case "cicn":
    guard args.count == 3 || args.count == 4 else { usage() }
    let (collection, _) = loadCollection(args[1])
    guard let id = Int(args[2]), let res = collection.resource(FourCharCode("cicn")!, id) else {
        FileHandle.standardError.write(Data("error: no cicn \(args[2]) in \(args[1])\n".utf8)); exit(1)
    }
    do {
        let img = try CICN.decode(res.data)
        let out = args.count == 4 ? args[3] : "data/converted/cicn_\(id).png"
        try? FileManager.default.createDirectory(atPath: URL(fileURLWithPath: out).deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        if img.writePNG(to: URL(fileURLWithPath: out)) {
            print("cicn \(id): \(img.frameWidth)x\(img.frameHeight) → \(out)")
        } else {
            print("cicn \(id): decoded \(img.frameWidth)x\(img.frameHeight) but PNG write failed")
        }
    } catch {
        FileHandle.standardError.write(Data("error decoding cicn \(id): \(error)\n".utf8)); exit(1)
    }

case "ditl":
    // Dev tool: decode a classic Mac DITL (dialog item list) resource into its
    // item rects, types, and text/resource-ID payloads — the authoritative pixel
    // layout for a dialog, straight from the game's own resource fork.
    //   novaswift-extract ditl <file> <id>
    guard args.count == 3, let ditlId = Int(args[2]) else { usage() }
    let (ditlCol, _) = loadCollection(args[1])
    guard let ditlRes = ditlCol.resource(FourCharCode("DITL")!, ditlId) else {
        FileHandle.standardError.write(Data("error: no DITL #\(ditlId) in \(args[1])\n".utf8)); exit(1)
    }
    printDITL(ditlRes)

case "dlog":
    // Dev tool: decode a classic Mac DLOG (dialog window template) resource —
    // bounds rect, title, and the DITL id it references.
    //   novaswift-extract dlog <file> <id>
    guard args.count == 3, let dlogId = Int(args[2]) else { usage() }
    let (dlogCol, _) = loadCollection(args[1])
    guard let dlogRes = dlogCol.resource(FourCharCode("DLOG")!, dlogId) else {
        FileHandle.standardError.write(Data("error: no DLOG #\(dlogId) in \(args[1])\n".utf8)); exit(1)
    }
    printDLOG(dlogRes)
    if let itemsID = dlogItemsID(dlogRes), let ditlRes = dlogCol.resource(FourCharCode("DITL")!, itemsID) {
        print("\n--- linked DITL #\(itemsID) ---")
        printDITL(ditlRes)
    }

case "ai":
    // Headless AI simulation: load a real system, populate it with NPCs from its
    // düde/flët spawn table, run the full engine (diplomacy + behaviors + combat)
    // for N seconds, and report what happened. Proves the AI works on real data.
    //   novaswift-extract ai <baseDir> [systemID] [seconds]
    guard args.count >= 2 else { usage() }
    let aiBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let aiGame: NovaGame
    do { aiGame = NovaGame(try GameLibrary.merge(baseFiles: aiBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    let galaxy = Galaxy(game: aiGame)
    let sysID = args.count >= 3 ? (Int(args[2]) ?? 0) : (aiGame.startingSystem()?.id ?? 128)
    let seconds = args.count >= 4 ? (Double(args[3]) ?? 60) : 60
    guard let sys = aiGame.system(sysID) else {
        FileHandle.standardError.write(Data("error: no system \(sysID)\n".utf8)); exit(1)
    }
    let govName = aiGame.govt(sys.government)?.name ?? "Independent"
    print("System #\(sys.id) \"\(sys.name)\"  govt: \(govName) (id \(sys.government))  avgShips: \(sys.averageShips)")
    print("spawn table: \(sys.dudeSpawns.count) dude(s), \(sys.fleetSpawns.count) fleet(s)")
    for (fid, prob) in sys.fleetSpawns {
        if let f = aiGame.fleet(fid) {
            let leadName = aiGame.ship(f.leadShip)?.name ?? "?"
            let esc = f.escorts.map { "\(aiGame.ship($0.shipID)?.name ?? "?")×\($0.min)-\($0.max)" }.joined(separator: ", ")
            print("  fleet #\(fid) (prob \(prob)): lead \(leadName), escorts [\(esc.isEmpty ? "none" : esc)] linkSys \(f.linkSystem)")
        } else {
            print("  fleet #\(fid) (prob \(prob)): <unresolved>")
        }
    }

    // A player ship at the centre (using the system's dominant hull if we can).
    let playerHull = aiGame.ship(sys.spawns.first?.id ?? 128).map { _ in sys.spawns.first!.id } ?? 128
    let player = galaxy.makeShip(playerHull, government: independentGovt, at: Vec2())
        ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
    let world = World(player: player)
    world.diplomacy = galaxy.makeDiplomacy()
    world.galaxy = galaxy
    world.systemContext = galaxy.systemContext(for: sys.id)
    world.spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
    world.spawner?.populate(world)
    print("populated with \(world.npcs.count) NPC(s); jumpRadius \(Int(world.systemContext.jumpRadius))")

    var arrivals = 0, departures = 0, kills = 0, shots = 0, beams = 0
    var landings = 0, launches = 0, disables = 0, jumpIns = 0, scans = 0
    var scansOfPlayer = 0
    var stateHistogram: [String: Int] = [:]
    let dt = 1.0 / 30.0
    let steps = Int(seconds / dt)
    for i in 0..<steps {
        world.step(dt)
        for e in world.events {
            switch e {
            case let .shipArrived(_, _, fromHyperspace): arrivals += 1; if fromHyperspace { jumpIns += 1 }
            case .shipDeparted: departures += 1
            case .shipLanded: landings += 1
            case .shipLaunched: launches += 1
            case .shipDisabled: disables += 1
            case .shipDestroyed: kills += 1
            case .weaponFired: shots += 1
            case .beam(_, _, _, _, let hit, _): if hit { beams += 1 }
            case let .shipScanned(_, targetID, _): scans += 1; if targetID == 0 { scansOfPlayer += 1 }
            default: break
            }
        }
        if i % (steps / 4 == 0 ? 1 : steps / 4) == 0 {
            for npc in world.npcs { stateHistogram[npc.brain?.state.rawValue ?? "?", default: 0] += 1 }
        }
    }

    print(String(repeating: "-", count: 44))
    print("after \(Int(seconds))s:  live NPCs \(world.npcs.count)   projectiles \(world.projectiles.count)")
    print("  arrivals \(arrivals) (jump-in \(jumpIns), launch \(launches))   departures \(departures)   landings \(landings)")
    print("  kills \(kills)   disabled \(disables)   shots fired \(shots)   beam hits \(beams)")
    print("  scans \(scans) (of player \(scansOfPlayer))")
    let hist = stateHistogram.sorted { $0.value > $1.value }
        .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    print("  behavior samples: \(hist)")
    print("  sample ships:")
    for npc in world.npcs.prefix(8) {
        let gov = aiGame.govt(npc.government)?.name ?? "indep"
        let tgt = npc.currentTargetID.map { " → target #\($0)" } ?? ""
        let ab = npc.afterburner != nil ? " AB" : ""
        // Show fleet role: leader id + this ship's formation slot when escorting.
        let wing = npc.brain?.leaderID.map { " wing→#\($0) slot \(npc.brain?.formationSlot ?? 0)" } ?? ""
        let fit = String(format: "wpn %d fuel %3.0f spd %3.0f%@",
                         npc.weapons.count, npc.maxFuel, npc.stats.maxSpeed, ab)
        print(String(format: "    #%-3d %-22@ [%@] %@  sh %3.0f ar %3.0f  %@%@%@",
                     npc.entityID, npc.name as NSString, gov as NSString,
                     npc.brain?.state.rawValue ?? "?",
                     npc.maxShield, npc.maxArmor, fit as NSString, tgt as NSString, wing as NSString))
    }

case "mission-spawn":
    // Headless proof for mission-driven spawning + ShipBehav overrides: build a
    // live system, spawn `count` mission ships of a dude with a goal/behavior,
    // run the sim, and report the objective events + how the ships behaved.
    //   novaswift-extract mission-spawn <baseDir> <sysID> <dudeID> <count> [goal] [behav] [secs]
    guard args.count >= 5,
          let msSysID = Int(args[2]), let msDudeID = Int(args[3]), let msCount = Int(args[4])
    else { usage() }
    let msGoal = MissionShipGoal(rawValue: args.count >= 6 ? (Int(args[5]) ?? -1) : -1) ?? .none
    let msBehav = MissionShipBehavior(raw: args.count >= 7 ? (Int(args[6]) ?? -1) : -1)
    let msSeconds = args.count >= 8 ? (Double(args[7]) ?? 30) : 30

    let msBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let msGame: NovaGame
    do { msGame = NovaGame(try GameLibrary.merge(baseFiles: msBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    let msGalaxy = Galaxy(game: msGame)
    guard let msSys = msGame.system(msSysID) else {
        FileHandle.standardError.write(Data("error: no system \(msSysID)\n".utf8)); exit(1)
    }
    guard let msDude = msGame.dude(msDudeID) else {
        FileHandle.standardError.write(Data("error: no dude \(msDudeID)\n".utf8)); exit(1)
    }
    print("System #\(msSys.id) \"\(msSys.name)\"  spawning \(msCount)× dude #\(msDudeID) \"\(msDude.name)\" (AI \(msDude.aiType))")
    print("  goal: \(msGoal)   behavior: \(msBehav)")

    // A player with a real hull + weapons so attack/protect behaviors have teeth.
    let msPlayerHull = msDude.ships.first?.shipID ?? 128
    let msPlayer = msGalaxy.makeLoadedShip(msPlayerHull, government: independentGovt, at: Vec2())
        ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
    // God-mode the harness player so it doesn't "die" mid-run (player death is
    // app-owned and would just make attackers disengage); this keeps attack/
    // protect behaviors observable for the full window.
    msPlayer.invulnerable = true
    let msWorld = World(player: msPlayer)
    msWorld.diplomacy = msGalaxy.makeDiplomacy()
    msWorld.galaxy = msGalaxy
    msWorld.systemContext = msGalaxy.systemContext(for: msSys.id)
    msWorld.spawner = Spawner(galaxy: msGalaxy, table: SpawnTable(system: msSys))
    msWorld.spawner?.populate(msWorld)
    let ambient = msWorld.npcs.count

    let msIDs = msWorld.spawnMissionShips(missionID: 9999, dudeID: msDudeID, count: msCount,
                                          goal: msGoal, behavior: msBehav)
    // The spawn event is emitted now; the first `step` clears the event buffer,
    // so read it before the loop.
    var spawnedEvents = msWorld.events.reduce(0) { if case .missionShipsSpawned = $1 { return $0 + 1 }; return $0 }
    print("  ambient NPCs \(ambient); placed mission ships \(msIDs) (entity ids)")

    var goalEvents = 0, despawnedEvents = 0
    var playerShots = 0
    var didMidDespawn = false
    let msDt = 1.0 / 30.0
    let msSteps = Int(msSeconds / msDt)
    for i in 0..<msSteps {
        msWorld.step(msDt)
        for e in msWorld.events {
            switch e {
            case .missionShipsSpawned: spawnedEvents += 1
            case let .missionShipGoalReached(mid, eid, goal, byPlayer):
                goalEvents += 1
                print("  [t=\(String(format: "%.1f", Double(i) * msDt))s] GOAL REACHED mission #\(mid) ship #\(eid) goal=\(goal) byPlayer=\(byPlayer)")
            case .missionShipsDespawned: despawnedEvents += 1
            case let .weaponFired(shooter, _, _, _, _): if shooter != 0 { for s in msWorld.missionShips() where s.entityID == shooter { playerShots += 1 } }
            default: break
            }
        }
        // Demonstrate "escorts leave at a plot point": halfway through, an escort
        // objective clears its ships via the despawn seam. Counted from the return
        // value (the event it emits is cleared by the next `step` before the scan).
        if !didMidDespawn, msGoal == .escort, i >= msSteps / 2 {
            didMidDespawn = true
            let gone = msWorld.despawnMissionShips(missionID: 9999)
            if !gone.isEmpty { despawnedEvents += 1 }
            print("  [t=\(String(format: "%.1f", Double(i) * msDt))s] despawnMissionShips → \(gone) left the system")
        }
    }

    let liveMission = msWorld.missionShips(missionID: 9999)
    print(String(repeating: "-", count: 44))
    print("after \(Int(msSeconds))s:  mission ships still live \(liveMission.count) / placed \(msIDs.count)")
    print("  spawn events \(spawnedEvents)  goal-reached events \(goalEvents)  despawn events \(despawnedEvents)")
    print("  player armor \(Int(msPlayer.armor))/\(Int(msPlayer.maxArmor))  shield \(Int(msPlayer.shield))/\(Int(msPlayer.maxShield))  (mission-ship weapon-fire events \(playerShots))")
    for s in liveMission.prefix(6) {
        let tgt = s.currentTargetID.map { " → target #\($0)" } ?? ""
        let lead = s.brain?.leaderID.map { " leader→#\($0)" } ?? ""
        let dis = s.disabled ? " DISABLED" : ""
        print("    #\(s.entityID) \(s.name) [\(msGame.govt(s.government)?.name ?? "indep")] \(s.brain?.state.rawValue ?? "?")\(dis)\(tgt)\(lead)")
    }

case "tribute":
    // Headless proof for Demand Tribute / planetary domination: find a defended
    // stellar, show its defense config, demand tribute at a low rating (laughed
    // off), then at a sufficient rating — launching defense waves. Simulate the
    // player defeating each wave until the pool is exhausted, then demand again
    // to dominate. Reports the whole flow.
    //   novaswift-extract tribute <baseDir> <systemID> [spobID] [rating]
    guard args.count >= 3, let trSysID = Int(args[2]) else { usage() }
    let trBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let trGame: NovaGame
    do { trGame = NovaGame(try GameLibrary.merge(baseFiles: trBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    let trGalaxy = Galaxy(game: trGame)
    guard let trSys = trGame.system(trSysID) else {
        FileHandle.standardError.write(Data("error: no system \(trSysID)\n".utf8)); exit(1)
    }
    // Pick the target stellar: an explicit id, else the first in-system stellar
    // that actually fields a defense fleet.
    let trSpobID: Int
    if args.count >= 4, let sid = Int(args[3]) { trSpobID = sid }
    else if let s = trSys.spobs.compactMap({ trGame.spob($0) }).first(where: { $0.hasDefenseFleet }) {
        trSpobID = s.id
    } else {
        FileHandle.standardError.write(Data("error: no defended stellar in system \(trSysID)\n".utf8)); exit(1)
    }
    guard let trSpob = trGame.spob(trSpobID) else {
        FileHandle.standardError.write(Data("error: no stellar \(trSpobID)\n".utf8)); exit(1)
    }
    let ddName = trGame.dude(trSpob.defenseDude)?.name ?? "?"
    print("Stellar #\(trSpob.id) \"\(trSpob.name)\"  govt \(trGame.govt(trSpob.government)?.name ?? "indep")")
    print("  defense: dude #\(trSpob.defenseDude) \"\(ddName)\"  total \(trSpob.defenseTotal) ships, \(trSpob.defenseWaveSize)/wave  (DefCount raw \(trSpob.defenseCountRaw))")
    print("  tribute: \(trSpob.dailyTributeAmount) cr/day  (Tribute field \(trSpob.tribute), techLevel \(trSpob.techLevel))")

    // A god-mode player so it survives the waves for the full demo.
    let trPlayer = trGalaxy.makeLoadedShip(trSpob.defenseDude >= 128 ? (trGame.dude(trSpob.defenseDude)?.ships.first?.shipID ?? 128) : 128,
                                           government: independentGovt, at: Vec2()) ?? Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100))
    trPlayer.invulnerable = true
    let trWorld = World(player: trPlayer)
    trWorld.galaxy = trGalaxy
    trWorld.diplomacy = trGalaxy.makeDiplomacy()
    trWorld.systemContext = trGalaxy.systemContext(for: trSys.id)

    let required = trWorld.tributeRatingRequired(for: trSpob)
    print("  rating gate: need combat rating ≥ \(required)")
    print(String(repeating: "-", count: 44))

    // 1) Demand with too-low a rating → laughed off.
    trWorld.playerCombatRating = max(0, required - 1)
    let low = trWorld.demandTribute(spobID: trSpobID)
    print("demand @ rating \(trWorld.playerCombatRating): \(low)")

    // 2) Demand with a sufficient rating → the planet fights.
    let rating = args.count >= 5 ? (Int(args[4]) ?? required) : required
    trWorld.playerCombatRating = rating
    let first = trWorld.demandTribute(spobID: trSpobID)
    print("demand @ rating \(rating): \(first)")

    // 3) Simulate the player defeating every wave. Each frame, destroy the
    // living defenders (stand-in for the player winning the fight), step the
    // world so the next wave scrambles, and count as we go.
    var wavesLaunched = 0, defendersDefeated = 0, dominatedAt = -1
    let trDt = 1.0 / 30.0
    for i in 0..<20000 {
        for e in trWorld.events {
            if case .stellarDefendersLaunched(_, let c, _) = e { wavesLaunched += 1; defendersDefeated += 0; _ = c }
        }
        // Destroy any live defenders this frame.
        for npc in trWorld.npcs where npc.spobDefenderOf == trSpobID && npc.isAlive {
            npc.armor = 0; defendersDefeated += 1
        }
        trWorld.step(trDt)
        // Once the field is clear, try to dominate; if defenders remain (a fresh
        // wave), keep fighting.
        if trWorld.npcs.allSatisfy({ $0.spobDefenderOf != trSpobID || !$0.isAlive }) {
            let out = trWorld.demandTribute(spobID: trSpobID)
            if case .dominated = out { dominatedAt = i; break }
        }
    }

    print(String(repeating: "-", count: 44))
    print("waves launched: \(wavesLaunched)   defenders defeated: \(defendersDefeated)")
    if dominatedAt >= 0 {
        print("RESULT: stellar #\(trSpobID) DOMINATED after \(String(format: "%.1f", Double(dominatedAt) * trDt))s of fighting")
        print("  (host would now add #\(trSpobID) to PlayerState.dominatedStellars, fire OnDominate, and pay \(trSpob.dailyTributeAmount) cr/day)")
    } else {
        print("RESULT: not dominated within the step cap (defenders remaining: \(trWorld.liveDefenders(of: trSpobID)))")
    }
    let dominatedEvents = trWorld.events.contains { if case .stellarDominated = $0 { return true }; return false }
    print("  final-frame stellarDominated event present: \(dominatedEvents)")

case "mission":
    // Decode a single mission and print its resolved fields + text. Validates
    // the mïsn decoder against real data.
    //   novaswift-extract mission <baseDir> <id>
    guard args.count == 3, let id = Int(args[2]) else { usage() }
    let mBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let mGame: NovaGame
    do { mGame = NovaGame(try GameLibrary.merge(baseFiles: mBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    guard let m = mGame.mission(id) else {
        FileHandle.standardError.write(Data("error: no mission #\(id)\n".utf8)); exit(1)
    }
    func nz(_ s: String) -> String { s.isEmpty ? "—" : s }
    print("""
    mïsn #\(m.id): \(m.name)
      offered:   loc=\(m.availLocation)  stellar=\(m.availStellar)  random=\(m.availRandom)%  \
    minRecord=\(m.availRecord) minRating=\(m.availRating) shipType=\(m.availShipType)
      availBits: \(nz(m.availBits))
      travel→\(m.travelStellar)  return→\(m.returnStellar)  \
    cargo=\(m.cargoType)×\(m.cargoQty) pickup=\(m.cargoPickup) dropoff=\(m.cargoDropoff)
      pay:       \(m.pay)  compGovt=\(m.compRewardGovt) compLegal=\(m.compLegalReward)  \
    timeLimit=\(m.timeLimit) canAbort=\(m.canAbort)
      ships:     count=\(m.shipCount) syst=\(m.shipSystem) dude=\(m.shipDude) goal=\(m.shipGoal) \
    aux=\(m.auxShipCount)
      flags:     0x\(String(m.flags1, radix: 16))/0x\(String(m.flags2, radix: 16))  \
    dateInc=\(m.datePostIncrement)  weight=\(m.displayWeight)
      onAccept:  \(nz(m.onAccept))
      onSuccess: \(nz(m.onSuccess))
      onFailure: \(nz(m.onFailure))
      onAbort:   \(nz(m.onAbort))
      onShipDone:\(nz(m.onShipDone))
      buttons:   [\(nz(m.acceptButton))] [\(nz(m.refuseButton))]
      offerText(\(m.offerTextID)): \(nz(String(mGame.descText(m.offerTextID).prefix(120))))
      compText(\(m.completionText)):  \(nz(String(mGame.descText(m.completionText).prefix(120))))
    """)

case "missions":
    // Parse ALL missions and report aggregate stats — a bulk validation that the
    // decoder handles every real mission without producing garbage.
    //   novaswift-extract missions <baseDir>
    guard args.count == 2 else { usage() }
    let msBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let msGame: NovaGame
    do { msGame = NovaGame(try GameLibrary.merge(baseFiles: msBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
    let all = msGame.missions()
    var withBits = 0, withAccept = 0, withSuccess = 0, withShips = 0, withPay = 0
    var badBits = 0
    for m in all {
        if !m.availBits.isEmpty { withBits += 1 }
        if !m.onAccept.isEmpty { withAccept += 1 }
        if !m.onSuccess.isEmpty { withSuccess += 1 }
        if m.hasShipObjective { withShips += 1 }
        if m.pay != 0 { withPay += 1 }
        // Sanity: control-bit strings should be ASCII-ish, not binary garbage.
        if m.availBits.unicodeScalars.contains(where: { $0.value > 0x7E || ($0.value < 0x20 && $0 != " ") }) {
            badBits += 1
        }
    }
    print("""
    parsed \(all.count) missions
      with availBits:   \(withBits)
      with onAccept:    \(withAccept)
      with onSuccess:   \(withSuccess)
      with ship goal:   \(withShips)
      with pay:         \(withPay)
      garbled bit-str:  \(badBits)   (should be 0)
    """)
    // Show a handful so a human can eyeball correctness.
    for m in all.prefix(6) {
        print(String(format: "  #%-4d %-32@ bits=%@", m.id, m.name as NSString,
                     m.availBits.isEmpty ? "—" : m.availBits))
    }

case "story":
    // End-to-end story-engine playthrough on REAL data: drive the actual first
    // Vell-os storyline missions through the engine and show the control-bit
    // chain advancing. Proves the mission runtime works on shipping game data.
    //   novaswift-extract story <baseDir> [firstMissionID]
    guard args.count >= 2 else { usage() }
    let stBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let stGame: NovaGame
    do { stGame = NovaGame(try GameLibrary.merge(baseFiles: stBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    let firstID = args.count >= 3 ? (Int(args[2]) ?? 128) : 128
    let services = LoggingGameServices()
    let pilot = PlayerState(pilotName: "Test Pilot", shipType: stGame.ships().first?.id ?? 128,
                            credits: 10_000, currentSystem: 128)
    let engine = StoryEngine(game: stGame, player: pilot, services: services)

    func bitsSet() -> String {
        engine.player.setBits.sorted().map { "b\($0)" }.joined(separator: " ")
    }
    guard let m = stGame.mission(firstID) else {
        FileHandle.standardError.write(Data("error: no mission #\(firstID)\n".utf8)); exit(1)
    }
    print("=== Story playthrough starting at mïsn #\(firstID): \(m.name) ===\n")
    print("availBits: \(m.availBits.isEmpty ? "(none)" : m.availBits)")
    print("eligible at mission computer? \(engine.isEligible(m, at: .missionComputer, spobID: nil))")

    print("\n-- accepting --")
    engine.accept(firstID)
    print("bits after accept: [\(bitsSet())]")
    print("credits: \(engine.player.credits)   active missions: \(engine.player.activeMissions.map { $0.missionID })")

    print("\n-- completing (landing at return stellar #\(m.returnStellar)) --")
    if m.returnStellar >= 128 {
        engine.playerLanded(onSpob: m.returnStellar)
    } else {
        engine.completeMission(firstID)
    }
    print("bits after success: [\(bitsSet())]")
    print("credits: \(engine.player.credits)   completed: \(engine.player.completedMissions.sorted())")

    // Show the chain: the very next storyline mission and whether its gate now
    // passes (the engine evaluating a real, hand-authored NCB expression).
    if let next = stGame.mission(firstID + 1) {
        print("\n-- next storyline mission #\(next.id): \(next.name) --")
        print("  gate: \(next.availBits.isEmpty ? "(none)" : next.availBits)")
        let ok = engine.evaluate(test: next.availBits)
        print("  gate passes now? \(ok)")
        if !ok {
            // Explain which sub-clauses are blocking, so the gate is legible.
            let blockers = next.availBits
                .split(whereSeparator: { "()&|! ".contains($0) })
                .compactMap { tok -> String? in
                    guard tok.hasPrefix("b"), let n = Int(tok.dropFirst()) else { return nil }
                    return engine.player.isBitSet(n) ? "\(tok)=set" : nil
                }
            if !blockers.isEmpty {
                print("  (blocked because these bits are set: \(Set(blockers).sorted().joined(separator: " ")))")
                print("  → authentic EV Nova pacing: a later cron/event clears the pending bit.")
            }
        }
    }
    print("\nservices log:")
    for line in services.log { print("  · \(line)") }

case "storylines":
    // Reconstruct every campaign from the mission bit-graph and show a pilot's
    // progress + next-step guidance (the data behind the in-game story guide).
    //   novaswift-extract storylines <baseDir> [setBits: b350,b6666,...]
    guard args.count >= 2 else { usage() }
    let slBase = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: args[1]))
    let slGame: NovaGame
    do { slGame = NovaGame(try GameLibrary.merge(baseFiles: slBase)) }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

    var slPlayer = PlayerState(currentSystem: 128)
    if args.count >= 3 {
        for tok in args[2].split(separator: ",") where tok.hasPrefix("b") {
            if let n = Int(tok.dropFirst()) { slPlayer.setBit(n) }
        }
    }
    let analyzer = StorylineAnalyzer(game: slGame)
    let lines = analyzer.storylines(for: slPlayer)
    print("reconstructed \(lines.count) storylines (+\(analyzer.untaggedMissionCount) untagged one-off missions)\n")
    for s in lines.prefix(args.count >= 3 ? 40 : 16) {
        let bar = String(repeating: "█", count: Int(s.progressFraction * 10))
            + String(repeating: "░", count: 10 - Int(s.progressFraction * 10))
        print("▐ \(s.title)  [\(bar)] \(s.completedCount)/\(s.totalCount)")
        if let cur = s.currentStepID, let step = s.steps.first(where: { $0.missionID == cur }) {
            print("    → next: #\(step.missionID) “\(step.displayName)”  [\(step.status.rawValue)]")
            if step.status == .available {
                print("      get it at: \(step.offeredAt)")
                print("      objective: \(step.objective)   reward: \(step.reward)")
            } else if step.status == .locked, !step.blockers.isEmpty {
                for b in step.blockers.prefix(3) {
                    let need = b.needsSet ? "set" : "clear"
                    let via = b.unlockedBy.first?.hint ?? "an as-yet-unknown event"
                    print("      blocked: needs b\(b.bit) \(need) — via \(via)")
                }
            }
        }
    }

default:
    usage()
}
