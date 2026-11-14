import Foundation
import XCTest
@testable import LumberCore

// Same deterministic signal and fake model as scripts/native/fixtures-separation.ts.
private func signal(_ n: Int) -> [[Float]] {
    var l = [Float](repeating: 0, count: n), r = l
    for i in 0..<n {
        let x = Double(i)
        l[i] = Float(0.5 * sin(x * 0.01) + 0.3 * sin(x * 0.0371 + 1) + 0.1 * sin(x * 0.5))
        r[i] = Float(0.4 * sin(x * 0.013 + 0.5) + 0.2 * sin(x * 0.11) + 0.05)
    }
    return [l, r]
}

private struct FakeRunner: DemucsRunner {
    static let spec: [Float] = [0.6, 0.2, 0.15, 0.05]
    static let wave: [Float] = [0.05, 0.02, 0.01, 0.0]
    func run(mix: [Float], mag: [Float]) async throws -> DemucsOutputs {
        let plane = Demucs.bins * Demucs.frames, seg = Demucs.segment
        var spec = [Float](repeating: 0, count: 16 * plane)
        for s in 0..<4 { for c in 0..<4 { let base = (s * 4 + c) * plane
            for x in 0..<plane { spec[base + x] = mag[c * plane + x] * Self.spec[s] } } }
        var wave = [Float](repeating: 0, count: 8 * seg)
        for s in 0..<4 { for ch in 0..<2 { let base = (s * 2 + ch) * seg
            for x in 0..<seg { wave[base + x] = mix[ch * seg + x] * Self.wave[s] } } }
        return DemucsOutputs(spec: spec, wave: wave)
    }
}

/// Source 0 (drums) gets the input spectrogram, everything else silence.
private struct IdentityDrumsRunner: DemucsRunner {
    func run(mix: [Float], mag: [Float]) async throws -> DemucsOutputs {
        var spec = [Float](repeating: 0, count: 16 * Demucs.bins * Demucs.frames)
        spec.replaceSubrange(0..<mag.count, with: mag)
        return DemucsOutputs(spec: spec, wave: [Float](repeating: 0, count: 8 * Demucs.segment))
    }
}

private struct Collect: StemSink {
    var channels: [[Float]] = [[], [], [], []]
    var blocks = 0
    mutating func write(drums: [[Float]], noDrums: [[Float]]) async throws {
        channels[0] += drums[0]; channels[1] += drums[1]
        channels[2] += noDrums[0]; channels[3] += noDrums[1]
        blocks += 1
    }
}

private struct Sampled: Decodable { let idx: [Int]; let val: [Double]; let sum: Double; let sumSq: Double }
private struct RunFixture: Decodable { let n: Int; let blocks: Int; let channels: [Sampled] }
private struct Fixture: Decodable { let spectrogram: Sampled; let single: RunFixture; let multi: RunFixture }

private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "separation", withExtension: "json", subdirectory: "Fixtures/separation"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

private func assertMatches(_ got: [Float], _ want: Sampled, tol: Double, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    var worst = 0.0
    let scale = max(1e-6, want.val.map(abs).max() ?? 1)
    for (i, v) in zip(want.idx, want.val) { worst = max(worst, abs(Double(got[i]) - v) / scale) }
    XCTAssertLessThan(worst, tol, "\(label): worst sampled relative error \(worst)", file: file, line: line)
    let sum = got.reduce(0.0) { $0 + Double($1) }, sumSq = got.reduce(0.0) { $0 + Double($1) * Double($1) }
    XCTAssertEqual(sumSq, want.sumSq, accuracy: max(1e-6, abs(want.sumSq) * tol), "\(label): energy", file: file, line: line)
    XCTAssertEqual(sum, want.sum, accuracy: max(1e-3, abs(want.sumSq).squareRoot() * tol * 10), "\(label): sum", file: file, line: line)
}

final class SeparationTests: XCTestCase {
    func testFFTRoundTrip() {
        let fft = FFT(4096)
        var re = (0..<4096).map { _ in Double.random(in: -0.5...0.5) }, im = [Double](repeating: 0, count: 4096)
        let orig = re
        fft.transform(&re, &im)
        fft.transform(&re, &im, inverse: true)
        for i in 0..<4096 { XCTAssertEqual(re[i] / 4096, orig[i], accuracy: 1e-12) }
    }

