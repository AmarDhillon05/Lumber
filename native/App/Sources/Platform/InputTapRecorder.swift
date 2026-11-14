// Receives the input node's tap buffers on AVAudioEngine's tap thread and
// writes them to a WAV (takes) or keeps them in memory (calibration), while
// recording the host time of file sample 0.
//
// Threading: the tap block runs on an arbitrary AVFoundation thread, never on
// the main actor. The block is created in `makeTapBlock()` — a method of this
// non-isolated class — so under Swift 6 it does not inherit @MainActor
// isolation (a main-actor closure called from the tap thread would trap on
// the runtime isolation check). All state is guarded by `lock`.

import AVFoundation

final class InputTapRecorder: @unchecked Sendable {
    struct Summary: Sendable {
        var fileURL: URL?
        /// Channel 0, only in memory mode.
        var samples: [Float]
        var frames: Int64
        var sampleRate: Double
        var channelCount: Int
        /// Host time (seconds) at which file sample 0 was stamped by the input.
        var fileStartHostSec: Double
        var syncSource: TakeSyncSource
        /// RMS spread (ms) of the per-buffer start estimates; ~0 when the tap
        /// delivered contiguous, consistently stamped buffers.
        var startSpreadMs: Double
    }

    /// Buffers used for the start estimate (the median of per-buffer estimates).
    private static let maxEstimates = 64

    let sampleRate: Double
    let channelCount: Int
    private let fileURL: URL?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var memory: [Float]?
    private var frames: Int64 = 0
    private var estimates: [Double] = []
    private var fallbackStart: Double?
    private var writeError: Error?
    private var finished = false

    /// Records to a WAV at the input's rate and channel count.
    init(fileURL: URL, format: AVAudioFormat, sampleFormat: WAVSampleFormat) throws {
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        self.fileURL = fileURL
        try? FileManager.default.removeItem(at: fileURL)
        do {
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: AudioFileIO.wavSettings(sampleRate: format.sampleRate, channels: Int(format.channelCount), format: sampleFormat),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw PlatformError.recordingFailed(error.localizedDescription)
        }
    }

    /// Records channel 0 into memory (calibration).
    init(memoryFormat format: AVAudioFormat, expectedSeconds: Double) {
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        fileURL = nil
        var m = [Float]()
        m.reserveCapacity(Int(expectedSeconds * format.sampleRate))
        memory = m
    }

    var hasAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames > 0
    }

    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, when in
            self.consume(buffer, when: when)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let callbackHost = mach_absolute_time()
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let n = Int64(buffer.frameLength)
        guard n > 0 else { return }

        // Each buffer gives an independent estimate of when sample 0 was
        // stamped: its own host time minus the frames that came before it.
        if estimates.count < Self.maxEstimates {
            let before = Double(frames) / sampleRate
            if when.isHostTimeValid {
                estimates.append(AVAudioTime.seconds(forHostTime: when.hostTime) - before)
            } else if fallbackStart == nil {
                // No timestamp: the callback runs at least one buffer after
                // capture, so this is late by roughly the tap's buffering.
                fallbackStart = AVAudioTime.seconds(forHostTime: callbackHost) - Double(n) / sampleRate - before
            }
        }

        if let file {
            do {
                try file.write(from: buffer)
            } catch {
                writeError = error
                self.file = nil
            }
        }
        if memory != nil, let data = buffer.floatChannelData {
            memory!.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(n)))
        }
        frames += n
    }

    /// Stops accepting buffers and closes the file. Call after removing the tap.
    func finish() throws -> Summary {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        file = nil // closes the WAV
        if let writeError { throw PlatformError.recordingFailed(writeError.localizedDescription) }
        guard frames > 0 else { throw PlatformError.microphoneProducedNoAudio }
        let start: Double
        let source: TakeSyncSource
        var spread = 0.0
        if let m = TakeClock.median(estimates) {
            start = m
            source = .inputTimestamps
            spread = TakeClock.spread(estimates, around: m) * 1000
        } else if let f = fallbackStart {
            start = f
            source = .callbackClock
        } else {
            throw PlatformError.recordingFailed("Could not align the recording to playback")
        }
        return Summary(
            fileURL: fileURL,
            samples: memory ?? [],
            frames: frames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            fileStartHostSec: start,
            syncSource: source,
            startSpreadMs: spread
        )
    }

    /// Stops and deletes whatever was written (failed start).
    func discard() {
        lock.lock()
        finished = true
        file = nil
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
