import Foundation

/// The stock layouts of the small native-chrome dialogs, for data that lacks
/// `Nova.rez` (an import of only `Nova Files`, or a Mac copy whose dialogs
/// weren't found). Without them these screens would draw an empty window with
/// no controls. Rects and labels match the shipped DLOG/DITL 3001, 3002, 3101
/// and 3102 (`novaswift-extract ditl Nova.rez <id>`). Data that has the real
/// resources always wins (`NovaGame.dialog`).
public enum StockDialogs {
    /// The stock dialog `id`, or nil when there's no built-in layout for it.
    public static func dialog(_ id: Int) -> NovaDialogRes? {
        guard let (w, h, name, items) = layouts[id] else { return nil }
        let window = DLOGRes(id: id, name: name, bounds: NovaRect(top: 0, left: 0, bottom: h, right: w), itemsID: id)
        return NovaDialogRes(window: window, items: DITLRes(id: id, name: name, items: items))
    }

    /// (left, top, right, bottom), as the extractor prints them.
    private static func r(_ l: Int, _ t: Int, _ rr: Int, _ b: Int) -> NovaRect {
        NovaRect(top: t, left: l, bottom: b, right: rr)
    }
    private static func item(_ i: Int, _ rect: NovaRect, _ kind: DITLItemKind, enabled: Bool = true,
                             _ text: String = "", res: Int? = nil) -> DITLItem {
        DITLItem(index: i, rect: rect, kind: kind, isEnabled: enabled, text: text, resourceID: res)
    }

    /// The New Pilot items shared by 3101 and 3102 (bottom rows differ).
    private static func newPilot(okTop: Int, art: Int, strict: Int, gender: NovaRect, scenario: NovaRect) -> [DITLItem] {
        [item(0, r(238, okTop, 308, okTop + 20), .button, "OK"),
         item(1, r(156, okTop, 226, okTop + 20), .button, "Cancel"),
         item(2, r(79, art, 261, art + 22), .picture, enabled: false, res: 129),
         item(3, r(59, strict, 154, strict + 17), .checkbox, "Strict Play"),
         item(4, r(54, 36, 138, 52), .statText, enabled: false, "Full Name:"),
         item(5, r(54, 59, 133, 75), .statText, enabled: false, "Nickname:"),
         item(6, r(49, 357, 127, 373), .statText, enabled: false, "name3:"),
         item(7, r(149, 36, 319, 52), .editText, "Edit Text"),
         item(8, r(149, 59, 319, 75), .editText, "Edit Text"),
         item(9, r(144, 357, 314, 373), .editText, "Edit Text"),
         item(10, gender, .resControl, res: 500),
         item(11, r(53, 6, 181, 22), .statText, enabled: false, "Create a new pilot:"),
         item(12, scenario, .resControl, res: 501),
         item(13, r(7, 5, 39, 37), .picture, enabled: false, res: 130)]
    }

    private static let layouts: [Int: (w: Int, h: Int, name: String, items: [DITLItem])] = [
        3001: (360, 138, "Text Input", [
            item(0, r(252, 106, 322, 126), .button, "OK"),
            item(1, r(259, 147, 327, 177), .picture, enabled: false, res: 129),
            item(2, r(52, 5, 347, 55), .statText, enabled: false, "Text"),
            item(3, r(7, 5, 39, 37), .picture, enabled: false, res: 130),
            item(4, r(91, 64, 291, 80), .editText, "Edit Text"),
            item(5, r(170, 106, 240, 126), .button, "Cancel"),
        ]),
        3002: (355, 109, "YesNo", [
            item(0, r(263, 75, 333, 95), .button, "OK"),
            item(1, r(277, 131, 345, 161), .picture, enabled: false, res: 129),
            item(2, r(52, 5, 347, 55), .statText, enabled: false, "Text"),
            item(3, r(7, 5, 39, 37), .picture, enabled: false, res: 130),
            item(4, r(181, 75, 251, 95), .button, "Cancel"),
        ]),
        3101: (326, 247, "new New Pilot + popup",
               newPilot(okTop: 214, art: 172, strict: 153, gender: r(51, 123, 251, 143), scenario: r(51, 92, 322, 112))),
        3102: (326, 213, "new New Pilot",
               newPilot(okTop: 183, art: 141, strict: 122, gender: r(51, 92, 251, 112), scenario: r(85, 277, 356, 297))),
    ]
}
