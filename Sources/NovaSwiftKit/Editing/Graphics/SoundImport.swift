import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Mono floating-point audio in [-1, 1] at a sample rate: the interchange
/// form between importers (WAV, AIFF, AVAudio) and the `snd ` writer.
public struct PCMAudio: Sendable, Equatable {
    public var sampleRate: Double
    public var samples: [Float]
    public init(sampleRate: Double, samples: [Float]) { self.sampleRate = sampleRate; self.samples = samples }
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Wraps PCM into classic `snd ` resources that `SndDecoder` (and the game)
/// read: format 1, one `sampledSynth` data format, a single `bufferCmd`.
///
/// - 8-bit: standard sampled-sound header, unsigned samples.
/// - 16-bit: extended sampled-sound header (encode 0xFF), signed big-endian.
///
/// Mono only (the original plays nothing for multi-channel sounds); stereo
/// inputs are averaged to mono on import.
public enum SoundImport {

    public enum BitDepth: Int, Sendable { case eight = 8, sixteen = 16 }

    // MARK: snd  writer

    /// Build a `snd ` resource body. `sampleRate` nil keeps the audio's rate
    /// (22050 Hz is typical for EV Nova effects); otherwise the audio is
    /// linearly resampled first.
    public static func makeSnd(_ audio: PCMAudio, bits: BitDepth = .sixteen,
                               sampleRate: Double? = nil) throws -> Data {
        var a = audio
        if let r = sampleRate, abs(r - audio.sampleRate) > 0.0001 { a = resample(audio, to: r) }
        guard a.sampleRate >= 1, a.sampleRate < 65536 else {
            throw GraphicsEncodeError.badInput("sample rate \(a.sampleRate)")
        }
        let n = a.samples.count
        let rateFixed = Int(a.sampleRate * 65536)
        var b = [UInt8]()
        b.reserveCapacity(0x60 + n * bits.rawValue / 8)
        b.appendBE16(1)                       // format 1
        b.appendBE16(1)                       // one data format
        b.appendBE16(5)                       // sampledSynth
        b.appendBE32(0x0000_0080)             // initMono
        b.appendBE16(1)                       // one command
        b.appendBE16(0x8051)                  // bufferCmd | dataOffsetFlag
        b.appendBE16(0)                       // param1
        b.appendBE32(20)                      // param2: header offset

        b.appendBE32(0)                       // samplePtr (data follows)
        switch bits {
        case .eight:
            b.appendBE32(n)                   // length
            b.appendBE32(rateFixed)
            b.appendBE32(0); b.appendBE32(0)  // loop start/end
            b.append(0)                       // encode: standard
            b.append(60)                      // base frequency (middle C)
            for s in a.samples {
                let v = (max(-1, min(1, s)) * 127.5 + 127.5).rounded()
                b.append(UInt8(max(0, min(255, v))))
            }
        case .sixteen:
            b.appendBE32(1)                   // numChannels
            b.appendBE32(rateFixed)
            b.appendBE32(0); b.appendBE32(0)  // loop start/end
            b.append(0xFF)                    // encode: extended
            b.append(60)
            b.appendBE32(n)                   // numFrames
            b.append(contentsOf: extended80(a.sampleRate))
            b.appendBE32(0); b.appendBE32(0); b.appendBE32(0)   // marker, instrument, AES
            b.appendBE16(16)                  // sampleSize
            b.append(contentsOf: [UInt8](repeating: 0, count: 14))   // future use -> data at +0x40
            for s in a.samples {
                let v = Int16(max(-32768, min(32767, (max(-1, min(1, s)) * 32767).rounded())))
                b.appendBE16(Int(UInt16(bitPattern: v)))
            }
        }
        return Data(b)
    }

    /// WAV bytes -> `snd `.
    public static func makeSnd(wav: Data, bits: BitDepth = .sixteen, sampleRate: Double? = nil) throws -> Data {
        try makeSnd(parseWAV(wav), bits: bits, sampleRate: sampleRate)
    }

    // MARK: Resampling

