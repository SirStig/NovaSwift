import Foundation

// EV Nova authors every one of its dialogs as a classic Mac `DLOG` (window
// template) plus a `DITL` (dialog item list) in `Nova.rez` — 41 of them, from
// the Spaceport landing screen to the New Pilot sheet. The `DITL` holds the
// *authoritative pixel rectangle* for every control on the screen.
//
// Those rects are ground truth. Anything that hand-copies them into Swift
// constants drifts (and has: `PlunderView` sized its buttons 63pt wide where
// `DITL` #1011 says 89). Decode them at runtime instead, and lay the UI out
// from the resource.
//
// Byte layouts are the standard Inside Macintosh ones, verified against the
// real resources in the shipped `Nova.rez`:
//
//   DITL:  int16 count-1
//          per item: 4 bytes (nil handle placeholder)
//                    8 bytes rect, as int16 top, left, bottom, right
//                    1 byte  type   (high bit set ⇒ *disabled*)
//                    1 byte  length of payload
//                    N bytes payload, then padded to an even offset
//
//   DLOG:  8 bytes bounds rect (top, left, bottom, right)
//          int16 procID, int16 visible, int16 goAway, int32 refCon,
//          int16 itemsID (the DITL to pair with), then a Pascal title string
//
//   STR#:  int16 count, then `count` Pascal strings back to back

// MARK: - Items

/// What kind of control a `DITL` entry describes. EV Nova draws its own chrome,
/// so in practice nearly every item in `Nova.rez` is a `.userItem` whose rect is
/// the only thing that matters — the label text lives in the view, not the
/// resource. The remaining cases are decoded for completeness (and for plug-ins,
/// which may use the standard toolbox controls).
public enum DITLItemKind: Equatable, Sendable {
    case userItem
    case button
    case checkbox
    case radioButton
    case resControl
    case statText
    case editText
    case icon
    case picture
    case unknown(Int)

    init(rawType: Int) {
        switch rawType & 0x7F {
        case 0:  self = .userItem
        case 4:  self = .button
        case 5:  self = .checkbox
        case 6:  self = .radioButton
        case 7:  self = .resControl
        case 8:  self = .statText
        case 16: self = .editText
        case 32: self = .icon
        case 64: self = .picture
        default: self = .unknown(rawType & 0x7F)
        }
    }

    /// True when the payload bytes are a Mac Roman label rather than a resource id.
    var payloadIsText: Bool {
        switch self {
        case .button, .checkbox, .radioButton, .statText, .editText: return true
        default: return false
        }
    }

    /// True when the payload bytes are a big-endian 16-bit resource id.
    var payloadIsResourceID: Bool {
        switch self {
        case .icon, .picture, .resControl: return true
        default: return false
        }
    }
}

/// One entry in a `DITL`: where it sits, what it is, and whatever the resource
/// carried alongside it.
public struct DITLItem: Equatable, Sendable {
    /// Zero-based position in the `DITL`. This is the stable handle a view uses
    /// to bind content to a rect — the game itself addresses items by index.
    public let index: Int
    public let rect: NovaRect
    public let kind: DITLItemKind
    /// `false` when the resource's type byte had its high bit set. EV Nova uses
    /// this to mark items it draws but never hit-tests (panels, backdrops).
    public let isEnabled: Bool
    /// Label text, for the kinds that carry one; empty otherwise.
    public let text: String
    /// Referenced resource id, for icon/picture/control items; nil otherwise.
    public let resourceID: Int?

    public init(index: Int, rect: NovaRect, kind: DITLItemKind,
                isEnabled: Bool, text: String = "", resourceID: Int? = nil) {
        self.index = index
        self.rect = rect
        self.kind = kind
        self.isEnabled = isEnabled
        self.text = text
        self.resourceID = resourceID
    }
}

// MARK: - DITL

/// A decoded dialog item list — the pixel layout of one EV Nova screen.
public struct DITLRes: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let items: [DITLItem]

    public init(_ resource: Resource) {
        id = resource.id
        name = resource.name
        items = Self.decodeItems(resource.data)
    }

    /// Item by `DITL` index, or nil when the resource is shorter than expected.
    /// Views bind content through this, so a truncated/absent resource degrades
    /// to "no rect" rather than trapping.
    public subscript(index: Int) -> DITLItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// The tightest rect containing every item. Some EV Nova dialogs (notably
    /// #1000 "Spaceport") place items past their own `DLOG` bounds, so this is
    /// unioned into the design size rather than trusting the window rect alone.
    public var itemBounds: NovaRect {
        guard let first = items.first else { return NovaRect(top: 0, left: 0, bottom: 0, right: 0) }
        return items.dropFirst().reduce(first.rect) { acc, item in
            NovaRect(top: min(acc.top, item.rect.top),
                     left: min(acc.left, item.rect.left),
                     bottom: max(acc.bottom, item.rect.bottom),
                     right: max(acc.right, item.rect.right))
        }
    }

    private static func decodeItems(_ d: Data) -> [DITLItem] {
        guard d.count >= 2 else { return [] }
        let base = d.startIndex

        func u8(_ off: Int) -> Int { Int(d[base + off]) }
        func s16(_ off: Int) -> Int {
            let v = (Int(d[base + off]) << 8) | Int(d[base + off + 1])
            return v >= 0x8000 ? v - 0x10000 : v
        }

        // The count field is "number of items minus one".
        let count = s16(0) + 1
        guard count > 0 else { return [] }

        var items: [DITLItem] = []
        items.reserveCapacity(count)
        var off = 2

        for index in 0..<count {
            // 4 (handle) + 8 (rect) + 1 (type) + 1 (length) must all be present.
            guard off + 14 <= d.count else { break }
            off += 4  // nil handle placeholder, unused on disk

            let rect = NovaRect(top: s16(off), left: s16(off + 2),
                                bottom: s16(off + 4), right: s16(off + 6))
            off += 8

            let rawType = u8(off); off += 1
            let length  = u8(off); off += 1
            guard off + length <= d.count else { break }

            let payload = d.subdata(in: (base + off)..<(base + off + length))
            off += length
            if length % 2 == 1 { off += 1 }  // items are even-aligned

            let kind = DITLItemKind(rawType: rawType)
            var text = ""
            var resourceID: Int?
            if kind.payloadIsText {
                text = String(data: payload, encoding: .macOSRoman) ?? ""
            } else if kind.payloadIsResourceID, payload.count >= 2 {
                resourceID = (Int(payload[payload.startIndex]) << 8)
                           | Int(payload[payload.startIndex + 1])
            }

            items.append(DITLItem(index: index, rect: rect, kind: kind,
                                  isEnabled: (rawType & 0x80) == 0,
                                  text: text, resourceID: resourceID))
        }
        return items
    }
}

