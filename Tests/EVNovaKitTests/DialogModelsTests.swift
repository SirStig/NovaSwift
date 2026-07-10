import XCTest
import Foundation
@testable import EVNovaKit

/// Pins the `DITL`/`DLOG`/`STR#` decoders to the byte layouts documented in
/// Inside Macintosh, using synthetic resources plus the exact numbers observed
/// in the shipped `Nova.rez` (see the fixtures below, transcribed from
/// `evnova-extract ditl/dlog`). If someone "fixes" a rect field order, these
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

}
