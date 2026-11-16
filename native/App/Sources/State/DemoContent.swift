// Demo library for screenshots and UI tests: launch with `-LumberDemo` and an
// empty library gets two generated songs (a groove and a quieter one) and a
// take with a project, so Library, Record and Edit all have something real
// to show. Audio is synthesised here; nothing is bundled.

import Foundation

enum DemoContent {
    static let songId = "file:demo-groove"
    static let launchArgument = "-LumberDemo"

    /// 16-bit mono PCM WAV of `render(t)` (clipped to ±1).
    static func writeWav(to url: URL, seconds: Double, sampleRate: Int, _ render: (Double) -> Double) throws {
        let frames = Int(seconds * Double(sampleRate))
        var d = Data(capacity: 44 + frames * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(frames * 2)
        for i in 0..<frames {
            let v = max(-1, min(1, render(Double(i) / Double(sampleRate))))
            withUnsafeBytes(of: Int16(v * 32_000).littleEndian) { d.append(contentsOf: $0) }
        }
        try d.write(to: url, options: [.atomic])
    }

    /// Kick on 1 and 3, snare on 2 and 4, hats on 8ths, 120 bpm.
    static func drums(_ t: Double, seed: Double = 0) -> Double {
        let beat = t.truncatingRemainder(dividingBy: 0.5)
        let n = Int(t / 0.5)
        let eighth = t.truncatingRemainder(dividingBy: 0.25)
        let kick = n % 2 == 0 ? sin(2 * .pi * (50 + 80 * exp(-beat * 30)) * beat) * exp(-beat * 12) * 0.8 : 0
        let noise = sin(t * 91_731.7 + seed) * sin(t * 37_119.3)
        let snare = n % 2 == 1 ? noise * exp(-beat * 22) * 0.55 : 0
        let hat = sin(t * 123_457.1 + seed * 3) * exp(-eighth * 90) * 0.18
        return kick + snare + hat
    }

    static func band(_ t: Double) -> Double {
        let notes = [55.0, 55, 73.4, 65.4]
        let f = notes[Int(t / 0.5) % notes.count]
        return 0.3 * sin(2 * .pi * f * t)
            + 0.06 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t))
    }
}

extension AppModel {
    /// Fills an empty library with the demo songs and one take (`-LumberDemo`).
    func seedDemoIfEmpty() throws {
        guard songs.isEmpty else { return }
        let song = files.dir(.songs).appendingPathComponent("demo-groove.wav")
        try DemoContent.writeWav(to: song, seconds: 40, sampleRate: 44_100) {
            0.6 * DemoContent.drums($0) + DemoContent.band($0)
        }
        let quiet = files.dir(.songs).appendingPathComponent("demo-ballad.wav")
        try DemoContent.writeWav(to: quiet, seconds: 30, sampleRate: 44_100) { 0.8 * DemoContent.band($0 * 0.5) }
        addSong(ImportedSong(id: "file:demo-ballad", title: "Slow one", artist: "Demo", durationSec: 30,
                             artworkUrl: nil, source: .file, fileURL: quiet))
        addSong(ImportedSong(id: DemoContent.songId, title: "Demo groove", artist: "Lumber", durationSec: 40,
                             artworkUrl: nil, source: .file, fileURL: song))

        let takeURL = files.dir(.takes).appendingPathComponent("take-demo.wav")
        try DemoContent.writeWav(to: takeURL, seconds: 16, sampleRate: 48_000) {
            0.5 * DemoContent.drums($0 + 0.02, seed: 1.3) // a little early, as played
        }
        addTake(Take(
            id: "demo-take", songId: DemoContent.songId, drumsUri: files.reference(for: takeURL),
            songStartSec: 8, drumOffsetSec: 8, latencyMs: 14, sampleRate: 48_000, createdAt: nowMs(), video: nil
        ))
    }
}
