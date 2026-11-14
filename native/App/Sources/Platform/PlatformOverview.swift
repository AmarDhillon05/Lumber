// iOS platform services for Lumber (native).
//
//   AudioSessionManager  .playAndRecord / .measurement session, route + interruptions
//   TakeEngine           song + count-in + mic on one AVAudioEngine clock → TakeResult
//   LatencyCalibrator    click loopback per output route (LatencyStore)
//   PreviewPlayer        editor playback: backing / original drums / processed drums
//   CameraRecorder       video-only AVCaptureMovieFileOutput, start in host time
//   CameraPreviewLayerView  SwiftUI preview layer (UIViewRepresentable)
//   MediaExporter        mux video + mix, M4A, video info, thumbnails
//   PhotoLibrary         add-only save to Photos
//   ShareSheet           UIActivityViewController for SwiftUI
//   AudioFileIO          decode any audio file to float channels at a rate; write WAV
//   TakeClock            pure sync math (Linux-testable)
//   CoreBridge           the only file importing LumberCore
//
// Info.plist keys the app needs: NSMicrophoneUsageDescription,
// NSCameraUsageDescription, NSPhotoLibraryAddUsageDescription.
//
// ── Only verifiable on a device ────────────────────────────────────────────
// 1. Sync: record a take of hits on the click/count-in with the phone on the
//    speaker and on wired/Bluetooth headphones; check TakeDiagnostics
//    (songStartDeviationMs ≈ 0, fileStartSpreadMs < 1) and that drum hits
//    land on the beat in the editor without nudge after calibration.
//    Assumption to confirm: render/tap host times exclude
//    AVAudioSession.outputLatency/inputLatency (calibration's residual
//    absorbs it if not, but a large residual on wired headphones means the
//    assumption is wrong and the reported latency should not be added).
// 2. play(at:) with host time on two player nodes starts them in the same
//    render cycle (count-in → song gap exact); a `.loops` buffer queued
//    after a file segment plays seamlessly.
// 3. Tap `when.hostTime` is valid on the input node (syncSource ==
//    .inputTimestamps), and tap buffers arrive contiguously.
// 4. .measurement mode: speaker output level is lower than default mode on
//    some iPhones; check count-in and song are loud enough on the speaker.
// 5. Bluetooth A2DP: route key, reported outputLatency (often ~150–250 ms)
//    and calibration residual; HFP off keeps the built-in mic.
// 6. Camera: iOS 18 `startPTS` delegate fires and agrees (<1 frame) with the
//    recordedDuration estimate; the clip is portrait (videoRotationAngle 90);
//    capture session doesn't disturb the audio engine (no audio input,
//    automaticallyConfiguresApplicationAudioSession = false).
// 7. Interruptions: phone call / Siri during a take → onInterrupted, stop()
//    still returns a valid take; unplugging headphones mid-take likewise.
// 8. Export: mp4 preset availability, preferredTransform kept, AAC M4A plays
//    in Files/Music; Photos add-only prompt.
// 9. Memory: PreviewPlayer holds the backing as ~0.5 s buffers (a 5-min
//    stereo song at 48 kHz ≈ 115 MB plus the caller's copy).

enum PlatformServices {
    static let version = "0.1.0"
}
