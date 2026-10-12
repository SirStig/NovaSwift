#if os(macOS)
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import NovaSwiftKit

@MainActor
final class EditorSoundPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    private var player: AVAudioPlayer?

    func play(wav: Data) {
        stop()
        guard let p = try? AVAudioPlayer(data: wav) else { return }
        p.delegate = self
        player = p
        playing = p.play()
    }

    func stop() { player?.stop(); player = nil; playing = false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}

struct SoundEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel
    @StateObject private var player = EditorSoundPlayer()

    @State private var sound: NovaSound?
    @State private var peaks: [Float] = []
    @State private var failure: String?
    @State private var bits: SoundImport.BitDepth = .sixteen
    @State private var rate: Double = 22050
    @State private var message: String?

    private struct Decoded: @unchecked Sendable { let sound: NovaSound?; let peaks: [Float]; let error: String? }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    if player.playing { player.stop() } else if let s = sound { player.play(wav: s.wavData()) }
                } label: { Label(player.playing ? "Stop" : "Play", systemImage: player.playing ? "stop.fill" : "play.fill") }
                    .disabled(sound == nil)
                Button { exportWAV() } label: { Label("Export WAV…", systemImage: "square.and.arrow.up") }.disabled(sound == nil)
                Divider().frame(height: 18)
                Button { importAudio() } label: { Label("Import WAV/AIFF…", systemImage: "square.and.arrow.down") }
                Picker("", selection: $bits) { Text("16-bit").tag(SoundImport.BitDepth.sixteen); Text("8-bit").tag(SoundImport.BitDepth.eight) }
                    .labelsHidden().frame(width: 90)
                Picker("", selection: $rate) { ForEach([11025.0, 22050, 44100], id: \.self) { Text("\(Int($0)) Hz").tag($0) } }
                    .labelsHidden().frame(width: 100)
                Spacer()
            }.controlSize(.small)

            if let sound {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    var path = Path()
                    for (i, p) in peaks.enumerated() {
                        let x = CGFloat(i) * step
                        path.move(to: CGPoint(x: x, y: mid - CGFloat(p) * mid))
                        path.addLine(to: CGPoint(x: x, y: mid + CGFloat(p) * mid))
                    }
                    ctx.stroke(path, with: .color(novaAmber), lineWidth: max(1, step))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                               with: .color(.white.opacity(0.15)), lineWidth: 1)
                }
                .frame(height: 110)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                Text(String(format: "%.2f s · %d Hz · %d samples · %d bytes", sound.duration, Int(sound.sampleRate),
                            sound.frameCount, data.count))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            } else if let failure {
                EditorEmptyState(icon: "waveform", title: failure, subtitle: "Use Raw to inspect the bytes.")
                    .frame(minHeight: 140)
            } else {
                // Still decoding: waveform-shaped placeholder.
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)).frame(height: 110)
                        .overlay { ProgressView().controlSize(.small).tint(novaAmber) }
                    SkeletonBar(width: 260, height: 9)
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .task(id: DecodeID(key: key, rev: model.dataRevision)) { await decode() }
        .onDisappear { player.stop() }
        .onChange(of: key) { _, _ in player.stop() }
    }

    /// Keyed by data revision (not by hashing the whole blob on every body pass).
    private struct DecodeID: Hashable { let key: ResourceKey; let rev: Int }

    private func decode() async {
        let d = data
        let r = await Task.detached(priority: .userInitiated) { () -> Decoded in
            do {
                let s = try SndDecoder.decode(d)
                let bins = 600
                var out = [Float](repeating: 0, count: bins)
                let n = s.samples.count
                if n > 0 {
                    for b in 0..<bins {
                        let lo = b * n / bins, hi = max(lo + 1, (b + 1) * n / bins)
                        var m: Float = 0
                        for i in lo..<min(hi, n) { m = max(m, abs(s.samples[i])) }
                        out[b] = min(1, m)
                    }
                }
                return Decoded(sound: s, peaks: out, error: nil)
            } catch { return Decoded(sound: nil, peaks: [], error: "\(error)") }
        }.value
        sound = r.sound; peaks = r.peaks; failure = r.error
    }

    private func exportWAV() {
        guard let sound else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.wav]
        p.nameFieldStringValue = "snd-\(key.id).wav"
        guard p.runModal() == .OK, let url = p.url else { return }
        try? sound.wavData().write(to: url, options: .atomic)
    }

    private func importAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.wav, .aiff, .audio]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let audio = try SoundImport.decodeAudioFile(at: url)
            let snd = try SoundImport.makeSnd(audio, bits: bits, sampleRate: rate)
            model.writeData(snd, for: key, label: "Import sound into \(key)")
            message = nil
        } catch { message = "Import failed: \(error)" }
    }
}
#endif
