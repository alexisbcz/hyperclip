import AppKit
import AVFoundation

/// Reading videos: their size and length, a thumbnail, their sound for transcription, and converting what AVFoundation can't play.
nonisolated enum Media {
    struct Info: Sendable {
        var duration: Double
        /// As displayed, rotation applied.
        var size: CGSize
        var isPlayable: Bool
        var hasAudio: Bool
    }

    enum Failure: LocalizedError {
        case noVideo, noAudio, unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "This file has no video in it."
            case .noAudio: "This video has no sound to transcribe."
            case .unreadable(let detail): "Couldn't read the video: \(detail)"
            }
        }
    }

    static func info(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let decodable = try await track.load(.isPlayable)
        return Info(duration: duration.seconds, size: CGSize(width: abs(size.width), height: abs(size.height)),
                    isPlayable: playable && decodable, hasAudio: !audio.isEmpty)
    }

    static func thumbnail(of url: URL, at seconds: Double, to file: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: file)
    }

    /// Re-encodes to H.264 and AAC with the Mac's hardware encoder, for VP9, AV1 or other files AVFoundation won't open.
    static func convert(_ url: URL, to destination: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try Tools.require(.ffmpeg)
        try? FileManager.default.removeItem(at: destination)
        try await Shell.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-i", url.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            "-progress", "pipe:1", destination.path,
        ]) { line in
            guard line.hasPrefix("out_time_us="), duration > 0, let micro = Double(line.dropFirst(12)) else { return }
            progress(min(1, micro / 1_000_000 / duration))
        }
    }

    /// The sound as 16 kHz mono WAV, which every transcription engine takes, plus how loud it is ten times a second.
    static func extractAudio(_ url: URL, to wav: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "unknown error") }

        try? FileManager.default.removeItem(at: wav)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw Failure.unreadable("no audio format")
        }
        let file = try AVAudioFile(forWriting: wav, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let window = Int(sampleRate / Project.loudnessRate)
        var loudness: [Float] = []
        var sum: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / MemoryLayout<Float>.size
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0]
            else { continue }
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * MemoryLayout<Float>.size, destination: channel)
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            for index in 0..<frames {
                sum += channel[index] * channel[index]
                count += 1
                if count == window {
                    loudness.append(level(sum / Float(count)))
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { loudness.append(level(sum / Float(count))) }
        if reader.status == .failed { throw Failure.unreadable(reader.error?.localizedDescription ?? "unknown error") }
        return loudness
    }

    /// Part of the sound as a 16 kHz mono, 16-bit WAV file in memory, for models that listen.
    static func audioClip(_ url: URL, range: ClosedRange<Double>) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        let sampleRate = 16_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "unknown error") }
        var samples = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: length)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(chunk)
        }
        if reader.status == .failed { throw Failure.unreadable(reader.error?.localizedDescription ?? "unknown error") }

        func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8) + bytes(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        wav += bytes(UInt32(16)) + bytes(UInt16(1)) + bytes(UInt16(1)) + bytes(UInt32(sampleRate)) + bytes(UInt32(sampleRate * 2))
        wav += bytes(UInt16(2)) + bytes(UInt16(16)) + Data("data".utf8) + bytes(UInt32(samples.count)) + samples
        return wav
    }

    /// Mean square power to 0...1, from -50 dB up to full scale.
    private static func level(_ power: Float) -> Float {
        let decibels = 10 * log10(max(power, 1e-10))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
