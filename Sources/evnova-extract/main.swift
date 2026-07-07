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

default:
    usage()
}
