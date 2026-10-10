import XCTest
import Foundation
@testable import NovaSwiftKit

/// Pins the `DITL`/`DLOG`/`STR#` decoders to the byte layouts documented in
/// Inside Macintosh, using synthetic resources plus the exact numbers observed
/// in the shipped `Nova.rez` (see the fixtures below, transcribed from
/// `novaswift-extract ditl/dlog`). If someone "fixes" a rect field order, these
/// fail loudly.
final class DialogModelsTests: XCTestCase {

    // MARK: Builders

    private func be16(_ v: Int) -> [UInt8] {
        let u = UInt16(bitPattern: Int16(v))
        return [UInt8(u >> 8), UInt8(u & 0xFF)]
    }

    /// Assemble a DITL body from (rect, type, payload) triples.
    /// rect is given the way the resource stores it: top, left, bottom, right.
    private func makeDITL(_ items: [(t: Int, l: Int, b: Int, r: Int, type: UInt8, payload: [UInt8])]) -> Data {
        var out: [UInt8] = be16(items.count - 1)
        for it in items {
            out += [0, 0, 0, 0]                                   // nil handle
            out += be16(it.t) + be16(it.l) + be16(it.b) + be16(it.r)
            out += [it.type, UInt8(it.payload.count)]
            out += it.payload
            if it.payload.count % 2 == 1 { out += [0] }           // even-align
        }
        return Data(out)
    }

    private func makeDLOG(t: Int, l: Int, b: Int, r: Int,
                          procID: Int, visible: Int, goAway: Int,
                          refCon: Int, itemsID: Int, title: String) -> Data {
        var out: [UInt8] = []
        out += be16(t) + be16(l) + be16(b) + be16(r)
        out += be16(procID) + be16(visible) + be16(goAway)
        let u = UInt32(bitPattern: Int32(refCon))
        out += [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
        out += be16(itemsID)
        let bytes = Array(title.data(using: .macOSRoman)!)
        out += [UInt8(bytes.count)] + bytes
        return Data(out)
    }

    // MARK: DITL

    /// A rect stored as (top, left, bottom, right) must not come back transposed.
    /// This is the bug that would silently misplace every control on every screen.
    func testDITLRectFieldOrder() {
        // DITL #1011 "Plunder Dialog" item 6, as shipped: 146 wide × 25 tall at (129, 138).
        let data = makeDITL([(t: 138, l: 129, b: 163, r: 275, type: 0, payload: [])])
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1011, name: "Plunder Dialog", data: data))

