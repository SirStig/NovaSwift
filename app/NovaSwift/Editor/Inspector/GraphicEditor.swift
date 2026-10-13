#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import NovaSwiftKit

/// A decoded sprite plus its full-surface CGImage (frames are cropped on demand).
struct EditorDecodedSprite: @unchecked Sendable {
    let sheet: SpriteSheet
    let image: CGImage

    init?(_ sheet: SpriteSheet) {
        guard let rgba = try? RGBAImage(width: sheet.surfaceWidth, height: sheet.surfaceHeight, rgba: sheet.rgba),
              let cg = rgba.makeCGImage() else { return nil }
        self.sheet = sheet; self.image = cg
    }

    func frame(_ n: Int) -> CGImage? {
        guard sheet.frameCount > 0 else { return nil }
        let i = ((n % sheet.frameCount) + sheet.frameCount) % sheet.frameCount
        return image.cropping(to: CGRect(x: (i % SpriteSheet.framesPerRow) * sheet.frameWidth,
                                         y: (i / SpriteSheet.framesPerRow) * sheet.frameHeight,
                                         width: sheet.frameWidth, height: sheet.frameHeight))
    }
}

/// Small decode cache so reselecting a sprite is instant (decode runs off-main).
final class EditorSpriteCache: @unchecked Sendable {
    static let shared = EditorSpriteCache()
    private struct K: Hashable { let type: UInt32; let id: Int; let hash: Int }
    private var store: [K: EditorDecodedSprite] = [:]
    private var order: [K] = []
    private let lock = NSLock()

    /// `mask` is the companion 1-bit icon list for colour icons (`ClassicIcon.maskType`).
    func decode(type: NovaSwiftKit.FourCharCode, id: Int, data: Data, mask: Data? = nil) -> (EditorDecodedSprite?, String?) {
        var h = Hasher(); h.combine(data); h.combine(mask)
        let k = K(type: type.rawValue, id: id, hash: h.finalize())
        lock.lock(); let hit = store[k]; lock.unlock()
        if let hit { return (hit, nil) }
        do {
            let sheet: SpriteSheet
            switch type {
            case NovaType.rleD: sheet = try RLED.decode(data)
            case NovaType.rle8: sheet = try RLE8.decode(data)
            case NovaType.pict: sheet = try PICT.decode(data)
            case NovaType.cicn: sheet = try CICN.decode(data)
            case _ where ClassicIcon.types.contains(type): sheet = try ClassicIcon.decode(type: type, data: data, mask: mask)
            default: return (nil, "No preview for \(type.stringValue)")
            }
            guard let d = EditorDecodedSprite(sheet) else { return (nil, "Couldn't build an image") }
            lock.lock()
            store[k] = d; order.append(k)
            if order.count > 24 { store[order.removeFirst()] = nil }
            lock.unlock()
            return (d, nil)
        } catch { return (nil, "\(error)") }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in 0..<Int(size.height / s) + 1 {
                for x in 0..<Int(size.width / s) + 1 where (x + y) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(.white.opacity(0.07)))
                }
            }
        }
        .background(Color(white: 0.13))
    }
}

/// Shows a sprite either animated / scrubbed or as a grid of every frame.
struct SpriteStage: View {
    let sprite: EditorDecodedSprite
    var zoom: CGFloat
    var checker: Bool
    var playing: Bool
    var fps: Double
    var frame: Int
    var showGrid: Bool
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        let s = sprite.sheet
        let w = CGFloat(s.frameWidth) * zoom, h = CGFloat(s.frameHeight) * zoom
        Group {
            if showGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: max(40, w)), spacing: 4)], spacing: 4) {
                        ForEach(0..<s.frameCount, id: \.self) { n in
                            VStack(spacing: 1) {
                                cell(n, w, h).overlay(RoundedRectangle(cornerRadius: 2)
                                    .stroke(n == frame ? novaAmber : Color.white.opacity(0.15)))
                                Text("\(n)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .onTapGesture { onPick(n) }
                        }
                    }.padding(8)
                }
            } else if playing {
                TimelineView(.periodic(from: .now, by: 1 / max(1, fps))) { ctx in
                    let n = Int(ctx.date.timeIntervalSinceReferenceDate * fps) % max(1, s.frameCount)
                    cell(n, w, h).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                cell(frame, w, h).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { if checker { CheckerboardBackground() } else { Color.black } }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
    }

    @ViewBuilder private func cell(_ n: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        if let cg = sprite.frame(n) {
            Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: w, height: h)
        } else { Color.clear.frame(width: w, height: h) }
    }
}

