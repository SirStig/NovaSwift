import Foundation

/// Registry of editable schemas, one per EV Nova resource type. The form
/// schemas live in `ResourceSchemas+Generated.swift` (ship, spöb, mïsn, …;
/// layouts reconciled against the typed decoders and the original loader's
/// padding sizes) and the text/graphic/sound types are flagged with an
/// `editorKind` so the UI opens a purpose-built editor instead.
public enum ResourceSchemas {

    /// Every type with a field-level schema, in a stable UI order.
    public static let all: [ResourceSchema] = [
        makeShipSchema(), makeOutfitSchema(), makeWeaponSchema(), makeSpobSchema(), makeSystSchema(), makeGovtSchema(),
        makeMissionSchema(), makeCronSchema(), makePersSchema(), makeDudeSchema(), makeFleetSchema(), makeCharSchema(),
        makeBoomSchema(), makeSpinSchema(), makeShanSchema(), makeJunkSchema(), makeOopsSchema(), makeNebulaSchema(),
        makeRankSchema(), makeRoidSchema(), makeIntfSchema(), makeColrSchema(), makeDescSchema(),
    ]

    private static let byType: [FourCharCode: ResourceSchema] =
        Dictionary(all.map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

    public static func schema(for type: FourCharCode) -> ResourceSchema? { byType[type] }

    /// Types handled by a dedicated (non-form) editor.
    private static let special: [FourCharCode: (EditorKind, String)] = [
        NovaType.strList: (.text, "String List"),
        FourCharCode("STR ")!: (.text, "String"),
        GraphicsEnhancementType.descriptor: (.text, "HD Graphics Descriptor (JSON)"),
        GraphicsEnhancementType.blob: (.raw, "HD Graphics Asset"),
        NovaType.pict: (.graphic, "Picture"),
        NovaType.rleD: (.graphic, "Sprite Sheet (32-bit)"),
        NovaType.rle8: (.graphic, "Sprite Sheet (8-bit)"),
        NovaType.cicn: (.graphic, "Color Icon"),
        NovaType.ppat: (.graphic, "Pixel Pattern"),
        NovaType.ppatAlt: (.graphic, "Pixel Pattern"),
        NovaType.snd: (.sound, "Sound"),
        NovaType.ditl: (.raw, "Dialog Item List"),
        NovaType.dlog: (.raw, "Dialog Template"),
        // `dsïg` #128 (2-4 bytes, e.g. 0000 or 0352028a) is a signature that plug-in editors stamp
        // into a file. The game never asks for it; it is kept byte-exact on save and nothing else.
        FourCharCode("dsïg")!: (.raw, "Editor Signature"),
    ]

    public static func editorKind(for type: FourCharCode) -> EditorKind {
        if let s = byType[type] { return s.editorKind }
        return special[type]?.0 ?? .raw
    }

    public static func displayName(for type: FourCharCode) -> String {
        byType[type]?.displayName ?? special[type]?.1 ?? type.stringValue
    }

    /// Types the editor knows about (schema or special editor), form types first.
    public static var knownTypes: [FourCharCode] {
        all.map(\.type) + special.keys.sorted()
    }


    /// `dësc`: NUL-terminated text, then a fixed 36-byte trailer (PICT id,
    /// 32-byte movie name, flags). Text editing goes through `DescRecord`; the
    /// schema only carries identity and the minimum record (an empty string +
    /// trailer).
    static func makeDescSchema() -> ResourceSchema {
        ResourceSchema(type: NovaType.desc, displayName: "Description", editorKind: .text,
                       minimumSize: 1 + DescRecord.trailerSize, fields: [])
    }
}

extension ContextualValue {
    /// What `oütf` ModVal means for each ModType (Nova Bible, oütf section).
    static func outfitModValue(selector: String) -> ContextualValue {
        func m(_ l: String, _ t: String? = nil, bits: [FlagBit] = []) -> Meaning {
            Meaning(l, refType: t.map { ty($0) }, flagBits: bits)
        }
        let cloak: [FlagBit] = [.f(0x1, "Faster fading"), .f(0x2, "Visible on radar"), .f(0x4, "Drops shields on activation"),
                                .f(0x8, "Deactivates when damaged"), .f(0x10, "1 fuel/sec"), .f(0x20, "2 fuel/sec"),
                                .f(0x40, "4 fuel/sec"), .f(0x80, "8 fuel/sec"), .f(0x100, "1 shield/sec"),
                                .f(0x200, "2 shield/sec"), .f(0x400, "4 shield/sec"), .f(0x800, "8 shield/sec"),
                                .f(0x1000, "Area cloak")]
        let scanner: [FlagBit] = [.f(0x1, "Reveal cloaked ships on radar"), .f(0x2, "Reveal cloaked ships on screen"),
                                  .f(0x4, "Allow targeting of untargetable ships"), .f(0x8, "Allow targeting of cloaked ships")]
        let table: [Int: Meaning] = [
            1: m("Weapon", "wëap"), 3: m("Ammo for weapon", "wëap"),
            2: m("Tons of cargo space"), 4: m("Shield points"), 5: m("Recharge speed (1000 = 1 pt/frame)"),
            6: m("Armor points"), 7: m("Acceleration added"), 8: m("Speed added"), 9: m("Turn rate (100 = 30°/s)"),
            12: m("Fuel (100 = 1 jump)"), 15: m("Fuel use per second"), 16: m("Map: jumps away (-1 inhabited independents, -1000- govt class)"),
            17: m("Cloak behaviour", bits: cloak), 18: m("Frames per fuel unit (negative sucks fuel)"),
            21: m("Govt to clear record with (-1 = all)", "gövt"),
            22: m("Days of hyperspace time"), 23: m("No-jump zone radius change"), 24: m("Interference reduction"),
            25: m("Marines (crew, or -1..-100 = % capture odds)"), 27: m("Outfit whose maximum is raised", "oütf"),
            28: m("Murk change"), 29: m("Armor recharge speed"), 30: m("Cloak scanner", bits: scanner),
            32: m("Extra jumps"), 33: m("Jamming type 1"), 34: m("Jamming type 2"), 35: m("Jamming type 3"), 36: m("Jamming type 4"),
            39: m("Ion dissipation (100 = 1 pt/tick)"), 40: m("Ion capacity"), 43: m("Paint colour (15-bit 0RRRRRGGGGGBBBBB)"),
            44: m("Govt class inhibited (-1 = all)"), 45: m("Max guns change"), 46: m("Max turrets change"),
            47: m("Description shown after the bomb", "dësc"), 48: m("Govt class fooled"),
            50: m("Explosion on self-destruct", "bööm"),
        ]
        return ContextualValue(selector: selector, meanings: table, fallback: m("Unused"))
    }

    /// `spöb` CustSndID / CustPicID: on hypergates and wormholes (Flags2 0x1000 /
    /// 0x2000) they are an exit angle / first-open frame, not a resource id.
    static func stellarMedia(_ type: String, minID: Int) -> ContextualValue {
        ContextualValue(selector: "flags2", selectorMask: 0x3000,
                        meanings: [0: Meaning(type == "snd " ? "Ambient sound" : "Custom landscape", refType: ty(type), minValue: minID)],
                        fallback: Meaning(type == "snd " ? "Ship exit angle (0-359, else random)" : "First open frame"))
    }

    /// `wëap` AmmoType: for fighter bays (Guidance 99) it is the carried ship's
    /// id; otherwise it indexes the weapon whose ammo is used.
    static let weaponAmmoType = ContextualValue(
        selector: "guidance",
        meanings: [99: Meaning("Carried ship", refType: ty("shïp"), minValue: 128)],
        fallback: Meaning("Ammo from weapon (index)", refType: ty("wëap"), idBase: 128, minValue: 0))
}