        let item = try! XCTUnwrap(ditl[0])
        XCTAssertEqual(item.rect, NovaRect(top: 138, left: 129, bottom: 163, right: 275))
        XCTAssertEqual(item.rect.width, 146, "width must be right-left, not bottom-top")
        XCTAssertEqual(item.rect.height, 25, "height must be bottom-top, not right-left")
    }

    /// The high bit of the type byte marks an item EV Nova draws but never
    /// hit-tests. Panels and backdrops rely on it.
    func testDITLDisabledFlagAndKinds() {
        let data = makeDITL([
            (t: 7, l: 11, b: 103, r: 298, type: 0x80, payload: []),        // disabled userItem (panel)
            (t: 110, l: 16, b: 135, r: 105, type: 0x00, payload: []),      // enabled userItem (button)
            (t: 0, l: 0, b: 20, r: 80, type: 4, payload: Array("OK".utf8)),  // real button w/ label
            (t: 0, l: 0, b: 32, r: 32, type: 64, payload: [0x21, 0x34]),   // picture → resID 8500
        ])
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t", data: data))
        XCTAssertEqual(ditl.items.count, 4)

        XCTAssertEqual(ditl[0]?.kind, .userItem)
        XCTAssertFalse(ditl[0]!.isEnabled)

        XCTAssertEqual(ditl[1]?.kind, .userItem)
        XCTAssertTrue(ditl[1]!.isEnabled)

        XCTAssertEqual(ditl[2]?.kind, .button)
        XCTAssertEqual(ditl[2]?.text, "OK")

        XCTAssertEqual(ditl[3]?.kind, .picture)
        XCTAssertEqual(ditl[3]?.resourceID, 0x2134)
    }

    /// Odd-length payloads pad to an even offset; a decoder that forgets this
    /// walks off by one byte and every subsequent rect is garbage.
    func testDITLOddPayloadPadding() {
        let data = makeDITL([
            (t: 1, l: 2, b: 3, r: 4, type: 8, payload: Array("abc".utf8)),   // 3 bytes → pad 1
            (t: 10, l: 20, b: 30, r: 40, type: 0, payload: []),
        ])
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t", data: data))
        XCTAssertEqual(ditl.items.count, 2)
        XCTAssertEqual(ditl[0]?.text, "abc")
        XCTAssertEqual(ditl[1]?.rect, NovaRect(top: 10, left: 20, bottom: 30, right: 40),
                       "second item misread ⇒ odd-payload padding was skipped")
    }

    /// A truncated resource must degrade to the items it could read, not trap.
    func testDITLTruncatedResourceDegrades() {
        var data = makeDITL([
            (t: 1, l: 2, b: 3, r: 4, type: 0, payload: []),
            (t: 10, l: 20, b: 30, r: 40, type: 0, payload: []),
        ])
        data = data.prefix(20)  // claims 2 items, holds ~1
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t", data: data))
        XCTAssertLessThan(ditl.items.count, 2)
        XCTAssertNil(ditl[5], "out-of-range subscript must be nil, not a trap")
    }

    /// `itemBounds` drives the design size, so it must be a true union.
    func testDITLItemBoundsUnion() {
        let data = makeDITL([
            (t: 3, l: 3, b: 288, r: 615, type: 0x80, payload: []),
            (t: 549, l: 452, b: 579, r: 520, type: 0x80, payload: []),  // overflows the DLOG
            (t: 333, l: 471, b: 358, r: 616, type: 0, payload: []),
        ])
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1000, name: "Spaceport", data: data))
        XCTAssertEqual(ditl.itemBounds, NovaRect(top: 3, left: 3, bottom: 579, right: 616))
    }

    // MARK: DLOG

    func testDLOGDecode() {
        // DLOG #1000 "Spaceport", exactly as shipped: top=-201 left=60 bottom=316 right=678.
        let data = makeDLOG(t: -201, l: 60, b: 316, r: 678,
                            procID: 2, visible: 0, goAway: 0,
                            refCon: 0, itemsID: 1000, title: "")
        let dlog = DLOGRes(Resource(type: NovaType.dlog, id: 1000, name: "Spaceport", data: data))

        XCTAssertEqual(dlog.bounds, NovaRect(top: -201, left: 60, bottom: 316, right: 678))
        XCTAssertEqual(dlog.bounds.width, 618)
        XCTAssertEqual(dlog.bounds.height, 517)
        XCTAssertEqual(dlog.procID, 2)
        XCTAssertFalse(dlog.isVisible)
        XCTAssertEqual(dlog.itemsID, 1000)
        XCTAssertEqual(dlog.title, "")
    }

    /// Spaceport is the case that proves the union matters: its items reach
    /// y=579 while its window is only 517 tall.
    func testDialogDesignSizeUnionsWindowAndItems() {
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1000, name: "Spaceport",
                                    data: makeDITL([
                                        (t: 3, l: 3, b: 288, r: 615, type: 0x80, payload: []),
                                        (t: 549, l: 452, b: 579, r: 520, type: 0x80, payload: []),
                                    ])))
        let dlog = DLOGRes(Resource(type: NovaType.dlog, id: 1000, name: "Spaceport",
                                    data: makeDLOG(t: -201, l: 60, b: 316, r: 678, procID: 2,
                                                   visible: 0, goAway: 0, refCon: 0,
                                                   itemsID: 1000, title: "")))
        let dialog = NovaDialogRes(window: dlog, items: ditl)

        XCTAssertEqual(dialog.designSize, NovaSize(width: 618, height: 579),
                       "design space must contain both the window (618×517) and the items (→579)")
    }

    /// With no DLOG, the items alone define the space.
    func testDialogDesignSizeWithoutWindow() {
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t",
                                    data: makeDITL([(t: 7, l: 11, b: 103, r: 298, type: 0, payload: [])])))
        XCTAssertEqual(NovaDialogRes(window: nil, items: ditl).designSize,
                       NovaSize(width: 298, height: 103))
    }

    // MARK: Original parser rules (Dialog_ParseItemList 0x004cef50)

    /// Raw item bytes, so the length byte can disagree with the payload the
    /// original actually consumes.
    private func rawItem(t: Int, l: Int, b: Int, r: Int, type: UInt8, length: UInt8, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 0]
        out += be16(t) + be16(l) + be16(b) + be16(r)
        out += [type, length] + body
        if out.count % 2 == 1 { out += [0] }
        return out
    }

    /// User items and unknown kinds take a fixed 14 bytes whatever the length
    /// byte says; controls/icons/pictures a fixed 2-byte id; unknown kinds
    /// build no item, so the next item takes their index.
    func testDITLParserFixedSizesAndUnknownKinds() {
        var bytes: [UInt8] = be16(3 - 1)
        bytes += rawItem(t: 0, l: 0, b: 10, r: 10, type: 0, length: 6, body: [])        // user, bogus length
        bytes += rawItem(t: 1, l: 1, b: 11, r: 11, type: 3, length: 0, body: [])        // unknown kind 3
        bytes += rawItem(t: 2, l: 2, b: 12, r: 12, type: 7, length: 9, body: [0x03, 0xF4]) // control, length ignored
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t", data: Data(bytes)))
        XCTAssertEqual(ditl.items.count, 2, "the unknown kind builds no item")
        XCTAssertEqual(ditl[0]?.kind, .userItem)
        XCTAssertEqual(ditl[1]?.kind, .resControl)
        XCTAssertEqual(ditl[1]?.index, 1)
        XCTAssertEqual(ditl[1]?.resourceID, 1012)
        XCTAssertEqual(ditl[1]?.rect, NovaRect(top: 2, left: 2, bottom: 12, right: 12))
    }

    /// Radio buttons are built as checkboxes; focus starts on the first item
    /// that isn't a user/static/icon/picture item.
    func testDITLRadioIsCheckboxAndInitialFocus() {
        let data = makeDITL([
            (t: 0, l: 0, b: 10, r: 10, type: 8, payload: Array("Hi".utf8)),   // static
            (t: 0, l: 0, b: 10, r: 10, type: 0, payload: []),                  // user
            (t: 0, l: 0, b: 10, r: 10, type: 6, payload: Array("R".utf8)),     // radio
            (t: 0, l: 0, b: 10, r: 10, type: 4, payload: Array("OK".utf8)),    // button
        ])
        let ditl = DITLRes(Resource(type: NovaType.ditl, id: 1, name: "t", data: data))
        XCTAssertEqual(ditl[2]?.kind, .checkbox)
        XCTAssertEqual(ditl[2]?.text, "R")
        XCTAssertEqual(ditl.initialFocusIndex, 2)
    }

    // MARK: Layout lookup (C I-1)

    private func plunderGame(itemThreeShift: Int) -> NovaGame {
        // DITL #1011 "Plunder Dialog" as shipped, with item 3 (the third
        // 89×25 button of row 1) optionally moved right.
        let s = itemThreeShift
        let ditl = makeDITL([
            (t: 166, l: 91, b: 191, r: 217, type: 0, payload: []),
            (t: 110, l: 110, b: 135, r: 199, type: 0, payload: []),
            (t: 138, l: 35, b: 163, r: 124, type: 0, payload: []),
            (t: 110, l: 204 + s, b: 135, r: 293 + s, type: 0, payload: []),
            (t: 7, l: 11, b: 103, r: 298, type: 0x80, payload: []),
            (t: 110, l: 16, b: 135, r: 105, type: 0, payload: []),
            (t: 138, l: 129, b: 163, r: 275, type: 0, payload: []),
        ])
        let dlog = makeDLOG(t: 40, l: 40, b: 238, r: 349, procID: 2, visible: 0, goAway: 0,
                            refCon: 0, itemsID: 1011, title: "")
        var col = ResourceCollection()
        col.add(Resource(type: NovaType.ditl, id: 1011, name: "Plunder Dialog", data: ditl))
        col.add(Resource(type: NovaType.dlog, id: 1011, name: "", data: dlog))
        return NovaGame(col)
    }

    /// A plug-in's replacement DITL moves the control; the layout follows it.
    func testDITLLayoutFollowsReplacementDITL() {
        let stock = NovaRect(top: 110, left: 204, bottom: 135, right: 293)
        let moved = plunderGame(itemThreeShift: 40).ditlLayout(1011).rect(3, fallback: stock)
        XCTAssertEqual(moved, NovaRect(top: 110, left: 244, bottom: 135, right: 333))
        let shipped = plunderGame(itemThreeShift: 0).ditlLayout(1011).rect(3, fallback: stock)
        XCTAssertEqual(shipped, stock)
    }

    /// No resource, or an item index past the list: the stock rect is used.
    func testDITLLayoutFallsBackWhenMissing() {
        let stock = NovaRect(top: 1, left: 2, bottom: 3, right: 4)
        let empty = NovaGame(ResourceCollection()).ditlLayout(1011)
        XCTAssertEqual(empty.rect(3, fallback: stock), stock)
        XCTAssertEqual(empty.windowSize(fallback: NovaSize(width: 9, height: 8)), NovaSize(width: 9, height: 8))
        let game = plunderGame(itemThreeShift: 0).ditlLayout(1011)
        XCTAssertEqual(game.rect(40, fallback: stock), stock)
    }

    /// The window is the DLOG's size, centred; its position is ignored.
    func testDITLLayoutWindowIsDLOGSizeCentred() {
        let l = plunderGame(itemThreeShift: 0).ditlLayout(1011)
        XCTAssertEqual(l.windowSize(fallback: NovaSize(width: 1, height: 1)), NovaSize(width: 309, height: 198))
        let o = l.windowOrigin(screen: NovaSize(width: 800, height: 600), fallback: NovaSize(width: 1, height: 1))
        XCTAssertEqual(o.x, 245); XCTAssertEqual(o.y, 201)
    }
}
