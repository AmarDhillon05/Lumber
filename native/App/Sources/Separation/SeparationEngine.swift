// On-device drum removal for the native app: downloads the model once, decodes
// the song to 44.1 kHz stereo, runs `Demucs.separate` (LumberCore) through
// ONNX Runtime, and streams the drums / no-drums stems to float WAVs cached per
// song. Crash breadcrumbs step the next run down to a safer mode (see
// LumberCore/Separation/SeparationModes.swift).

import AVFoundation
import Foundation
import LumberCore

struct StemFiles: Sendable, Equatable {
    var drums: URL
    var noDrums: URL
    var sampleRate: Int { Demucs.sampleRate }
}

enum SeparationError: LocalizedError {
    case download(String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .download(let m): "Couldn't download the drum-removal model: \(m)"
        case .decode(let m): "Couldn't read the song: \(m)"
        }
    }
}

/// Holds no mutable state of its own (everything lives in files), so it can be
/// shared freely; heavy work runs on the caller's task, off the main actor.
final class SeparationEngine: @unchecked Sendable {
    static let shared = SeparationEngine()

    /// Built and published by .github/workflows/model.yml.
    static let modelURL = URL(string: "https://github.com/AmarDhillon05/Lumber/releases/download/models-v1/htdemucs_chunked.onnx")!
    static let modelFileName = "htdemucs_chunked_v1.onnx"

    private let fm = FileManager.default
    private var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var modelsDir: URL { documents.appendingPathComponent("lumber/models", isDirectory: true) }
    private var modelFile: URL { modelsDir.appendingPathComponent(Self.modelFileName) }
    private var modelDone: URL { modelsDir.appendingPathComponent(Self.modelFileName + ".done") }
    private var stateFile: URL { modelsDir.appendingPathComponent("separation-state.json") }
    private func stemsDir(_ key: String) -> URL { documents.appendingPathComponent("lumber/stems/\(key)", isDirectory: true) }

    // MARK: Crash breadcrumbs

    private func readState() -> SeparationModeState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SeparationModeState.self, from: data) else { return SeparationModeState() }
        return state
    }

    private func writeState(_ state: SeparationModeState) {
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }

    /// If the last run never finished (the app was killed), step down a mode
    /// and return a message for the user.
    func checkForCrash() -> String? {
        let (state, crashed) = readState().recoveringFromCrash()
        guard let crashed else { return nil }
        writeState(state)
        return separationCrashMessage(crashed, next: state.mode)
    }

    func currentModeLabel() -> String { readState().mode.label }

    // MARK: Model

    func isModelDownloaded() -> Bool { fm.fileExists(atPath: modelFile.path) && fm.fileExists(atPath: modelDone.path) }

    func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if isModelDownloaded() { return modelFile }
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let temp = try await ProgressDownload.run(Self.modelURL, progress: progress)
        try? fm.removeItem(at: modelFile)
        try fm.moveItem(at: temp, to: modelFile)
        try Data("\(Date().timeIntervalSince1970)".utf8).write(to: modelDone)
        return modelFile
    }

    // MARK: Separation

    func cached(songKey: String) -> StemFiles? {
        let dir = stemsDir(songKey)
        guard fm.fileExists(atPath: dir.appendingPathComponent("done.json").path) else { return nil }
        return StemFiles(drums: dir.appendingPathComponent("drums.wav"), noDrums: dir.appendingPathComponent("no_drums.wav"))
    }

    /// Progress: model download (if needed) fills the first 20 %, separation the rest.
    func separate(songURL: URL, songKey: String, progress: @escaping @Sendable (Double) -> Void) async throws -> StemFiles {
        if let cached = cached(songKey: songKey) { return cached }
        _ = checkForCrash()
        let split = isModelDownloaded() ? 0.0 : 0.2
        let model = try await ensureModel { progress($0 * split) }

        var state = readState()
        let mode = state.mode
        func crumb(_ stage: SeparationBreadcrumb.Stage, chunk: Int? = nil, total: Int? = nil) {
            state.inProgress = SeparationBreadcrumb(mode: mode, stage: stage, chunk: chunk, total: total)
            writeState(state)
        }
        defer {
            // A thrown error isn't a crash: clear the breadcrumb either way.
            var s = readState()
            s.inProgress = nil
            writeState(s)
        }

        crumb(.decode)
        let input = try decodeStereo(songURL, sampleRate: Double(Demucs.sampleRate))

        crumb(.load)
        let runner = try OrtDemucsRunner(modelPath: model.path, config: mode.sessionConfig)

        let dir = stemsDir(songKey)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = StemFiles(drums: dir.appendingPathComponent("drums.wav"), noDrums: dir.appendingPathComponent("no_drums.wav"))
        var sink = try WavPairSink(drums: files.drums, noDrums: files.noDrums)
        do {
            crumb(.run, chunk: 0)
            let pause = mode.pauseBetweenChunks
            try await Demucs.separate(
                input: input,
                runner: runner,
                sink: &sink,
                onProgress: { progress(split + $0 * (1 - split)) },
                afterChunk: { chunk, total in
                    crumb(.run, chunk: chunk, total: total)
                    if pause > .zero { try await Task.sleep(for: pause) }
                    await Task.yield()
                }
            )
            try sink.finish()
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        let done = ["songKey": songKey, "mode": mode.rawValue, "createdAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: done).write(to: dir.appendingPathComponent("done.json"))
        return files
    }

    /// Any audio file → [left, right] floats at `sampleRate`.
    private func decodeStereo(_ url: URL, sampleRate: Double) throws -> [[Float]] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw SeparationError.decode(error.localizedDescription) }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw SeparationError.decode("unsupported audio format")
        }
        let ratio = sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SeparationError.decode("out of memory") }
        let chunk: AVAudioFrameCount = 32_768
        var readError: Error?
        var finished = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if finished { outStatus.pointee = .endOfStream; return nil }
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: buf, frameCount: chunk) } catch { readError = error }
            if buf.frameLength == 0 {
                finished = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }
        if let readError { throw SeparationError.decode(readError.localizedDescription) }
        if status == .error { throw SeparationError.decode(convError?.localizedDescription ?? "conversion failed") }
        let n = Int(out.frameLength)
        guard let data = out.floatChannelData else { throw SeparationError.decode("no samples") }
        return (0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }
}

/// Writes the two stems as they stream out of `Demucs.separate`.
private struct WavPairSink: StemSink {
    let drums: FloatWavWriter
    let noDrums: FloatWavWriter
    init(drums: URL, noDrums: URL) throws {
        self.drums = try FloatWavWriter(url: drums, sampleRate: Demucs.sampleRate, channels: 2)
        self.noDrums = try FloatWavWriter(url: noDrums, sampleRate: Demucs.sampleRate, channels: 2)
    }
    mutating func write(drums d: [[Float]], noDrums n: [[Float]]) async throws {
        try drums.write(d)
        try noDrums.write(n)
    }
    func finish() throws {
        try drums.finish()
        try noDrums.finish()
    }
}

/// A download with byte progress (async `URLSession.download` doesn't report it).
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func run(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDownload(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns: move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".onnx")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw SeparationError.download("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: SeparationError.download(error.localizedDescription))
            continuation = nil
        }
    }
}