    /// Linear-interpolation resample (box-averaged first when decimating by > 1.5x).
    public static func resample(_ a: PCMAudio, to rate: Double) -> PCMAudio {
        guard rate > 0, a.sampleRate > 0, !a.samples.isEmpty, abs(rate - a.sampleRate) > 0.0001 else {
            return PCMAudio(sampleRate: rate > 0 ? rate : a.sampleRate, samples: a.samples)
        }
        let ratio = a.sampleRate / rate
        let outCount = max(1, Int((Double(a.samples.count) / ratio).rounded()))
        var out = [Float](repeating: 0, count: outCount)
        let src = a.samples
        let last = src.count - 1
        if ratio > 1.5 {
            for i in 0..<outCount {
                let lo = Int(Double(i) * ratio), hi = min(last, max(lo, Int(Double(i + 1) * ratio) - 1))
                var sum: Float = 0
                for k in lo...hi { sum += src[min(k, last)] }
                out[i] = sum / Float(hi - lo + 1)
            }
        } else {
            for i in 0..<outCount {
                let p = Double(i) * ratio
                let i0 = min(last, Int(p)), i1 = min(last, i0 + 1)
                let f = Float(p - Double(i0))
                out[i] = src[i0] * (1 - f) + src[i1] * f
            }
        }
        return PCMAudio(sampleRate: rate, samples: out)
    }

    // MARK: Pure-Swift WAV

