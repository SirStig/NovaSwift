#if os(macOS)
import SwiftUI
import SceneKit
import ImageIO
import UniformTypeIdentifiers
import NovaSwiftKit

/// `ppat` / `PPat` pixel pattern: the decoded tile at 1x-8x and tiled over a sample surface the
/// way the classic UI fills a background. Decoding runs off the main actor.
struct PixPatPreview: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    @State private var sprite: EditorDecodedSprite?
    @State private var failure: String?
    @State private var loading = true
    @State private var zoom: CGFloat = 4

    private struct TaskKey: Hashable { let key: ResourceKey; let rev: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sprite {
                HStack {
                    Text("\(sprite.sheet.frameWidth)×\(sprite.sheet.frameHeight) px tile")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $zoom) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag(CGFloat($0)) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                Text("TILE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                tileView(sprite)
                Text("TILED").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                TiledPatternView(sprite: sprite)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            } else if loading {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                    ProgressView().controlSize(.regular).tint(novaAmber)
                }.frame(maxWidth: .infinity, minHeight: 200)
            } else {
                EditorEmptyState(icon: "square.grid.3x3", title: "Can't preview this pattern",
                                 subtitle: failure ?? "The pattern isn't a 1/2/4/8-bit pixel pattern with a colour table.")
                    .frame(minHeight: 180)
            }
        }
        .task(id: TaskKey(key: key, rev: model.dataRevision)) {
            loading = true
            let d = data
            let box = await Task.detached(priority: .userInitiated) { () -> SpecBox<(EditorDecodedSprite?, String?)> in
                do {
                    let sheet = try PixPat.decode(d)
                    guard let s = EditorDecodedSprite(sheet) else { return SpecBox(value: (nil, "Couldn't build an image")) }
                    return SpecBox(value: (s, nil))
                } catch { return SpecBox(value: (nil, "\(error)")) }
            }.value
            if Task.isCancelled { return }
            sprite = box.value.0; failure = box.value.1; loading = false
        }
    }

    private func tileView(_ s: EditorDecodedSprite) -> some View {
        let w = CGFloat(s.sheet.frameWidth) * zoom, h = CGFloat(s.sheet.frameHeight) * zoom
        return ZStack {
            CheckerboardBackground()
            Image(decorative: s.image, scale: 1).interpolation(.none).resizable().frame(width: w, height: h)
        }
        .frame(width: max(w + 16, 80), height: max(h + 16, 60))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
    }
}

/// A pattern repeated across the whole view at 1:1 (the classic fill), via a tiled draw.
private struct TiledPatternView: View {
    let sprite: EditorDecodedSprite
    var body: some View {
        Canvas { ctx, size in
            let tw = CGFloat(sprite.sheet.frameWidth), th = CGFloat(sprite.sheet.frameHeight)
            guard tw > 0, th > 0 else { return }
            let img = ctx.resolve(Image(decorative: sprite.image, scale: 1).interpolation(.none))
            let cols = Int(size.width / tw) + 1, rows = Int(size.height / th) + 1
            // Very small tiles would mean tens of thousands of draws; cap the work.
            guard cols * rows <= 40_000 else {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.3))); return
            }
            for y in 0..<rows {
                for x in 0..<cols {
                    ctx.draw(img, in: CGRect(x: CGFloat(x) * tw, y: CGFloat(y) * th, width: tw, height: th))
                }
            }
        }
    }
}
#endif

#if os(macOS)
/// Whole-file images and models stored as a resource: `NSbl` HD assets (PNG atlas or USDZ
/// model), `PNG ` / `PNGf`, and `icns`. Images go through ImageIO, so PNG, JPEG, GIF, TIFF,
/// BMP, HEIC, WebP, ICNS and ICO all preview; a zip (`PK`) is loaded as USDZ in an
/// orbitable SceneKit view. Anything else points at the Raw toggle.
struct HDBlobPreview: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    private enum Loaded { case image(CGImage, format: String, frames: Int), scene(SCNScene), failed(String) }

    @State private var loaded: Loaded?
    @State private var zoom: CGFloat = 1

    private struct TaskKey: Hashable { let key: ResourceKey; let rev: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch loaded {
            case let .image(img, format, frames):
                HStack {
                    Text("\(format) · \(img.width)×\(img.height) px\(frames > 1 ? " · \(frames) images, largest shown" : "") · \(data.count.formatted()) bytes")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $zoom) {
                        ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { Text("\($0.formatted())×").tag(CGFloat($0)) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        CheckerboardBackground()
                        Image(decorative: img, scale: 1).interpolation(zoom >= 1 ? .none : .high).resizable()
                    }
                    .frame(width: CGFloat(img.width) * zoom, height: CGFloat(img.height) * zoom)
                }
                .frame(maxWidth: .infinity).frame(minHeight: 200, maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            case .scene(let scene):
                Text("USDZ model · \(data.count.formatted()) bytes — drag to orbit, scroll to zoom")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .frame(maxWidth: .infinity).frame(height: 420)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            case .failed(let why):
                EditorEmptyState(icon: "photo", title: "Can't preview this asset", subtitle: why)
                    .frame(minHeight: 180)
            case nil:
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                    ProgressView().controlSize(.regular).tint(novaAmber)
                }.frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: TaskKey(key: key, rev: model.dataRevision)) {
            loaded = nil
            let d = data
            let box = await Task.detached(priority: .userInitiated) { SpecBox(value: Self.load(d)) }.value
            if Task.isCancelled { return }
            loaded = box.value
        }
    }

    private static func load(_ d: Data) -> Loaded {
        // A zip is a USDZ; ImageIO would refuse it anyway.
        if d.prefix(2).elementsEqual([0x50, 0x4B]) {
            // SceneKit/ModelIO only read USDZ from a file URL.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nsbl-preview-\(UUID().uuidString).usdz")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try d.write(to: url)
                return .scene(try SCNScene(url: url, options: [.checkConsistency: false]))
            } catch { return .failed("The USDZ didn't load: \(error.localizedDescription)") }
        }
        if let src = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(src) > 0 {
            // icns/ico hold several sizes: show the largest.
            let n = CGImageSourceGetCount(src)
            let best = (0..<n).max { a, b in
                func area(_ i: Int) -> Int {
                    let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                    return ((p?[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((p?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
                }
                return area(a) < area(b)
            } ?? 0
            if let img = CGImageSourceCreateImageAtIndex(src, best, nil) {
                let uti = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
                let format = uti?.preferredFilenameExtension?.uppercased() ?? "Image"
                return .image(img, format: format, frames: n)
            }
        }
        return .failed("Not an image or USDZ model ImageIO/SceneKit can read. Switch to Raw to edit the bytes.")
    }
}
#endif