/// Heading dial: frame 0 is up, frames run clockwise (EV Nova rotation sprites).
struct RotationDial: View {
    let frames: Int
    @Binding var frame: Int
    var body: some View {
        let angle = Double(frame) / Double(max(1, frames)) * 2 * .pi
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)
            Capsule().fill(novaAmber).frame(width: 2.5, height: 22).offset(y: -11).rotationEffect(.radians(angle))
            Circle().fill(Color.white.opacity(0.4)).frame(width: 5, height: 5)
        }
        .frame(width: 54, height: 54)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let dx = g.location.x - 27, dy = g.location.y - 27
            var deg = atan2(dx, -dy) * 180 / .pi
            if deg < 0 { deg += 360 }
            frame = Int((deg / 360 * Double(frames)).rounded()) % frames
        })
        .help("Drag to set heading — frame \(frame) of \(frames) (\(Int(Double(frame) * 360 / Double(max(1, frames))))°)")
    }
}

/// rlëD / PICT / cicn viewer with import & export (classic icons: view & export only).
struct GraphicEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel
    var importable = true

    @State private var sprite: EditorDecodedSprite?
    @State private var failure: String?
    /// Starts true so the very first frame is the placeholder, not a flash of "No preview".
    @State private var loading = true
    @State private var frame = 0
    @State private var playing = false
    @State private var fps = 12.0
    @State private var zoom: CGFloat = 2
    @State private var checker = true
    @State private var grid = false
    @State private var importing = false

    /// Keyed by data revision (not by hashing the whole blob on every body pass).
    private struct DecodeID: Hashable { let key: ResourceKey; let rev: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            Group {
                if let sprite {
                    SpriteStage(sprite: sprite, zoom: zoom, checker: checker, playing: playing && !grid, fps: fps,
                                frame: frame, showGrid: grid) { frame = $0 }
                        .frame(minHeight: 260, maxHeight: 520)
                    info(sprite)
                } else if loading {
                    // Decoding off-main: a box the size of the stage with a spinner.
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                        ProgressView().controlSize(.regular).tint(novaAmber)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                    SkeletonBar(width: 320, height: 9)
                } else {
                    EditorEmptyState(icon: "photo", title: failure ?? "No preview", subtitle: "Use Raw to inspect the bytes.")
                        .frame(minHeight: 200)
                }
            }
        }
        .task(id: DecodeID(key: key, rev: model.dataRevision)) { await decode() }
        .sheet(isPresented: $importing) {
            GraphicImportSheet(key: key, model: model) { importing = false }
        }
    }

    private func decode() async {
        let k = key, d = data
        let mask = ClassicIcon.maskType(for: k.type).flatMap { model.document.resource($0, k.id)?.data }
        loading = true
        let (s, err) = await Task.detached(priority: .userInitiated) {
            EditorSpriteCache.shared.decode(type: k.type, id: k.id, data: d, mask: mask)
        }.value
        sprite = s; failure = err; loading = false
        if let s, frame >= s.sheet.frameCount { frame = 0 }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if importable {
                Button { importing = true } label: { Label("Import PNG…", systemImage: "square.and.arrow.down") }
            }
            Menu {
                Button("Sprite sheet (PNG)…") { exportPNG(sheet: true) }
                Button("Current frame (PNG)…") { exportPNG(sheet: false) }
            } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                .disabled(sprite == nil).fixedSize()
            Divider().frame(height: 18)
            if let s = sprite?.sheet, s.frameCount > 1 {
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .help(playing ? "Pause" : "Play")
                if !playing {
                    Slider(value: Binding(get: { Double(frame) }, set: { frame = Int($0) }),
                           in: 0...Double(s.frameCount - 1), step: 1).frame(width: 140)
                    Text("\(frame)/\(s.frameCount - 1)").font(.system(size: 11, design: .monospaced)).frame(width: 52)
                } else {
                    Stepper("\(Int(fps)) fps", value: $fps, in: 1...60).font(.system(size: 11)).fixedSize()
                }
                if s.frameCount >= 8 && !playing { RotationDial(frames: s.frameCount, frame: $frame) }
                Toggle(isOn: $grid) { Image(systemName: "square.grid.3x3") }.toggleStyle(.button).help("Show all frames")
            }
            Spacer(minLength: 0)
            Picker("", selection: $zoom) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag(CGFloat($0)) }
            }.pickerStyle(.segmented).frame(width: 140).labelsHidden()
            Toggle(isOn: $checker) { Image(systemName: "checkerboard.rectangle") }.toggleStyle(.button).help("Checkerboard background")
        }
        .controlSize(.small)
    }

    private func info(_ s: EditorDecodedSprite) -> some View {
        Text("\(s.sheet.frameWidth)×\(s.sheet.frameHeight) px · \(s.sheet.frameCount) frame\(s.sheet.frameCount == 1 ? "" : "s") · surface \(s.sheet.surfaceWidth)×\(s.sheet.surfaceHeight) · \(data.count) bytes")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func exportPNG(sheet whole: Bool) {
        guard let sprite else { return }
        let cg = whole ? sprite.image : (sprite.frame(frame) ?? sprite.image)
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "\(key.type.stringValue)-\(key.id)\(whole ? "" : "-f\(frame)").png"
        guard p.runModal() == .OK, let url = p.url,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Import

struct GraphicImportSheet: View {
    let key: ResourceKey
    @ObservedObject var model: EditorModel
    var done: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case single = "Single image", grid = "Grid sheet", folder = "Folder of frames", rotate = "Auto-rotate"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .single
    @State private var sources: [RGBAImage] = []
    @State private var sourceNames = ""
    @State private var frameW = 64
    @State private var frameH = 64
    @State private var frameCount = 0     // 0 = all complete cells
    @State private var rotFrames = 36
    @State private var alpha = 128.0
    @State private var pictDepth16 = false

    @State private var preview: EditorDecodedSprite?
    @State private var error: String?
    @State private var building = false
    @State private var pFrame = 0
    @State private var playing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import into \(key.type.stringValue) #\(key.id)").font(.headline)
            Picker("Source", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).onChange(of: mode) { _, _ in sources = []; sourceNames = ""; preview = nil; error = nil }
            HStack {
                Button(mode == .folder ? "Choose Folder…" : "Choose Image…") { choose() }
                Text(sourceNames.isEmpty ? "Nothing chosen" : sourceNames).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            options
            Group {
                if let preview {
                    SpriteStage(sprite: preview, zoom: zoomFor(preview), checker: true, playing: playing && preview.sheet.frameCount > 1,
                                fps: 12, frame: pFrame, showGrid: false)
                        .frame(height: 220)
                    Text("\(preview.sheet.frameWidth)×\(preview.sheet.frameHeight) · \(preview.sheet.frameCount) frames — preview shows the game's 5-bit colour and 1-bit alpha")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if building {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text(error ?? "Choose an image to preview.").font(.system(size: 12))
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Replace Resource") { commit() }.keyboardShortcut(.defaultAction).disabled(preview == nil)
            }
        }
        .padding(20).frame(width: 560)
        .task(id: BuildID(mode: mode, n: sources.count, w: frameW, h: frameH, c: frameCount, r: rotFrames, a: Int(alpha))) {
            await rebuild()
        }
    }

    private struct BuildID: Hashable { let mode: Mode; let n: Int; let w: Int; let h: Int; let c: Int; let r: Int; let a: Int }

    @ViewBuilder private var options: some View {
        switch mode {
        case .grid:
            HStack {
                Stepper("Frame W \(frameW)", value: $frameW, in: 1...1024)
                Stepper("H \(frameH)", value: $frameH, in: 1...1024)
                Stepper("Frames \(frameCount == 0 ? "all" : String(frameCount))", value: $frameCount, in: 0...1000)
            }.font(.system(size: 12))
        case .rotate:
            Stepper("Rotation frames: \(rotFrames) (36 = standard ship)", value: $rotFrames, in: 2...120).font(.system(size: 12))
        default: EmptyView()
        }
        HStack {
            Text("Alpha cut-off \(Int(alpha))").font(.system(size: 12)).frame(width: 110, alignment: .leading)
            Slider(value: $alpha, in: 1...254).frame(width: 160)
            if key.type == NovaType.pict { Toggle("16-bit colour", isOn: $pictDepth16).font(.system(size: 12)) }
        }
    }

    private func zoomFor(_ p: EditorDecodedSprite) -> CGFloat {
        max(1, min(6, floor(200 / CGFloat(max(1, p.sheet.frameHeight)))))
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        if mode == .folder { p.canChooseDirectories = true; p.canChooseFiles = false }
        else { p.allowedContentTypes = [.image] }
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            if mode == .folder {
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                sources = try files.map { try RGBAImage(imageData: Data(contentsOf: $0)) }
                sourceNames = "\(files.count) images in \(url.lastPathComponent)"
            } else {
                let img = try RGBAImage(imageData: Data(contentsOf: url))
                sources = [img]; sourceNames = url.lastPathComponent
                if mode == .grid { frameW = min(img.width, frameW); frameH = min(img.height, frameH) }
            }
            error = nil
        } catch { self.error = "\(error)"; sources = [] }
    }

    nonisolated private static func build(mode: Mode, sources: [RGBAImage], w: Int, h: Int, count: Int, rot: Int, alpha: Double) throws -> SpriteSheet {
        guard !sources.isEmpty else { throw GraphicsEncodeError.badInput("no image chosen") }
        let o = SpriteImport.Options(alphaThreshold: UInt8(alpha), quantizeTo555: true)
        switch mode {
        case .single: return try SpriteImport.singleFrame(sources[0], options: o)
        case .grid: return try SpriteImport.fromGrid(sources[0], frameWidth: w, frameHeight: h,
                                                     frameCount: count == 0 ? nil : count, options: o)
        case .folder: return try SpriteImport.fromFrames(sources, options: o)
        case .rotate: return try SpriteImport.rotated(sources[0], frames: rot, options: o)
        }
    }

    private func rebuild() async {
        guard !sources.isEmpty else { return }
        building = true
        let (m, src, w, h, c, r, a) = (mode, sources, frameW, frameH, frameCount, rotFrames, alpha)
        let result: Result<EditorDecodedSprite, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let s = try Self.build(mode: m, sources: src, w: w, h: h, count: c, rot: r, alpha: a)
                guard let d = EditorDecodedSprite(s) else { throw GraphicsEncodeError.badInput("preview failed") }
                return .success(d)
            } catch { return .failure(error) }
        }.value
        building = false
        switch result {
        case .success(let d): preview = d; error = nil
        case .failure(let e): preview = nil; error = "\(e)"
        }
    }

    private func commit() {
        guard let preview else { return }
        do {
            let bytes: Data
            switch key.type {
            case NovaType.rleD: bytes = try RLEDEncoder.encode(preview.sheet, alphaThreshold: UInt8(alpha))
            case NovaType.rle8: bytes = try RLE8Encoder.encode(preview.sheet, alphaThreshold: UInt8(alpha))
            case NovaType.pict: bytes = try PICTEncoder.encode(preview.sheet, depth: pictDepth16 ? .bits16 : .bits32)
            case NovaType.cicn: bytes = try CICNEncoder.encode(preview.sheet, alphaThreshold: UInt8(alpha))
            default: return
            }
            model.writeData(bytes, for: key, label: "Import image into \(key)")
            done()
        } catch { self.error = "\(error)" }
    }
}
#endif
