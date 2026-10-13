import XCTest
import Foundation
@testable import NovaSwiftKit

/// Per-total-conversion add-on lists (`TCAddOns`): load order, persistence shape, hints. Synthetic data only.
final class TCAddOnTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("novaswift-tcaddon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func put(_ type: String, _ res: [(Int, String)], at path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ClassicForkBuilder.build(type: type, resources: res.map { (id: $0.0, name: $0.1, payload: Data([1])) }).write(to: url)
        return url
    }

    /// Base Nova.rez + Nova Files, a TC with its own Plug-Ins, two global plug-ins.
    private func fixture() throws -> (base: [URL], plugins: [PluginBundle]) {
        let novaRez = try put("STR#", [(130, "stock")], at: "base/Nova.rez")
        let stock = try put("shïp", [(128, "Stock")], at: "base/Nova Files/a.ndat")
        try put("shïp", [(128, "TC")], at: "tcs/EV Override for Nova/Nova Files/b.ndat")
        try put("shïp", [(128, "TCPlug"), (129, "TCPlug129")], at: "tcs/EV Override for Nova/Plug-Ins/m.ndat")
        try Data("{}".utf8).write(to: root.appendingPathComponent("tcs/EV Override for Nova/Play.nplay"))
        try put("shïp", [(128, "FaceliftA")], at: "tcs/EVO Facelift/Facelift A.ndat")
        try put("shïp", [(128, "FaceliftB"), (130, "FL130")], at: "tcs/EVO Facelift/Facelift B.ndat")
        try put("shïp", [(129, "Cold")], at: "tcs/Cold Fusion.ndat")
        let plugins = GameLibrary.discoverPlugins(in: root.appendingPathComponent("tcs"))
        return ([novaRez, stock], plugins)
    }

    private func enableTC(_ plugins: [PluginBundle], lists: TCAddOns.Lists) -> [PluginBundle] {
        var p = plugins
        PluginSet.setEnabled(&p, id: "EV Override for Nova", enabled: true, manual: false)
        return PluginSet.arrange(discovered: p, persisted: PluginSet.persistedState(of: p), manual: false, tcAddOns: lists)
    }

    func testNoListMeansOriginalBehaviour() throws {
        let (base, plugins) = try fixture()
        let p = enableTC(plugins, lists: [:])
        let m = try GameLibrary.merge(baseFiles: base, plugins: p)
        XCTAssertEqual(m.resource(NovaType.ship, 128)?.name, "TCPlug")
        XCTAssertNil(m.resource(NovaType.ship, 130), "global plug-ins stay out of a conversion")
    }

    func testAddOnsLoadAfterTCPlugInsInListOrder() throws {
        let (base, plugins) = try fixture()
        var lists: TCAddOns.Lists = [:]
        let tc = "EV Override for Nova"
        XCTAssertTrue(TCAddOns.add(&lists, tc: tc, id: "Cold Fusion.ndat"))
        XCTAssertTrue(TCAddOns.add(&lists, tc: tc, id: "EVO Facelift"))
        XCTAssertFalse(TCAddOns.add(&lists, tc: tc, id: "EVO Facelift"), "no duplicates")
        var p = enableTC(plugins, lists: lists)
        var m = try GameLibrary.merge(baseFiles: base, plugins: p)
        XCTAssertEqual(m.resource(NovaType.ship, 128)?.name, "FaceliftB", "add-ons win over the TC's own Plug-Ins")
        XCTAssertEqual(m.resource(NovaType.ship, 129)?.name, "Cold", "Cold Fusion (129) comes before Facelift (no 129), so it survives")
        XCTAssertEqual(m.resource(NovaType.ship, 130)?.name, "FL130")
        XCTAssertNotNil(m.resource(FourCharCode("STR#")!, 130), "Nova.rez still shared")

        // Reorder: Facelift first, then Cold Fusion wins 129 over the TC plug-in either way; 128 stays Facelift B.
        XCTAssertTrue(TCAddOns.move(&lists, tc: tc, id: "EVO Facelift", by: -1))
        XCTAssertEqual(lists[tc]?.map(\.id), ["EVO Facelift", "Cold Fusion.ndat"])
        // Disable Facelift: it drops out, the TC's own plug-in wins 128 again.
        XCTAssertTrue(TCAddOns.setEnabled(&lists, tc: tc, id: "EVO Facelift", enabled: false))
        p = enableTC(plugins, lists: lists)
        m = try GameLibrary.merge(baseFiles: base, plugins: p)
        XCTAssertEqual(m.resource(NovaType.ship, 128)?.name, "TCPlug")
        XCTAssertEqual(m.resource(NovaType.ship, 129)?.name, "Cold")
        XCTAssertNil(m.resource(NovaType.ship, 130))
        XCTAssertTrue(TCAddOns.remove(&lists, tc: tc, id: "Cold Fusion.ndat"))
        p = enableTC(plugins, lists: lists)
        XCTAssertEqual(TCAddOns.selectedTC(p)?.addOnIDs, [])
    }

    func testAddOnListsDoNotTouchBaseGame() throws {
        let (base, plugins) = try fixture()
        var lists: TCAddOns.Lists = [:]
        TCAddOns.add(&lists, tc: "EV Override for Nova", id: "EVO Facelift")
        // No TC selected: lists are ignored, global plug-ins load as the original does.
        let p = PluginSet.arrange(discovered: plugins, persisted: [], manual: false, tcAddOns: lists)
        let m = try GameLibrary.merge(baseFiles: base, plugins: p)
        XCTAssertEqual(m.resource(NovaType.ship, 128)?.name, "FaceliftB")
        XCTAssertEqual(m.resource(NovaType.ship, 129)?.name, "Cold")
    }

    func testFingerprintChangesWithAddOns() throws {
        let (base, plugins) = try fixture()
        var lists: TCAddOns.Lists = [:]
        let f0 = GameLibrary.fingerprint(baseFiles: base, plugins: enableTC(plugins, lists: lists))
        TCAddOns.add(&lists, tc: "EV Override for Nova", id: "EVO Facelift")
        let f1 = GameLibrary.fingerprint(baseFiles: base, plugins: enableTC(plugins, lists: lists))
        XCTAssertNotEqual(f0, f1)
    }

    func testListsRoundTripAsJSON() throws {
        var lists: TCAddOns.Lists = [:]
        TCAddOns.add(&lists, tc: "T", id: "A")
        TCAddOns.add(&lists, tc: "T", id: "B", enabled: false)
        let back = try JSONDecoder().decode(TCAddOns.Lists.self, from: JSONEncoder().encode(lists))
        XCTAssertEqual(back, lists)
    }

    func testCompatibilityHints() throws {
        let (_, plugins) = try fixture()
        let tc = try XCTUnwrap(plugins.first { $0.isTotalConversion })
        XCTAssertTrue(TCAddOns.aliases(of: tc).contains("evo"))
        let fl = try XCTUnwrap(plugins.first { $0.id == "EVO Facelift" })
        XCTAssertEqual(TCAddOns.compatibility(of: fl, with: tc).key, "recommended")
        let cold = try XCTUnwrap(plugins.first { $0.id == "Cold Fusion.ndat" })
        XCTAssertEqual(TCAddOns.compatibility(of: cold, with: tc), .neutral)
        // A plug-in that names another conversion is flagged unlikely.
        try put("shïp", [(1, "x")], at: "tcs2/Polycon EV/Nova Files/p.ndat")
        try put("shïp", [(2, "x")], at: "tcs2/Polycon Booster/pb.ndat")
        let more = GameLibrary.discoverPlugins(in: root.appendingPathComponent("tcs2"))
        let poly = try XCTUnwrap(more.first { $0.isTotalConversion })
        let booster = try XCTUnwrap(more.first { !$0.isTotalConversion })
        XCTAssertEqual(TCAddOns.compatibility(of: booster, with: tc, others: [poly]).key, "unlikely")
    }

    func testRecordOverlapVerdicts() throws {
        var tcRes = ResourceCollection()
        for i in 128..<140 { tcRes.add(Resource(type: NovaType.ship, id: i, name: "Ship \(i)", data: Data([1]))) }
        _ = try put("shïp", (128..<140).map { ($0, "Ship \($0)") }, at: "o/same.ndat")
        _ = try put("shïp", (128..<140).map { ($0, "Base \($0)") }, at: "o/diff.ndat")
        _ = try put("shïp", (500..<510).map { ($0, "New \($0)") }, at: "o/new.ndat")
        func bundle(_ n: String) -> PluginBundle { PluginBundle(id: n, name: n, fileURLs: [root.appendingPathComponent("o/\(n).ndat")]) }
        XCTAssertEqual(TCAddOns.overlap(of: bundle("same"), in: tcRes).key, "recommended")
        XCTAssertEqual(TCAddOns.overlap(of: bundle("diff"), in: tcRes).key, "unlikely")
        XCTAssertEqual(TCAddOns.overlap(of: bundle("new"), in: tcRes).key, "neutral")
    }

    func testMediaFoldersFollowTheConversionAndItsAddOns() throws {
        let (_, plugins) = try fixture()
        try Data("x".utf8).write(to: root.appendingPathComponent("tcs/EV Override for Nova/Nova Files/Intro.mp4"))
        try Data("x".utf8).write(to: root.appendingPathComponent("tcs/EV Override for Nova/Sillycon.ttf"))
        try Data("x".utf8).write(to: root.appendingPathComponent("tcs/EV Override for Nova/Plug-Ins/Plug.mov"))
        try Data("x".utf8).write(to: root.appendingPathComponent("tcs/EVO Facelift/Facelift.mov"))
        try Data("x".utf8).write(to: root.appendingPathComponent("tcs/Stray.mov"))
        let base = root.appendingPathComponent("base")
        var lists: TCAddOns.Lists = [:]
        // No conversion: plug-in folders of the enabled plug-ins, then the base data.
        var p = PluginSet.arrange(discovered: plugins, persisted: [], manual: false)
        var m = TCAddOns.mediaDirectories(plugins: p, baseDir: base)
        XCTAssertNotNil(TCAddOns.findMedia(named: "facelift.MOV", in: m), "case-insensitive, enabled plug-in folder")
        XCTAssertTrue(TCAddOns.fontFiles(in: m).isEmpty)

        // Conversion without add-ons: its own folders only; the global plug-in's movie is not visible.
        PluginSet.setEnabled(&p, id: "EV Override for Nova", enabled: true, manual: false)
        p = PluginSet.arrange(discovered: p, persisted: PluginSet.persistedState(of: p), manual: false, tcAddOns: lists)
        m = TCAddOns.mediaDirectories(plugins: p, baseDir: base)
        XCTAssertNotNil(TCAddOns.findMedia(named: "Intro.mp4", in: m))
        XCTAssertNotNil(TCAddOns.findMedia(named: "Plug.mov", in: m))
        XCTAssertEqual(TCAddOns.fontFiles(in: m).map(\.lastPathComponent), ["Sillycon.ttf"])
        XCTAssertEqual(m.plugIns.first?.lastPathComponent, "Plug-Ins", "Nova Plug-ins before Nova Files")
        XCTAssertTrue(m.plugIns.allSatisfy { !$0.path.contains("EVO Facelift") })

        // With the add-on: its folder is searched first.
        TCAddOns.add(&lists, tc: "EV Override for Nova", id: "EVO Facelift")
        p = PluginSet.arrange(discovered: p, persisted: PluginSet.persistedState(of: p), manual: false, tcAddOns: lists)
        m = TCAddOns.mediaDirectories(plugins: p, baseDir: base)
        XCTAssertEqual(m.plugIns.first?.lastPathComponent, "EVO Facelift")
        XCTAssertNotNil(TCAddOns.findMedia(named: "Facelift.mov", in: m))
    }

    func testDescMovieFlagsAndStrayNames() throws {
        func desc(name: [UInt8], flags: UInt16) -> DescRes {
            var d = Data("Text".utf8); d.append(0)
            d.append(contentsOf: [0, 0])                 // picture id
            var n = name + [UInt8](repeating: 0, count: 32 - name.count)
            n[n.count - 1] = 0
            d.append(contentsOf: n); d.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 0xff)])
            return DescRes(Resource(type: NovaType.desc, id: 128, data: d))
        }
        let a = desc(name: Array("Intro.mp4".utf8), flags: 0x0004)
        XCTAssertEqual(a.movieFilename, "Intro.mp4")
        XCTAssertTrue(a.movieFillsScreen); XCTAssertFalse(a.movieDoubleSize); XCTAssertFalse(a.moviePlaysAfterText)
        let b = desc(name: Array("TD.mov".utf8), flags: 0x0003)
        XCTAssertTrue(b.movieDoubleSize); XCTAssertTrue(b.moviePlaysAfterText)
        XCTAssertNil(desc(name: [1], flags: 1).movieFilename, "a stray control byte names no file")
    }
}