// MARK: - DLOG

/// A decoded dialog window template: where the window sits and which `DITL`
/// fills it.
public struct DLOGRes: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let bounds: NovaRect
    public let procID: Int
    public let isVisible: Bool
    public let hasGoAway: Bool
    public let refCon: Int
    /// The `DITL` resource id holding this window's items.
    public let itemsID: Int
    public let title: String

    public init(_ resource: Resource) {
        id = resource.id
        name = resource.name
        let d = resource.data
        let base = d.startIndex

        func s16(_ off: Int) -> Int {
            guard off + 2 <= d.count else { return 0 }
            let v = (Int(d[base + off]) << 8) | Int(d[base + off + 1])
            return v >= 0x8000 ? v - 0x10000 : v
        }
        func s32(_ off: Int) -> Int {
            guard off + 4 <= d.count else { return 0 }
            var v = 0
            for i in 0..<4 { v = (v << 8) | Int(d[base + off + i]) }
            return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
        }

        bounds    = NovaRect(top: s16(0), left: s16(2), bottom: s16(4), right: s16(6))
        procID    = s16(8)
        isVisible = s16(10) != 0
        hasGoAway = s16(12) != 0
        refCon    = s32(14)
        itemsID   = s16(18)

        // Pascal string title at offset 20.
        var t = ""
        if d.count > 20 {
            let len = Int(d[base + 20])
            if 21 + len <= d.count {
                t = String(data: d.subdata(in: (base + 21)..<(base + 21 + len)),
                           encoding: .macOSRoman) ?? ""
            }
        }
        title = t
    }
}

// MARK: - Composed dialog

/// A `DLOG` paired with its `DITL` — everything needed to lay one EV Nova
/// screen out at its authored size.
public struct NovaDialogRes: Equatable, Sendable {
    public let window: DLOGRes?
    public let items: DITLRes

    public init(window: DLOGRes?, items: DITLRes) {
        self.window = window
        self.items = items
    }

    /// The coordinate space to lay this dialog out in, with the origin at
    /// (0, 0). This is the `DLOG`'s own size unioned with the bounding box of
    /// its items, because EV Nova ships dialogs whose items overflow the window
    /// rect — #1000 "Spaceport" is 618×517 by its `DLOG` yet places controls
    /// down to y=579. Taking the union means nothing ever clips.
    public var designSize: NovaSize {
        let b = items.itemBounds
        var w = max(b.right, 0)
        var h = max(b.bottom, 0)
        if let window {
            w = max(w, window.bounds.width)
            h = max(h, window.bounds.height)
        }
        return NovaSize(width: w, height: h)
    }

    public subscript(index: Int) -> DITLItem? { items[index] }
}

/// A width/height pair in dialog design units. (`NovaRect` already covers the
/// rectangle case; this exists so `designSize` doesn't have to fake an origin.)
public struct NovaSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

// MARK: - Game accessors

public extension NovaGame {
    /// The dialog item list for `id` — the authoritative pixel layout of a screen.
    func ditl(_ id: Int) -> DITLRes? {
        resources.resource(NovaType.ditl, id).map(DITLRes.init)
    }

    /// The dialog window template for `id`.
    func dlog(_ id: Int) -> DLOGRes? {
        resources.resource(NovaType.dlog, id).map(DLOGRes.init)
    }

    /// A `DLOG` and the `DITL` it points at, composed for layout.
    ///
    /// EV Nova numbers them in lockstep (`DLOG` #1011 → `DITL` #1011), but the
    /// `DLOG` is what actually names the item list, so follow `itemsID` rather
    /// than assuming. When no `DLOG` exists (a few `DITL`s are used standalone),
    /// fall back to the `DITL` of the same id so the caller still gets rects.
    func dialog(_ id: Int) -> NovaDialogRes? {
        if let window = dlog(id), let items = ditl(window.itemsID) {
            return NovaDialogRes(window: window, items: items)
        }
        if let items = ditl(id) {
            return NovaDialogRes(window: nil, items: items)
        }
        return nil
    }
}
