// Lumber's AVFoundation helpers.
//
//   getVideoInfo(uri)            → { durationSec, width, height, frameRate }
//   muxVideo(options)            → output uri (.mp4, or .mov if mp4 is unavailable)
//   exportM4A(wavUri, outputUri) → output uri (AAC in .m4a)
//
// Both exports emit "onExportProgress" { progress: 0..1 } while running.
// Timing decisions (which part of the clip lines up with which part of the
// mix) are made in JS (src/video/sync.ts); muxVideo only trims and stacks.

import AVFoundation
import ExpoModulesCore

internal struct MuxVideoOptions: Record {
  /// file:// URI of the camera clip (its audio, if any, is ignored).
  @Field var videoUri: String = ""
  /// file:// URI of the mix, already cut to start where the output starts.
  @Field var audioUri: String = ""
  /// file:// URI to write; an existing file is replaced.
  @Field var outputUri: String = ""
  /// Seconds into the clip where the output starts.
  @Field var videoStartSec: Double = 0
  /// Output length in seconds (clamped to what both inputs have).
  @Field var durationSec: Double = 0
}

internal final class LumberMediaError: GenericException<String> {
  override var reason: String {
    param
  }
}

public class LumberMediaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LumberMedia")

    Events("onExportProgress")

    AsyncFunction("getVideoInfo") { (uri: String, promise: Promise) in
      let url = try fileUrl(uri)
      Task {
        do {
          let info = try await loadVideoInfo(url)
          promise.resolve(info)
        } catch {
          promise.reject(error)
        }
      }
    }

    AsyncFunction("muxVideo") { (options: MuxVideoOptions, promise: Promise) in
      let videoUrl = try fileUrl(options.videoUri)
      let audioUrl = try fileUrl(options.audioUri)
      let outputUrl = try fileUrl(options.outputUri)
      let videoStartSec = options.videoStartSec
      let durationSec = options.durationSec
      Task {
        do {
          let (composition, range) = try await buildComposition(
            videoUrl: videoUrl,
            audioUrl: audioUrl,
            videoStartSec: videoStartSec,
            durationSec: durationSec
          )
          guard let made = makeVideoExportSession(composition) else {
            throw LumberMediaError("No video export preset is available on this device")
          }
          let (session, fileType) = made
          let target = fileType == .mov ? outputUrl.deletingPathExtension().appendingPathExtension("mov") : outputUrl
          try? FileManager.default.removeItem(at: target)
          session.outputURL = target
          session.timeRange = range
          session.shouldOptimizeForNetworkUse = true
          self.run(session, promise)
        } catch {
          promise.reject(error)
        }
      }
    }

    AsyncFunction("exportM4A") { (wavUri: String, outputUri: String, promise: Promise) in
      let source = try fileUrl(wavUri)
      let target = try fileUrl(outputUri)
      let asset = AVURLAsset(url: source)
      guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw LumberMediaError("AAC export is not available on this device")
      }
      try? FileManager.default.removeItem(at: target)
      session.outputFileType = .m4a
      session.outputURL = target
      self.run(session, promise)
    }
  }

  /// Runs an export, reporting progress until it finishes, then settles the promise.
  private func run(_ session: AVAssetExportSession, _ promise: Promise) {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 0.1, repeating: 0.2)
    timer.setEventHandler { [weak self] in
      self?.sendEvent("onExportProgress", ["progress": Double(session.progress)])
    }
    timer.resume()

    session.exportAsynchronously { [weak self] in
      timer.cancel()
      if session.status == .completed, let url = session.outputURL {
        self?.sendEvent("onExportProgress", ["progress": 1.0])
        promise.resolve(url.absoluteString)
      } else {
        let message = session.error?.localizedDescription ?? "Export failed (status \(session.status.rawValue))"
        promise.reject(LumberMediaError(message))
      }
    }
  }
}

private func fileUrl(_ uri: String) throws -> URL {
  if uri.hasPrefix("file://"), let url = URL(string: uri) {
    return url
  }
  if uri.hasPrefix("/") {
    return URL(fileURLWithPath: uri)
  }
  throw LumberMediaError("Not a file URI: \(uri)")
}

private func loadVideoInfo(_ url: URL) async throws -> [String: Any] {
  let asset = AVURLAsset(url: url)
  let duration = try await asset.load(.duration)
  var info: [String: Any] = ["durationSec": duration.seconds]
  if let track = try await asset.loadTracks(withMediaType: .video).first {
    let (size, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
    // Display size: naturalSize is the encoded (sensor) orientation.
    let shown = CGRect(origin: .zero, size: size).applying(transform)
    info["width"] = Double(abs(shown.width))
    info["height"] = Double(abs(shown.height))
    info["frameRate"] = Double(frameRate)
  }
  return info
}

/// Clip video from videoStartSec + mix audio from 0, both durationSec long
/// (or as much as both have), stacked at time 0. Keeps the clip's
/// preferredTransform so portrait clips stay portrait.
private func buildComposition(
  videoUrl: URL,
  audioUrl: URL,
  videoStartSec: Double,
  durationSec: Double
) async throws -> (AVMutableComposition, CMTimeRange) {
  let video = AVURLAsset(url: videoUrl)
  let audio = AVURLAsset(url: audioUrl)
  guard let videoTrack = try await video.loadTracks(withMediaType: .video).first else {
    throw LumberMediaError("The camera clip has no video track")
  }
  guard let audioTrack = try await audio.loadTracks(withMediaType: .audio).first else {
    throw LumberMediaError("The mix has no audio track")
  }
  let (videoRange, transform) = try await videoTrack.load(.timeRange, .preferredTransform)
  let audioRange = try await audioTrack.load(.timeRange)

  let videoStart = CMTimeAdd(videoRange.start, CMTime(seconds: max(0, videoStartSec), preferredTimescale: 60000))
  let wanted = CMTime(seconds: max(0, durationSec), preferredTimescale: 48000)
  let videoLeft = CMTimeSubtract(videoRange.end, videoStart)
  let length = CMTimeMinimum(CMTimeMinimum(wanted, videoLeft), audioRange.duration)
  guard length.isNumeric, length.seconds > 0.05 else {
    throw LumberMediaError("The camera clip and the mix don't overlap")
  }

  let composition = AVMutableComposition()
  guard
    let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
    let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
  else {
    throw LumberMediaError("Could not create composition tracks")
  }
  try videoOut.insertTimeRange(CMTimeRange(start: videoStart, duration: length), of: videoTrack, at: .zero)
  videoOut.preferredTransform = transform
  try audioOut.insertTimeRange(CMTimeRange(start: audioRange.start, duration: length), of: audioTrack, at: .zero)
  return (composition, CMTimeRange(start: .zero, duration: length))
}

/// Highest quality H.264/HEVC to .mp4; .mov as a last resort.
private func makeVideoExportSession(_ asset: AVAsset) -> (AVAssetExportSession, AVFileType)? {
  let candidates: [(String, AVFileType)] = [
    (AVAssetExportPresetHighestQuality, .mp4),
    (AVAssetExportPresetHEVCHighestQuality, .mp4),
    (AVAssetExportPresetHighestQuality, .mov),
    (AVAssetExportPresetHEVCHighestQuality, .mov),
  ]
  for (preset, fileType) in candidates {
    if let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(fileType) {
      session.outputFileType = fileType
      return (session, fileType)
    }
  }
  return nil
}
