#if os(macOS)
import SwiftUI
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
