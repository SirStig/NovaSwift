import Foundation
import NovaSwiftKit

/// Opens classic Mac archives (.sit, .hqx, .sit.hqx, .sea, .bin / MacBinary,
/// and any nesting of those) and writes their contents to disk.
///
/// Fork handling: GameLibrary reads resource containers from a file's *data*
/// bytes and auto-detects the classic resource-fork layout, so a resource
/// fork is written out as an ordinary `.ndat` file next to the data fork.
/// That works on every platform (no `..namedfork/rsrc`, no AppleDouble).
public enum MacArchive {
    public static let fileExtensions: Set<String> = ["sit", "hqx", "bin", "macbin", "sea", "sitx"]

    /// Whether `data` is something this extractor should be tried on.
    public static func recognizes(_ data: Data, name: String? = nil) -> Bool {
        let b = [UInt8](data.prefix(8192))
        if StuffIt.kind(b) != nil || BinHex.bodyStart(b) != nil { return true }
        if let name, fileExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        return MacBinary.decode([UInt8](data)) != nil
    }

    /// Fully unwraps `data` into a flat list of files and folders.
    public static func extract(_ data: Data, name: String? = nil) throws -> [MacFile] {
        try expand([UInt8](data), isSea: (name as NSString?)?.pathExtension.lowercased() == "sea", depth: 0)
    }

    private static func expand(_ b: [UInt8], isSea: Bool, depth: Int) throws -> [MacFile] {
        guard depth < 5 else { throw MacArchiveError.corrupt("archives nested too deeply") }
        if StuffIt.kind(b) != nil { return try StuffIt.extract(b) }
        if BinHex.bodyStart(b) != nil { return try unwrap(try BinHex.decode(b), isSea: isSea, depth: depth) }
        if let f = MacBinary.decode(b) { return try unwrap(f, isSea: isSea, depth: depth) }
        if isSea, let at = StuffIt.findEmbedded(b) { return try StuffIt.extract(b, at: at) }
        throw MacArchiveError.unrecognized
    }

    /// A wrapper (BinHex/MacBinary) yielded one file: if that file is itself an
    /// archive, open it; otherwise it is the payload.
    private static func unwrap(_ f: MacFile, isSea: Bool, depth: Int) throws -> [MacFile] {
        let sea = isSea || f.fileType == "APPL" || (f.name as NSString).pathExtension.lowercased() == "sea"
        if StuffIt.kind(f.data) != nil || BinHex.bodyStart(Array(f.data.prefix(8192))) != nil
            || (f.rsrc.isEmpty && MacBinary.decode(f.data) != nil) {
            return try expand(f.data, isSea: false, depth: depth + 1)
        }
        if sea, let at = StuffIt.findEmbedded(f.data) { return try StuffIt.extract(f.data, at: at) }
        if sea, let at = StuffIt.findEmbedded(f.rsrc) { return try StuffIt.extract(f.rsrc, at: at) }
        return [f]
    }

    // MARK: Writing

    static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n"))
        if t == "." || t == ".." || t.isEmpty { t = "_" + t }
        return t
    }

    /// Writes `files` under `dest`, recreating folders. Returns the number of files written.
    @discardableResult
    public static func write(_ files: [MacFile], to dest: URL) throws -> Int {
        let fm = FileManager.default
        var written = 0
        for f in files {
            var dir = dest
            for c in f.folders { dir.appendPathComponent(sanitize(c), isDirectory: true) }
            if f.isFolder {
                try fm.createDirectory(at: dir.appendingPathComponent(sanitize(f.name), isDirectory: true),
                                       withIntermediateDirectories: true)
                continue
            }
            // Finder custom-icon stubs and similar junk.
            if f.name.hasPrefix("Icon") && f.name.unicodeScalars.last == "\r" { continue }
            if f.name == ".DS_Store" || f.name == "__MACOSX" { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = sanitize(f.name)
            let ext = (name as NSString).pathExtension.lowercased()
            let isResourceName = GameLibrary.resourceExtensions.contains(ext)

            if !f.data.isEmpty {
                try Data(f.data).write(to: dir.appendingPathComponent(name))
                written += 1
            }
            if !f.rsrc.isEmpty {
                // Resource fork -> a data-fork-style resource file the loader understands.
                let rsrcName: String
                if f.data.isEmpty { rsrcName = isResourceName ? name : name + ".ndat" }
                else { rsrcName = name + ".rsrc.ndat" }
                try Data(f.rsrc).write(to: dir.appendingPathComponent(rsrcName))
                written += 1
            }
        }
        return written
    }

    /// Extract the file at `url` into `dest`.
    @discardableResult
    public static func extractArchive(at url: URL, name: String? = nil, to dest: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let files = try extract(data, name: name ?? url.lastPathComponent)
        let n = try write(files, to: dest)
        guard n > 0 else { throw MacArchiveError.corrupt("the archive contains no files") }
        return n
    }
}