    /// RIFF/WAVE PCM (8/16/24/32-bit integer or 32-bit float), any channel
    /// count (averaged to mono).
    public static func parseWAV(_ data: Data) throws -> PCMAudio {
        let b = [UInt8](data)
        func le16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func le32(_ p: Int) -> Int { le16(p) | le16(p + 2) << 16 }
        guard b.count >= 12, b[0...3].elementsEqual("RIFF".utf8), b[8...11].elementsEqual("WAVE".utf8) else {
            throw GraphicsEncodeError.badInput("not a RIFF/WAVE file")
        }
        var p = 12
        var tag = 0, channels = 0, rate = 0, bits = 0
        var pcm: Range<Int>?
        while p + 8 <= b.count {
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            let size = le32(p + 4)
            let body = p + 8
            let end = min(b.count, body + size)
            if id == "fmt ", end - body >= 16 {
                tag = le16(body); channels = le16(body + 2); rate = le32(body + 4); bits = le16(body + 14)
                if tag == 0xFFFE, end - body >= 26 { tag = le16(body + 24) }
            } else if id == "data" {
                pcm = body..<end
                break
            }
            p = body + size + (size & 1)
        }
        guard let range = pcm, channels > 0, rate > 0 else { throw GraphicsEncodeError.badInput("WAV has no fmt/data") }
        guard tag == 1 || tag == 3 else { throw GraphicsEncodeError.unsupported("WAV format tag \(tag) (only PCM/float)") }
        let bytes = bits / 8
        guard [1, 2, 3, 4].contains(bytes), tag != 3 || bytes == 4 else {
            throw GraphicsEncodeError.unsupported("WAV \(bits)-bit samples")
        }
        let frames = range.count / (bytes * channels)
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                let q = range.lowerBound + (f * channels + c) * bytes
                switch (tag, bytes) {
                case (1, 1): sum += (Float(b[q]) - 128) / 128
                case (1, 2): sum += Float(Int16(bitPattern: UInt16(le16(q)))) / 32768
                case (1, 3):
                    let v = Int32(bitPattern: UInt32(b[q]) << 8 | UInt32(b[q + 1]) << 16 | UInt32(b[q + 2]) << 24)
                    sum += Float(v >> 8) / 8388608
                case (1, _): sum += Float(Int32(bitPattern: UInt32(le32(q)))) / 2147483648
                default: sum += Float(bitPattern: UInt32(le32(q)))
                }
            }
            out[f] = sum / Float(channels)
        }
        return PCMAudio(sampleRate: Double(rate), samples: out)
    }

    // MARK: Pure-Swift AIFF / AIFF-C (uncompressed)

    public static func parseAIFF(_ data: Data) throws -> PCMAudio {
        let b = [UInt8](data)
        func be16(_ p: Int) -> Int { Int(b[p]) << 8 | Int(b[p + 1]) }
        func be32(_ p: Int) -> Int { be16(p) << 16 | be16(p + 2) }
        guard b.count >= 12, b[0...3].elementsEqual("FORM".utf8),
              b[8...11].elementsEqual("AIFF".utf8) || b[8...11].elementsEqual("AIFC".utf8) else {
            throw GraphicsEncodeError.badInput("not an AIFF file")
        }
        var p = 12
        var channels = 0, frames = 0, bits = 0, rate = 0.0
        var littleEndian = false
        var ssnd: Range<Int>?
        while p + 8 <= b.count {
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            let size = be32(p + 4), body = p + 8
            let end = min(b.count, body + size)
            if id == "COMM", end - body >= 18 {
                channels = be16(body); frames = be32(body + 2); bits = be16(body + 6)
                rate = decodeExtended80(Array(b[(body + 8)..<(body + 18)]))
                if end - body >= 22 {
                    let comp = String(decoding: b[(body + 18)..<(body + 22)], as: UTF8.self)
                    if comp == "sowt" { littleEndian = true }
                    else if comp != "NONE" && comp != "twos" { throw GraphicsEncodeError.unsupported("AIFF-C compression '\(comp)'") }
                }
            } else if id == "SSND", end - body >= 8 {
                ssnd = (body + 8 + be32(body))..<end
            }
            p = body + size + (size & 1)
        }
        guard let range = ssnd, channels > 0, rate > 0 else { throw GraphicsEncodeError.badInput("AIFF has no COMM/SSND") }
        let bytes = bits / 8
        guard [1, 2, 3, 4].contains(bytes) else { throw GraphicsEncodeError.unsupported("AIFF \(bits)-bit samples") }
        let n = min(frames, range.count / (bytes * channels))
        var out = [Float](repeating: 0, count: n)
        for f in 0..<n {
            var sum: Float = 0
            for c in 0..<channels {
                let q = range.lowerBound + (f * channels + c) * bytes
                switch bytes {
                case 1: sum += Float(Int8(bitPattern: b[q])) / 128
                case 2:
                    let raw = littleEndian ? Int(b[q + 1]) << 8 | Int(b[q]) : be16(q)
                    sum += Float(Int16(bitPattern: UInt16(raw))) / 32768
                case 3:
                    let v = Int32(bitPattern: UInt32(b[q]) << 24 | UInt32(b[q + 1]) << 16 | UInt32(b[q + 2]) << 8)
                    sum += Float(v >> 8) / 8388608
                default: sum += Float(Int32(bitPattern: UInt32(be32(q)))) / 2147483648
                }
            }
            out[f] = sum / Float(channels)
        }
        return PCMAudio(sampleRate: rate, samples: out)
    }

    /// WAV or AIFF by sniffing the header.
    public static func parse(_ data: Data) throws -> PCMAudio {
        if data.starts(with: Array("RIFF".utf8)) { return try parseWAV(data) }
        if data.starts(with: Array("FORM".utf8)) { return try parseAIFF(data) }
        throw GraphicsEncodeError.badInput("not a WAV or AIFF file (use decodeAudioFile for other formats)")
    }

    // MARK: 80-bit extended

    static func extended80(_ rate: Double) -> [UInt8] {
        guard rate > 0 else { return [UInt8](repeating: 0, count: 10) }
        let e = Int(floor(log2(rate)))
        let mant = UInt64((rate / pow(2, Double(e))) * Double(UInt64(1) << 63))
        let exp = e + 16383
        var out = [UInt8](); out.appendBE16(exp)
        for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: mant >> UInt64(s))) }
        return out
    }

    static func decodeExtended80(_ b: [UInt8]) -> Double {
        let exp = (Int(b[0] & 0x7F) << 8 | Int(b[1])) - 16383
        var mant: UInt64 = 0
        for i in 2..<10 { mant = mant << 8 | UInt64(b[i]) }
        return Double(mant) / Double(UInt64(1) << 63) * pow(2, Double(exp))
    }

    // MARK: AVFoundation (any format the system reads)

    #if canImport(AVFoundation)
    /// Decode any audio file AVFoundation understands (MP3, M4A, FLAC, CAF, ...)
    /// to mono floats at its native rate.
    public static func decodeAudioFile(at url: URL) throws -> PCMAudio {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let cap = AVAudioFrameCount(file.length)
        guard cap > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else {
            throw GraphicsEncodeError.badInput("empty audio file")
        }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { throw GraphicsEncodeError.badInput("no float channel data") }
        let n = Int(buf.frameLength), c = Int(fmt.channelCount)
        var out = [Float](repeating: 0, count: n)
        for k in 0..<c { let p = ch[k]; for i in 0..<n { out[i] += p[i] } }
        if c > 1 { let inv = 1 / Float(c); for i in 0..<n { out[i] *= inv } }
        return PCMAudio(sampleRate: fmt.sampleRate, samples: out)
    }
    #endif
}
