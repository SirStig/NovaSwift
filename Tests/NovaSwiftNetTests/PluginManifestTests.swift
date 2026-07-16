import XCTest
@testable import NovaSwiftNet

final class PluginManifestTests: XCTestCase {
    private func req(_ id: String, _ hash: String = "h") -> PluginRequirement {
        PluginRequirement(id: id, name: id.capitalized, contentHash: hash)
    }

    func testEmptyManifestsAreCompatible() {
        XCTAssertTrue(PluginManifest.empty.isCompatible(with: .empty))
        XCTAssertTrue(PluginManifest.empty.mismatch(against: .empty).isCompatible)
    }

    func testSameSetIsCompatibleRegardlessOfOrder() {
        let a = PluginManifest([req("shields"), req("fed")])
        let b = PluginManifest([req("fed"), req("shields")])
        XCTAssertTrue(a.isCompatible(with: b))
        XCTAssertEqual(a.signature, b.signature)
        XCTAssertTrue(a.mismatch(against: b).isCompatible)
    }

    func testMissingAndExtraAreDetected() {
        let host = PluginManifest([req("shields"), req("fed")])
        let joiner = PluginManifest([req("fed"), req("pirates")])
        let m = joiner.mismatch(against: host)
        XCTAssertFalse(m.isCompatible)
        XCTAssertEqual(m.missing.map(\.id), ["shields"])   // host has, joiner must install
        XCTAssertEqual(m.extra.map(\.id), ["pirates"])     // joiner has, must disable
        XCTAssertTrue(m.wrongVersion.isEmpty)
        XCTAssertNotEqual(host.signature, joiner.signature)
    }

    func testDifferentVersionOfSamePluginIsAWrongVersion() {
        let host = PluginManifest([req("shields", "v2")])
        let joiner = PluginManifest([req("shields", "v1")])
        let m = joiner.mismatch(against: host)
        XCTAssertFalse(m.isCompatible)
        XCTAssertTrue(m.missing.isEmpty)
        XCTAssertTrue(m.extra.isEmpty)
        XCTAssertEqual(m.wrongVersion.map(\.id), ["shields"])
        XCTAssertFalse(host.isCompatible(with: joiner))
        XCTAssertNotEqual(host.signature, joiner.signature)   // content changes the fingerprint
    }

    func testSignatureIsDeterministicAndGroupNonNegative() {
        let a = PluginManifest([req("shields", "abc"), req("fed", "def")])
        let b = PluginManifest([req("fed", "def"), req("shields", "abc")])
        XCTAssertEqual(a.signature, b.signature)   // stable across launches / devices
        XCTAssertGreaterThanOrEqual(a.groupID, 0)
        XCTAssertEqual(a.groupID, b.groupID)
    }

    func testManifestRoundTripsThroughTheWire() throws {
        let manifest = PluginManifest([req("shields", "abc"), req("fed", "def")])
        let data = try NetCodec.encode(.pluginManifest(manifest))
        guard case let .pluginManifest(decoded) = try NetCodec.decode(data) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(decoded, manifest)
    }
}