    func testConstants() {
        XCTAssertEqual(Demucs.frames, 336)
        XCTAssertEqual(Demucs.bins, 2048)
        XCTAssertEqual(Demucs.stride, 257_985)
    }

    func testSpectrogramMatchesTypeScript() throws {
        let f = try fixture()
        let s = signal(Demucs.segment)
        assertMatches(Demucs.spectrogram(left: s[0], right: s[1]), f.spectrogram, tol: 1e-5, "spectrogram")
    }

    func testSingleChunkMatchesTypeScript() async throws {
        let f = try fixture().single
        var sink = Collect()
        try await Demucs.separate(input: signal(f.n), runner: FakeRunner(), sink: &sink)
        XCTAssertEqual(sink.blocks, f.blocks)
        for k in 0..<4 {
            XCTAssertEqual(sink.channels[k].count, f.n)
            assertMatches(sink.channels[k], f.channels[k], tol: 1e-4, "single ch\(k)")
        }
    }

    func testMultiChunkMatchesTypeScript() async throws {
        let f = try fixture().multi
        var sink = Collect()
        try await Demucs.separate(input: signal(f.n), runner: FakeRunner(), sink: &sink)
        XCTAssertEqual(sink.blocks, f.blocks)
        for k in 0..<4 {
            XCTAssertEqual(sink.channels[k].count, f.n)
            assertMatches(sink.channels[k], f.channels[k], tol: 1e-4, "multi ch\(k)")
        }
    }

    func testIdentityRunnerReconstructsInput() async throws {
        let n = Int(Double(Demucs.segment) * 2.3)
        let input = signal(n)
        var sink = Collect()
        try await Demucs.separate(input: input, runner: IdentityDrumsRunner(), sink: &sink)
        // demucs drops the first STFT frames (the time branch covers them in the
        // real model) and that edge leaks in at a tiny cross-fade weight where
        // later chunks start — same bounds as the TypeScript test.
        for ch in 0..<2 {
            var worst: Float = 0
            for i in 2048..<n { worst = max(worst, abs(sink.channels[ch][i] - input[ch][i])) }
            XCTAssertLessThan(worst, 5e-3)
        }
    }

    func testCrashModesStepDown() {
        let crumb = SeparationBreadcrumb(mode: .coreml, stage: .run, chunk: 3, total: 31)
        let once = SeparationModeState(mode: .coreml, inProgress: crumb).recoveringFromCrash()
        XCTAssertEqual(once.state.mode, .cpu)
        XCTAssertNil(once.state.inProgress)
        XCTAssertEqual(once.state.lastCrash?.chunk, 3)
        var c2 = crumb; c2.mode = .cpu
        XCTAssertEqual(SeparationModeState(mode: .cpu, inProgress: c2).recoveringFromCrash().state.mode, .cpuSlow)
        var c3 = crumb; c3.mode = .cpuSlow
        XCTAssertEqual(SeparationModeState(mode: .cpuSlow, inProgress: c3).recoveringFromCrash().state.mode, .cpuSlow)
        XCTAssertEqual(SeparationModeState(mode: .cpu, inProgress: crumb).recoveringFromCrash().state.mode, .cpuSlow)
        XCTAssertNil(SeparationModeState().recoveringFromCrash().crashed)
        let msg = separationCrashMessage(crumb, next: .cpu)
        XCTAssertTrue(msg.contains("chunk 3 of 31") && msg.contains("CPU"), msg)
        XCTAssertFalse(SeparationMode.cpu.sessionConfig.cpuMemArena)
        XCTAssertEqual(SeparationMode.cpuSlow.sessionConfig.intraOpThreads, 1)
    }

    func testFloatWavWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumber-wav-\(UUID()).wav")
        let w = try FloatWavWriter(url: url, sampleRate: 44100, channels: 2)
        try w.write([[0.5, -0.5], [0.25, 1]])
        try w.finish()
        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.count, 44 + 16)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
        let u16 = { (o: Int) in UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
        let u32 = { (o: Int) in UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        XCTAssertEqual(u16(20), 3)
        XCTAssertEqual(u32(40), 16)
        let floats = (0..<4).map { Float(bitPattern: u32(44 + 4 * $0)) }
        XCTAssertEqual(floats, [0.5, 0.25, -0.5, 1])
        try? FileManager.default.removeItem(at: url)
    }
}
