import Foundation
import AVFoundation
import EVNovaKit

/// Decodes `snd ` resources from the loaded game data into ready-to-play
/// `AVAudioPCMBuffer`s, resampled to the engine's canonical format and cached by
/// resource id. Decoding is lazy (first play of a given id) and results are
/// retained so repeated fire/hits don't re-decode.
final class NovaSoundLibrary {
    private var game: NovaGame?
    private var cache: [Int: AVAudioPCMBuffer?] = [:]   // nil entry = known-undecodable

    func attach(game: NovaGame?) {
        self.game = game
        cache.removeAll()
    }

    /// The set of sound ids the data provides (for a sound browser / test picker).
    func availableIDs() -> [Int] { game?.soundIDs() ?? [] }
    func name(for id: Int) -> String? { game?.soundName(id) }

    /// A canonical-format buffer for a `snd ` id, decoded and cached. Returns nil
    /// if the sound is missing or uses an unsupported encoding.
    func buffer(for id: Int) -> AVAudioPCMBuffer? {
        if let cached = cache[id] { return cached }
        let built = decodeBuffer(id)
        cache[id] = built            // cache the miss too, so we don't retry decoding
        return built
    }

    private func decodeBuffer(_ id: Int) -> AVAudioPCMBuffer? {
        guard let sound = game?.sound(id), !sound.samples.isEmpty else { return nil }
        let src = sound.samples
        let srcRate = sound.sampleRate > 0 ? sound.sampleRate : GameAudioEngine.canonicalRate
        let dstRate = GameAudioEngine.canonicalRate

        let out: [Float]
        if abs(srcRate - dstRate) < 1 {
            out = src
        } else {
            out = Self.resampleLinear(src, from: srcRate, to: dstRate)
        }
        guard !out.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: GameAudioEngine.canonicalFormat,
                                            frameCapacity: AVAudioFrameCount(out.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        out.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: out.count) }
        buffer.frameLength = AVAudioFrameCount(out.count)
        return buffer
    }

    /// Simple linear resampler. Sound effects are short and low-rate; linear
    /// interpolation is inaudible here and keeps decode cheap.
    static func resampleLinear(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate > 0, dstRate > 0, input.count > 1 else { return input }
        let ratio = srcRate / dstRate
        let outCount = Int(Double(input.count) / ratio)
        guard outCount > 0 else { return input }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            let frac = Float(pos - Double(i0))
            let a = input[i0]
            let b = i0 + 1 < input.count ? input[i0 + 1] : a
            out[i] = a + (b - a) * frac
        }
        return out
    }
}
