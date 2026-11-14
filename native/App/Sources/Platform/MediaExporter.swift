// AVFoundation export work (port of modules/lumber-media/ios/LumberMediaModule.swift):
//
//   videoInfo(url)           → duration, display size, frame rate
//   muxVideo(request)        → camera clip (trimmed) + mixed audio → .mp4 (or .mov)
//   exportM4A(wav, output)   → AAC .m4a (AVAssetExportPresetAppleM4A)
//   thumbnail(...)           → UIImage / JPEG of a video frame
//
// Exports report progress through an AsyncThrowingStream of ExportEvent.
// Timing decisions (which part of the clip lines up with which part of the
// mix — planVideoExport / sampleRange) belong to LumberCore Timing; muxVideo
// only trims and stacks, exactly like the RN module.

import AVFoundation
import UIKit

public struct VideoInfo: Sendable, Equatable {
    public var durationSec: Double
    /// Display size (preferredTransform applied).
    public var width: Double
    public var height: Double
    public var frameRate: Double
}

public struct MuxRequest: Sendable, Equatable {
    /// Camera clip (its audio track, if any, is ignored).
    public var videoURL: URL
    /// The mix, already cut to start where the output starts (WAV or M4A).
    public var audioURL: URL
    /// File to write (replaced). Becomes .mov if no .mp4 preset is available.
    public var outputURL: URL
    /// Seconds into the clip where the output starts.
    public var videoStartSec: Double
    /// Output length (clamped to what both inputs have).
    public var durationSec: Double

    public init(videoURL: URL, audioURL: URL, outputURL: URL, videoStartSec: Double, durationSec: Double) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.outputURL = outputURL
        self.videoStartSec = videoStartSec
        self.durationSec = durationSec
    }
}

public enum ExportEvent: Sendable, Equatable {
    /// 0...1
    case progress(Double)
    case completed(URL)
}

public enum MediaExporter {
    // MARK: Info

