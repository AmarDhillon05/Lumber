// Runs one 7.8 s Demucs segment through ONNX Runtime (Core ML EP or CPU).
// The STFT, chunking and stem summing live in LumberCore (`Demucs`); this is
// only the model call. The graph is htdemucs exported without STFT, with
// attention computed in row slices (see scripts/separation/chunk_attention.py).

import Foundation
import LumberCore
import OnnxRuntimeBindings

enum OrtRunnerError: LocalizedError {
    case missingOutput(String)
    var errorDescription: String? {
        switch self {
        case .missingOutput(let name): "The drum-removal model returned no \(name)"
        }
    }
}

/// Calls are made one at a time by `Demucs.separate`, so the session is never
/// used concurrently; hence `@unchecked Sendable`.
final class OrtDemucsRunner: DemucsRunner, @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let runOptions: ORTRunOptions

    init(modelPath: String, config: SeparationSessionConfig) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let options = try ORTSessionOptions()
        if config.intraOpThreads > 0 {
            try options.setIntraOpNumThreads(Int32(config.intraOpThreads))
        }
        try options.setGraphOptimizationLevel(config.basicOptimization ? ORTGraphOptimizationLevel.basic : ORTGraphOptimizationLevel.all)
        if config.useCoreML {
            let coreml = ORTCoreMLExecutionProviderOptions()
            coreml.createMLProgram = true
            coreml.onlyAllowStaticInputShapes = true
            try options.appendCoreMLExecutionProvider(with: coreml)
        }
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        runOptions = try ORTRunOptions()
        // Hand the CPU arena's memory back after every run instead of keeping
        // the peak (with the default arena a CPU run held ~5 GB after two chunks).
        try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    }

    func run(mix: [Float], mag: [Float]) async throws -> DemucsOutputs {
        let mixValue = try ORTValue(
            tensorData: NSMutableData(data: mix.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: ORTTensorElementDataType.float,
            shape: [1, 2, NSNumber(value: Demucs.segment)]
        )
        let magValue = try ORTValue(
            tensorData: NSMutableData(data: mag.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: ORTTensorElementDataType.float,
            shape: [1, 4, NSNumber(value: Demucs.bins), NSNumber(value: Demucs.frames)]
        )
        let outputs = try session.run(
            withInputs: ["mix": mixValue, "mag": magValue],
            outputNames: ["spec_out", "wave_out"],
            runOptions: runOptions
        )
        guard let spec = outputs["spec_out"] else { throw OrtRunnerError.missingOutput("spectrogram") }
        guard let wave = outputs["wave_out"] else { throw OrtRunnerError.missingOutput("waveform") }
        return DemucsOutputs(spec: try floats(spec), wave: try floats(wave))
    }

    private func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
