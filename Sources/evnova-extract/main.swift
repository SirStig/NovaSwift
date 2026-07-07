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

default:
    usage()
}