    public static func videoInfo(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        var info = VideoInfo(durationSec: duration.isNumeric ? duration.seconds : 0, width: 0, height: 0, frameRate: 0)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            // naturalSize is the encoded (sensor) orientation.
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            info.width = Double(abs(shown.width))
            info.height = Double(abs(shown.height))
            info.frameRate = Double(frameRate)
        }
        return info
    }

    // MARK: Video

    /// Clip video from `videoStartSec` + mix audio from 0, both `durationSec`
    /// long (or as much as both have), stacked at time 0; keeps the clip's
    /// preferredTransform. Highest-quality H.264, then HEVC, to .mp4; .mov last.
    public static func muxVideo(_ request: MuxRequest) -> AsyncThrowingStream<ExportEvent, Error> {
        stream {
            let (composition, range) = try await MediaExporter.buildComposition(request)
            guard let made = MediaExporter.makeVideoExportSession(composition) else {
                throw PlatformError.exportFailed("No video export preset is available on this device")
            }
            let (session, fileType) = made
            let target = fileType == .mov
                ? request.outputURL.deletingPathExtension().appendingPathExtension("mov")
                : request.outputURL
            try? FileManager.default.removeItem(at: target)
            session.outputURL = target
            session.timeRange = range
            session.shouldOptimizeForNetworkUse = true
            return ExportSessionBox(session)
        }
    }

    /// `muxVideo` as a single async call.
    public static func muxVideo(_ request: MuxRequest, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await collect(muxVideo(request), onProgress: onProgress)
    }

    // MARK: Audio

    /// Encodes a WAV (the rendered mix) to AAC in an .m4a.
    public static func exportM4A(wavURL: URL, to outputURL: URL) -> AsyncThrowingStream<ExportEvent, Error> {
        stream {
            let asset = AVURLAsset(url: wavURL)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw PlatformError.exportFailed("AAC export is not available on this device")
            }
            try? FileManager.default.removeItem(at: outputURL)
            session.outputFileType = .m4a
            session.outputURL = outputURL
            return ExportSessionBox(session)
        }
    }

    public static func exportM4A(wavURL: URL, to outputURL: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await collect(exportM4A(wavURL: wavURL, to: outputURL), onProgress: onProgress)
    }

    // MARK: Thumbnails

    /// A frame of the video at `atSec`, upright, at most `maxPixelSize` on its longest side.
    public static func thumbnail(for videoURL: URL, atSec: Double = 0, maxPixelSize: CGFloat = 480) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: CMTime(seconds: max(0, atSec), preferredTimescale: 600))
        return UIImage(cgImage: image)
    }

    /// Writes a JPEG thumbnail to `url` and returns it.
    @discardableResult
    public static func writeThumbnailJPEG(
        for videoURL: URL,
        to url: URL,
        atSec: Double = 0,
        maxPixelSize: CGFloat = 480,
        quality: CGFloat = 0.8
    ) async throws -> URL {
        let image = try await thumbnail(for: videoURL, atSec: atSec, maxPixelSize: maxPixelSize)
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw PlatformError.writeFailed("Could not encode the thumbnail")
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Internals

    private static func buildComposition(_ r: MuxRequest) async throws -> (AVMutableComposition, CMTimeRange) {
        let video = AVURLAsset(url: r.videoURL)
        let audio = AVURLAsset(url: r.audioURL)
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first else {
            throw PlatformError.exportFailed("The camera clip has no video track")
        }
        guard let audioTrack = try await audio.loadTracks(withMediaType: .audio).first else {
            throw PlatformError.exportFailed("The mix has no audio track")
        }
        let (videoRange, transform) = try await videoTrack.load(.timeRange, .preferredTransform)
        let audioRange = try await audioTrack.load(.timeRange)

        let videoStart = CMTimeAdd(videoRange.start, CMTime(seconds: max(0, r.videoStartSec), preferredTimescale: 60_000))
        let wanted = CMTime(seconds: max(0, r.durationSec), preferredTimescale: 48_000)
        let videoLeft = CMTimeSubtract(videoRange.end, videoStart)
        let length = CMTimeMinimum(CMTimeMinimum(wanted, videoLeft), audioRange.duration)
        guard length.isNumeric, length.seconds > 0.05 else { throw PlatformError.noOverlap }

        let composition = AVMutableComposition()
        guard let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PlatformError.exportFailed("Could not create composition tracks") }
        try videoOut.insertTimeRange(CMTimeRange(start: videoStart, duration: length), of: videoTrack, at: .zero)
        videoOut.preferredTransform = transform
        try audioOut.insertTimeRange(CMTimeRange(start: audioRange.start, duration: length), of: audioTrack, at: .zero)
        return (composition, CMTimeRange(start: .zero, duration: length))
    }

    private static func makeVideoExportSession(_ asset: AVAsset) -> (AVAssetExportSession, AVFileType)? {
        let candidates: [(String, AVFileType)] = [
            (AVAssetExportPresetHighestQuality, .mp4),
            (AVAssetExportPresetHEVCHighestQuality, .mp4),
            (AVAssetExportPresetHighestQuality, .mov),
            (AVAssetExportPresetHEVCHighestQuality, .mov),
        ]
        for (preset, fileType) in candidates {
            if let session = AVAssetExportSession(asset: asset, presetName: preset),
               session.supportedFileTypes.contains(fileType) {
                session.outputFileType = fileType
                return (session, fileType)
            }
        }
        return nil
    }

    /// Runs the export built by `make`, yielding progress then `.completed(url)`.
    /// Cancelling the consumer cancels the export.
    private static func stream(
        _ make: @escaping @Sendable () async throws -> ExportSessionBox
    ) -> AsyncThrowingStream<ExportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let box = try await make()
                    let url = try await box.run { continuation.yield(.progress($0)) }
                    continuation.yield(.progress(1))
                    continuation.yield(.completed(url))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func collect(
        _ events: AsyncThrowingStream<ExportEvent, Error>,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        for try await event in events {
            switch event {
            case .progress(let p): onProgress?(p)
            case .completed(let url): return url
            }
        }
        throw PlatformError.exportFailed("The export ended without a file")
    }
}

/// AVAssetExportSession is not Sendable; it is only touched from the export
/// task, its completion handler and the progress poller, which AVFoundation
/// allows (progress/status are thread-safe reads).
final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let poller = Task { [self] in
            while !Task.isCancelled {
                progress(Double(self.session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.session.exportAsynchronously { [self] in
                    switch self.session.status {
                    case .completed:
                        cont.resume()
                    case .cancelled:
                        cont.resume(throwing: CancellationError())
                    default:
                        let message = self.session.error?.localizedDescription
                            ?? "Export failed (status \(self.session.status.rawValue))"
                        cont.resume(throwing: PlatformError.exportFailed(message))
                    }
                }
            }
        } onCancel: {
            self.session.cancelExport()
        }
        guard let url = session.outputURL else { throw PlatformError.exportFailed("No output file") }
        return url
    }
}
