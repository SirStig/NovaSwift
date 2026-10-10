import SwiftUI
import ImageIO

/// Plays a GIF named by a `dësc` movie field (e.g. EV Classic's "EV Haikus.gif")
/// once through, then calls `onFinish`. Frames come from ImageIO.
struct AnimatedGIFView: View {
    let url: URL
    let onFinish: () -> Void

    private struct Frames {
        var images: [CGImage] = []
        var delays: [Double] = []
        var total: Double { delays.reduce(0, +) }
    }

    @State private var frames = Frames()
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            if let img = frame(at: t) {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: load)
    }

    private func frame(at t: Double) -> CGImage? {
        guard !frames.images.isEmpty else { return nil }
        if t >= frames.total {
            DispatchQueue.main.async(execute: onFinish)
            return frames.images.last
        }
        var acc = 0.0
        for (i, d) in frames.delays.enumerated() {
            acc += d
            if t < acc { return frames.images[i] }
        }
        return frames.images.last
    }

    private func load() {
        var f = Frames()
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            for i in 0..<CGImageSourceGetCount(src) {
                guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                f.images.append(img); f.delays.append(d < 0.02 ? 0.1 : d)
            }
        }
        if f.images.isEmpty { DispatchQueue.main.async(execute: onFinish); return }
        frames = f; start = Date()
    }
}
