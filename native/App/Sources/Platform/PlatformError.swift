import Foundation

/// Errors thrown by the iOS platform services (audio engine, camera, export).
public enum PlatformError: LocalizedError, Sendable, Equatable {
    case microphonePermissionDenied
    case cameraPermissionDenied
    case photosPermissionDenied
    case noAudioInput
    case microphoneProducedNoAudio
    case songUnreadable(String)
    case engineFailed(String)
    case busy
    case cameraUnavailable
    case notRecording
    case recordingFailed(String)
    case exportFailed(String)
    case noOverlap
    case decodeFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Lumber needs microphone access to record your drums."
        case .cameraPermissionDenied: "Lumber needs camera access to film the take."
        case .photosPermissionDenied: "Lumber needs permission to add videos to your Photos library."
        case .noAudioInput: "No microphone is available."
        case .microphoneProducedNoAudio: "The microphone produced no audio."
        case .songUnreadable(let m): "The song couldn't be opened: \(m)"
        case .engineFailed(let m): "The audio engine failed: \(m)"
        case .busy: "The audio engine is busy."
        case .cameraUnavailable: "No camera is available."
        case .notRecording: "Nothing is being recorded."
        case .recordingFailed(let m): "Recording failed: \(m)"
        case .exportFailed(let m): "Export failed: \(m)"
        case .noOverlap: "The camera clip and the mix don't overlap."
        case .decodeFailed(let m): "The audio couldn't be decoded: \(m)"
        case .writeFailed(let m): "The file couldn't be written: \(m)"
        }
    }
}
