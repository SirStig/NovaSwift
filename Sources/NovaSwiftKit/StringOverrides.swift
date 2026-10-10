import Foundation

// Original string-table behaviour that plug-ins and total conversions rely on:
// `EVNova.ini` overrides (Resource_LoadStringEntry 0x004b8ca0), the `STR `
// single-string patches of the display-name tables
// (NovaData_LoadDisplayNamePstringTables 0x004c7040) and the `l33t` easter egg
// (Ui_LoadSelectionDialogResource 0x004c6d50).

/// `[<STR# id>]` / `S<n> = "text"` overrides read from the data folder's
/// `EVNova.ini`. A non-empty value replaces entry `n` (1-based) of that STR#.
public enum IniStringOverrides {
    /// Parse the ini (Mac Roman, CR/LF line ends, `;` comments). Keys are
    /// `[STR# id][n]`; unknown sections and keys are ignored.
    public static func parse(_ data: Data) -> [Int: [Int: String]] {
        let text = String(data: data, encoding: .macOSRoman) ?? ""
        var out: [Int: [Int: String]] = [:]
        var section: Int?
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                section = line.firstIndex(of: "]").flatMap { Int(line[line.index(after: line.startIndex)..<$0].trimmingCharacters(in: .whitespaces)) }
                continue
            }
            guard let section, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key.count > 1, key.first == "S" || key.first == "s", let n = Int(key.dropFirst()), n > 0 else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { out[section, default: [:]][n] = value }
        }
        return out
    }
}

extension StringListRes {
    /// A list with entries replaced (1-based) by `overrides`, growing the list if needed.
    func applying(_ overrides: [Int: String]) -> StringListRes {
        var s = strings
        for (n, v) in overrides.sorted(by: { $0.key < $1.key }) where n > 0 && n <= 4096 {
            while s.count < n { s.append("") }
            s[n - 1] = v
        }
        return StringListRes(id: id, name: name, strings: s)
    }
}

extension NovaGame {
    /// The `STR ` resource `id` as the original sees it: present even when empty.
    func rawSingleString(_ id: Int) -> String? {
        guard let d = resources.resource(FourCharCode("STR ")!, id)?.data else { return nil }
        guard !d.isEmpty else { return "" }
        let length = Int(d[d.startIndex])
        guard d.count >= 1 + length else { return nil }
        return String(data: d.subdata(in: (d.startIndex + 1)..<(d.startIndex + 1 + length)), encoding: .macOSRoman)
    }

    /// `STR ` `overrideBase + index` when present (even if empty), else entry
    /// `index + 1` of STR# `list`; nil when neither exists.
    public func patchedStringIfPresent(list: Int, index: Int, overrideBase: Int) -> String? {
        rawSingleString(overrideBase + index) ?? stringList(list)?.string(at: index + 1)
    }

    /// As `patchedStringIfPresent`, "" when neither exists.
    public func patchedString(list: Int, index: Int, overrideBase: Int) -> String {
        patchedStringIfPresent(list: list, index: index, overrideBase: overrideBase) ?? ""
    }

    /// Commodity names (`STR ` 9000+i over STR# 4000), 256 entries.
    public func commodityDisplayName(_ index: Int) -> String? {
        patchedStringIfPresent(list: 4000, index: index, overrideBase: 9000)
    }
    /// Mission cargo names, `<CT>` (`STR ` 9100+i over STR# 4001), 256 entries.
    public func cargoTypeName(_ index: Int) -> String? {
        guard (0..<256).contains(index) else { return nil }
        return patchedStringIfPresent(list: 4001, index: index, overrideBase: 9100)
    }
    /// Mission cargo short names for the status panel (`STR ` 9200+i over STR# 4002), 256 entries.
    public func cargoShortName(_ index: Int) -> String? {
        guard (0..<256).contains(index) else { return nil }
        return patchedStringIfPresent(list: 4002, index: index, overrideBase: 9200)
    }
    /// Cargo abbreviations for the status panel rows (`STR ` 9400+i over STR# 4003), 6 entries.
    public func cargoAbbreviation(_ index: Int) -> String? {
        guard (0..<6).contains(index) else { return nil }
        return patchedStringIfPresent(list: 4003, index: index, overrideBase: 9400)
    }
}

extension NovaDescFormatter {
    /// The `l33t` transform of a `dësc` string. Per character, independent
    /// `roll() < 2` (a `Rand(3)`): a/A to 4, e/E to 3, i/I to 1, o/O to 0.
    /// "you" becomes "j00" unconditionally when the `y` is more than 4
    /// characters from the end (the `o` has not been rolled yet at that point).
    /// `<TAG>` wildcards are left alone so a later expansion still works.
    public static func leetSpeak(_ s: String, roll: () -> Int) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        var inTag = false
        while i < c.count {
            let ch = c[i]
            if inTag { out.append(ch); if ch == ">" { inTag = false }; i += 1; continue }
            if ch == "<" { inTag = true; out.append(ch); i += 1; continue }
            if (ch == "y" || ch == "Y"), i < c.count - 4, c[i + 1] == "o", c[i + 2] == "u" {
                out += "j00"; i += 3; continue
            }
            switch ch {
            case "a", "A": out.append(roll() < 2 ? "4" : ch)
            case "e", "E": out.append(roll() < 2 ? "3" : ch)
            case "i", "I": out.append(roll() < 2 ? "1" : ch)
            case "o", "O": out.append(roll() < 2 ? "0" : ch)
            default: out.append(ch)
            }
            i += 1
        }
        return out
    }
}
