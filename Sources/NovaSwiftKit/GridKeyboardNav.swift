import Foundation

/// Arrow-key navigation of the shipyard/outfitter 4×5 item grid (the
/// shipyard keyboard handler, CE fragment 0x008722b0): the arrows move the
/// **selection**, and the grid scrolls a row only when the selection would
/// leave the visible 20 slots. Space presses the screen's buy button.
public enum GridKeyboardNav {
    public enum Key { case left, right, up, down }
    public static let columns = 4
    public static let visibleSlots = 20

    /// `slot` is the selected visible slot (0…19, or −1 for none), `offset`
    /// the index of the first visible item (a multiple of 4), `count` how
    /// many items the grid holds. Returns the new slot and offset; the slot
    /// is pulled back onto the last real item if it lands past the end.
    public static func step(slot: Int, offset: Int, count: Int, key: Key) -> (slot: Int, offset: Int) {
        var s = slot, off = offset
        func exists(_ i: Int) -> Bool { i >= 0 && i < count }
        if s == -1 {
            s = (key == .right || key == .down) ? 0 : visibleSlots - 1
        } else {
            switch key {
            case .right:
                if s < visibleSlots - 1 {
                    if exists(off + s + 1) { s += 1 }
                } else if off < count - visibleSlots {
                    off += columns; s -= columns - 1
                }
            case .left:
                if s < 1 {
                    if off > 0 { off -= columns; s += columns - 1 }
                } else {
                    s -= 1
                }
            case .up:
                if s < columns {
                    if off > 0 { off -= columns }
                } else {
                    s -= columns
                }
            case .down:
                if s < visibleSlots - columns {
                    if exists(off + s + columns) { s += columns }
                } else if off < count - visibleSlots {
                    off += columns
                }
            }
        }
        while !exists(off + s) && s > 0 { s -= 1 }
        return (s, off)
    }
}
