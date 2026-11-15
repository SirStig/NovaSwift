#if canImport(SceneKit) && canImport(AppKit)
import AppKit
import SceneKit
import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftHD

/// `ModelBaker.matchBrightness` (bakes and `calibrateLive`): a model is lit to match the classic art
/// it replaces. It once measured an empty scene and always settled on 1.
final class LightMatchTests: XCTestCase {
    private func hull() -> SCNNode {
        let box = SCNBox(width: 1, height: 0.3, length: 1.4, chamferRadius: 0.05)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: 0.6, alpha: 1)
        m.metalness.contents = NSNumber(value: 0.2)
        m.roughness.contents = NSNumber(value: 0.6)
        box.materials = [m]
        let root = SCNNode()
        root.addChildNode(SCNNode(geometry: box))
        return root
    }

    /// Eight 32×32 frames, each a grey block of `grey` on transparent.
    private func classic(grey: UInt8) -> SpriteSheet {
        let fw = 32, fh = 32, frames = 8
        let cols = min(frames, SpriteSheet.framesPerRow), rows = (frames + cols - 1) / cols
        let w = cols * fw, h = rows * fh
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for f in 0..<frames {
            let ox = (f % SpriteSheet.framesPerRow) * fw, oy = (f / SpriteSheet.framesPerRow) * fh
            for y in 6..<26 { for x in 8..<24 {
                let i = ((oy + y) * w + ox + x) * 4
                rgba[i] = grey; rgba[i + 1] = grey; rgba[i + 2] = grey; rgba[i + 3] = 255
            } }
        }
        return SpriteSheet(frameWidth: fw, frameHeight: fh, frameCount: frames, columns: cols, rows: rows,
                           surfaceWidth: w, surfaceHeight: h, rgba: rgba)
    }

    func testLiveCalibrationLightsTheModelToItsClassicArt() throws {
        guard let baker = ModelBaker() else { throw XCTSkip("no Metal device") }
        let layout = BakeLayout(frameWidth: 32, frameHeight: 32, frameCount: 8, framesPerSet: 8, sets: [.level])
        let descriptor = GraphicsEnhancement(kind: .model)
        let dim = baker.calibrateLive(model: hull(), descriptor: descriptor, layout: layout, classic: classic(grey: 30))
        let bright = baker.calibrateLive(model: hull(), descriptor: descriptor, layout: layout, classic: classic(grey: 230))
        XCTAssertLessThan(dim.lightScale, 0.95, "dark classic art dims the model")
        XCTAssertGreaterThan(bright.lightScale, 1.05, "bright classic art brightens the model")
    }

    func testAPackExposureIsNotMatched() throws {
        guard let baker = ModelBaker() else { throw XCTSkip("no Metal device") }
        let layout = BakeLayout(frameWidth: 32, frameHeight: 32, frameCount: 8, framesPerSet: 8, sets: [.level])
        var bake = GraphicsEnhancement.BakeSettings()
        bake.exposure = 1.3
        let c = baker.calibrateLive(model: hull(), descriptor: GraphicsEnhancement(kind: .model, bake: bake),
                                    layout: layout, classic: classic(grey: 230))
        XCTAssertEqual(c.lightScale, 1, "the pack's own exposure stands")
    }
}
#endif
