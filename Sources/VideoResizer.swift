import Foundation
import AVFoundation

enum VideoResizer {
    struct Probe {
        var size: CGSize
        var codec: String
        var duration: Double
    }

    static let webCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1"]

    static func probe(_ url: URL) async -> Probe? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform, descs) = try? await track.load(.naturalSize, .preferredTransform,
                                                                      .formatDescriptions),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        let code = descs.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        return Probe(size: CGSize(width: abs(r.width), height: abs(r.height)), codec: codec,
                     duration: duration.seconds)
    }

    static func fileType(forExtension ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    private static func composition(_ asset: AVURLAsset, width: Int, height: Int,
                                    fit: FitMode, padWhite: Bool) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw CrateError("No video track") }
        let (natural, transform, frame) = try await track.load(.naturalSize, .preferredTransform,
                                                               .minFrameDuration)
        let duration = try await asset.load(.duration)

        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let W = CGFloat(width), H = CGFloat(height)
        let sx = W / oriented.width, sy = H / oriented.height
        let scale = fit == .fill ? max(sx, sy) : min(sx, sy)
        let t = transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (W - oriented.width * scale) / 2,
                                             y: (H - oriented.height * scale) / 2))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(gray: padWhite ? 1 : 0, alpha: 1)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = frame.isValid && frame.seconds > 0
            ? frame : CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }

    /// Renders to H.264 MP4 at the given size. Returns a warning when the size cap can't be met.
    static func render(_ url: URL, to dst: URL, width: Int, height: Int, fit: FitMode, padWhite: Bool,
                       strip: Bool, capBytes: Int?) async throws -> String? {
        let w = width + width % 2, h = height + height % 2
        let asset = AVURLAsset(url: url)
        let comp = try await composition(asset, width: w, height: h, fit: fit, padWhite: padWhite)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw CrateError("Can't create export session") }
        session.videoComposition = comp
        session.shouldOptimizeForNetworkUse = true
        if strip { session.metadataItemFilter = .forSharing() }
        try await session.export(to: dst, as: .mp4)

        guard let capBytes, ImageResizer.fileSize(dst) > capBytes else { return nil }
        let seconds = try await asset.load(.duration).seconds
        var budget = Double(capBytes) * 8 * 0.95 / max(seconds, 0.1) - 256_000 - 64_000
        for _ in 0..<3 {
            guard budget >= 300_000 else {
                return "Can't fit under the size cap without dropping below 300 kbps"
            }
            try? FileManager.default.removeItem(at: dst)
            try await encode(asset, composition: comp, to: dst, width: w, height: h, bitrate: Int(budget))
            if ImageResizer.fileSize(dst) <= capBytes { return nil }
            budget *= 0.85
        }
        return "Still over size cap (\(ImageResizer.mb(ImageResizer.fileSize(dst))))"
    }

    static func remux(_ url: URL, to dst: URL, as type: AVFileType, strip: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw CrateError("Can't create export session") }
        if strip { session.metadataItemFilter = .forSharing() }
        session.shouldOptimizeForNetworkUse = type != .mov
        try await session.export(to: dst, as: type)
    }

    private static func encode(_ asset: AVURLAsset, composition: AVVideoComposition, to dst: URL,
                               width: Int, height: Int, bitrate: Int) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let fps = try await videoTracks.first?.load(.nominalFrameRate) ?? 30

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.videoComposition = composition
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: max(Int(fps.rounded()) * 2, 1),
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var pairs: [(AVAssetWriterInput, AVAssetReaderOutput)] = [(videoIn, videoOut)]

        if !audioTracks.isEmpty {
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(audioOut)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
            pairs.append((audioIn, audioOut))
        }

        guard reader.startReading() else { throw reader.error ?? CrateError("Can't read video") }
        guard writer.startWriting() else { throw writer.error ?? CrateError("Can't write video") }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (i, (input, output)) in pairs.enumerated() {
                group.addTask { await pump(input, output, label: "crate.pump.\(i)") }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? CrateError("Video read failed")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CrateError("Video write failed") }
    }

    private static func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        finished = true
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }
}
