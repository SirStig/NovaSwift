import Foundation
import EVNovaKit

// evnova-extract — inspect EV Nova resource containers (classic fork / .ndat / BRGR .rez).
//
//   evnova-extract types <file>            Summary: each resource type and count
//   evnova-extract list  <file> <TYPE>     List resources of a type (id, name, size)
//   evnova-extract info  <file>            Format + totals

func usage() -> Never {
    let name = "evnova-extract"
    FileHandle.standardError.write(Data("""
    \(name) — inspect EV Nova resource containers

    USAGE:
      \(name) info    <file>
      \(name) types   <file>
      \(name) list    <file> <TYPE>
      \(name) sprites <file> [outDir]     Decode rlëD sprites → PNG sheets
      \(name) library <baseDir> [plugDir] Discover base + plug-ins; show override effect
      \(name) ship    <baseDir> [id]      Decode ship stats + resolve its sprite → PNG
      \(name) system  <baseDir> [id]      List a system's planets + resolve sprites
      \(name) sounds  <baseDir>           List all snd resources (id, name, rate, length)
      \(name) sound   <baseDir> <id> [out] Decode one snd → WAV (default: <id>.wav)

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
      shieldRecharge \(s.shieldRecharge)  armorRecharge \(s.armorRecharge)  energyRecharge \(s.energyRecharge)
      cargo \(s.cargoSpace)
    """)
    if let shan = game.shan(s.id) {
        print("  shän #\(shan.id): baseSprite spïn \(shan.baseSpriteID)  frames \(shan.baseSetCount)  \(shan.baseWidth)x\(shan.baseHeight)")
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
    //   evnova-extract raw <baseDir> <TYPE> <id>
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
    // code pairs) and print each field with its running byte offset. Authoritative
    // field layout for the on-disk resource bodies.
    //   evnova-extract tmpl <Templates.rsrc> <id>
    guard args.count == 3, let id = Int(args[2]) else { usage() }
    let (tcol, _) = loadCollection(args[1])
    guard let tr = tcol.resource(FourCharCode("TMPL")!, id) else {
        FileHandle.standardError.write(Data("error: no TMPL #\(id)\n".utf8)); exit(1)
    }
    // Byte size of a template field type code (variable ones return nil).
    func tmplSize(_ code: String) -> Int? {
        switch code {
        case "DBYT", "UBYT", "HBYT", "CHAR", "BFLG", "FBYT": return 1
        case "DWRD", "UWRD", "HWRD", "BOOL", "WFLG", "FWRD", "RSID", "AWRD": return 2
        case "DLNG", "ULNG", "HLNG", "LFLG", "FLNG", "PNT ", "TNAM", "KEYB": return 4
        case "RECT": return 8
        default:
            if code.first == "C", let n = Int(code.dropFirst(), radix: 16) { return n } // Cnnn fixed C string
            if code.first == "P", let n = Int(code.dropFirst(), radix: 16) { return n + 1 } // Pnnn pascal
            return nil // PSTR/CSTR/HEXD/OCNT/LSTB/LSTE/ZCNT etc — variable/structural
        }
    }
    let tdata = tr.data
    var tp = tdata.startIndex
    var tByteOff = 0
    print("TMPL #\(tr.id) \"\(tr.name)\" — field layout (offset, type, label):")
    while tp < tdata.endIndex {
        let len = Int(tdata[tp]); tp += 1
        guard tp + len + 4 <= tdata.endIndex else { break }
        let label = String(data: tdata[tp..<tp+len], encoding: .macOSRoman) ?? "?"
        tp += len
        let code = String(data: tdata[tp..<tp+4], encoding: .macOSRoman) ?? "????"
        tp += 4
        let sz = tmplSize(code)
        let offStr = sz == nil ? "  ?  " : String(format: "%5d", tByteOff)
        print("  @\(offStr)  \(code)  \(label)")
        if let s = sz { tByteOff += s }
    }

case "strscan":
    // Dev tool: across all resources of a type, find printable ASCII runs (>=3
    // chars) and tally their START offsets — reveals fixed string-field offsets.
    //   evnova-extract strscan <baseDir> <TYPE>
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

default:
    usage()
}
