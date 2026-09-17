import Foundation
import AVFoundation

enum AudioTools {
    static func probe(_ url: URL) -> AudioInfo? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let asbd = file.fileFormat.streamDescription.pointee
        return AudioInfo(sampleRate: file.fileFormat.sampleRate,
                         bitDepth: Int(asbd.mBitsPerChannel),
                         channels: Int(file.fileFormat.channelCount),
                         isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    private struct XorShift {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private final class EndFlag {
        var ended = false
    }

    /// 16-bit / 44.1 kHz WAV. Mastering-grade SRC when the rate changes; TPDF dither only when
    /// requantising from a deeper source, so a 16/44.1 source round-trips bit for bit.
    static func makeCD(_ url: URL, to dst: URL) throws {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        let ch = inFormat.channelCount
        let asbd = input.fileFormat.streamDescription.pointee
        let needsSRC = inFormat.sampleRate != 44_100
        let isInt16 = asbd.mBitsPerChannel == 16 && asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0
        let dither = needsSRC || !isInt16

        guard let mid = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                      channels: ch, interleaved: false)
        else { throw CrateError("Unsupported channel layout") }
        let output = try AVAudioFile(forWriting: dst, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: ch,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatInt16, interleaved: false)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let midBuf = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: chunk * 5),
              let outBuf = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: chunk * 5)
        else { throw CrateError("Can't allocate audio buffers") }

        var rng = XorShift(seed: 0x9E3779B97F4A7C15)
        func emit(_ buf: AVAudioPCMBuffer) throws {
            let n = Int(buf.frameLength)
            guard n > 0, let src = buf.floatChannelData, let dstPlanes = outBuf.int16ChannelData else { return }
            for c in 0..<Int(ch) {
                for i in 0..<n {
                    var v = Double(src[c][i]) * 32768
                    if dither {
                        v += rng.unit() - rng.unit()
                    }
                    dstPlanes[c][i] = Int16(max(-32768, min(32767, v.rounded())))
                }
            }
            outBuf.frameLength = AVAudioFrameCount(n)
            try output.write(from: outBuf)
        }

        func readChunk() -> Bool {
            (try? input.read(into: inBuf, frameCount: chunk)) != nil && inBuf.frameLength > 0
        }

        guard needsSRC else {
            while readChunk() { try emit(inBuf) }
            return
        }

        guard let converter = AVAudioConverter(from: inFormat, to: mid)
        else { throw CrateError("Can't create sample-rate converter") }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let flag = EndFlag()
        while true {
            midBuf.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: midBuf, error: &error) { _, outStatus in
                if flag.ended || !readChunk() {
                    flag.ended = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw error ?? CrateError("Sample-rate conversion failed") }
            try emit(midBuf)
            if status == .endOfStream || (flag.ended && midBuf.frameLength == 0) { break }
        }
    }

    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func makeMP3(_ url: URL, to dst: URL, sampleRate: Double) throws {
        guard let ffmpeg else { throw CrateError("MP3 needs ffmpeg — brew install ffmpeg") }
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                    "-map", "0:a:0", "-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"]
        if sampleRate > 48_000 {
            let target = sampleRate.truncatingRemainder(dividingBy: 44_100) == 0 ? "44100" : "48000"
            args += ["-af", "aresample=resampler=swr:filter_size=128:phase_shift=10:cutoff=0.97",
                     "-ar", target]
        }
        args.append(dst.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CrateError("ffmpeg: \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
    }
}
