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
        // The original builds radio buttons (6) as checkboxes (0x004cef50).
        case 5, 6: self = .checkbox
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
        case .button, .checkbox, .statText, .editText: return true
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

    /// Decoded the way the original's `Dialog_ParseItemList` (0x004cef50)
    /// walks the list, not the toolbox's generic rule:
    /// - text kinds (button 4, checkbox 5, radio 6, static 8, edit 16) consume
    ///   their length byte's worth of payload;
    /// - control 7, icon 32 and picture 64 read a fixed 2-byte id and ignore
    ///   the length byte (16 bytes per item);
    /// - user items (0) and unknown kinds consume a fixed 14 bytes, also
    ///   ignoring the length byte;
    /// - unknown kinds create **no item**, so later items take their place in
    ///   the index order the game addresses them by;
    /// - radio buttons are built as checkboxes.
    /// Every item then pads to an even offset.
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

        for _ in 0..<count {
            // 4 (handle) + 8 (rect) + 1 (type) + 1 (length) must all be present.
            guard off + 14 <= d.count else { break }
            let rect = NovaRect(top: s16(off + 4), left: s16(off + 6),
                                bottom: s16(off + 8), right: s16(off + 10))
            let rawType = u8(off + 12)
            let length  = u8(off + 13)
            let kind = DITLItemKind(rawType: rawType)

            var text = ""
            var resourceID: Int?
            switch rawType & 0x7F {
            case 4, 5, 6, 8, 16:
                guard off + 14 + length <= d.count else { return items }
                let payload = d.subdata(in: (base + off + 14)..<(base + off + 14 + length))
                text = String(data: payload, encoding: .macOSRoman) ?? ""
                off += 14 + length
            case 7, 32, 64:
                guard off + 16 <= d.count else { return items }
                resourceID = s16(off + 14)
                off += 16
            default:
                off += 14
            }
            if off % 2 == 1 { off += 1 }  // items are even-aligned

            if case .unknown = kind { continue }   // the original builds nothing
            items.append(DITLItem(index: items.count, rect: rect, kind: kind,
                                  isEnabled: (rawType & 0x80) == 0,
                                  text: text, resourceID: resourceID))
        }
        return items
    }

    /// The item that takes keyboard focus when the dialog opens: the first
    /// one that is not a user, static-text, icon or picture item (0x004cef50).
    /// nil when every item is passive.
    public var initialFocusIndex: Int? {
        items.first { item in
            switch item.kind {
            case .userItem, .statText, .icon, .picture: return false
            default: return true
            }
        }?.index
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

// MARK: - Layout lookup with fallback

/// One screen's layout as the original builds it (`UiWindow_CreateFromDialogResource`):
/// the window is the `DLOG` rect's **size**, centred on screen (its position is
/// ignored, 0x008730a1), and each control sits at its `DITL` item rect, which
/// the code addresses by index. A plug-in or TC that replaces the `DLOG`/`DITL`
/// therefore moves, resizes and re-hit-tests the controls.
///
/// Views ask for every rect through here with the stock value as a fallback,
/// so a missing resource or a short item list degrades to the shipped layout
/// instead of collapsing.
public struct DITLLayout: Equatable, Sendable {
    public let id: Int
    public let dialog: NovaDialogRes?

    public init(id: Int, dialog: NovaDialogRes?) {
        self.id = id
        self.dialog = dialog
    }

    /// The rect of item `index` (window-relative pixels), or `fallback` when
    /// the resource or the item is absent.
    public func rect(_ index: Int, fallback: NovaRect) -> NovaRect {
        dialog?[index]?.rect ?? fallback
    }

    /// The item itself, when present.
    public func item(_ index: Int) -> DITLItem? { dialog?[index] }

    /// The window size: the `DLOG` bounds' width and height, else `fallback`.
    public func windowSize(fallback: NovaSize) -> NovaSize {
        guard let w = dialog?.window, w.bounds.width > 0, w.bounds.height > 0 else { return fallback }
        return NovaSize(width: w.bounds.width, height: w.bounds.height)
    }

    /// The window's top-left on a screen of `screen` size: centred, the `DLOG`'s
    /// own position ignored (integer halves, as the original computes it).
    public func windowOrigin(screen: NovaSize, fallback: NovaSize) -> (x: Int, y: Int) {
        let s = windowSize(fallback: fallback)
        return ((screen.width - s.width) / 2, (screen.height - s.height) / 2)
    }

    /// The item that takes keyboard focus first (see `DITLRes.initialFocusIndex`).
    public var initialFocusIndex: Int? { dialog?.items.initialFocusIndex }
}

public extension NovaGame {
    /// The layout of dialog `id` (`DLOG` → `DITL`), possibly empty.
    func ditlLayout(_ id: Int) -> DITLLayout {
        DITLLayout(id: id, dialog: dialog(id))
    }
}
