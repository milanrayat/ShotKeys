import AppKit
import Foundation

/// `ShotKeys --selftest`: plays both sound packs through the real engine (no key tap or permission
/// needed), checks the key maps and samples, prints latency, then quits. Used to verify the audio path.
enum SelfTest {
    static func run(engine: ShotEngine) {
        engine.idleTimeout = 1
        engine.start(enabled: true, volume: 0.5, pitchVariation: 0.06, playOnRepeat: false)

        let counts = engine.loadedSampleCounts
        print("Loaded banks: \(counts.count), samples: \(counts.values.reduce(0, +))")
        let missing = KeyMap.allSounds.map(\.bank).filter { counts[$0, default: 0] == 0 }.sorted()
        print("Sounds with no samples (expect none):", missing.isEmpty ? "none" : missing.joined(separator: " "))
        let checks: [(String, Int64, SoundPack, String?)] = [
            ("Z", 0x06, .piano, "piano_C3"), ("A", 0x00, .piano, "piano_C4"), ("L", 0x25, .piano, "piano_D5"),
            ("Q", 0x0C, .piano, "piano_E5"), ("P", 0x23, .piano, "piano_G6"), ("Space", 0x31, .piano, "piano_bass"),
            ("Return", 0x24, .piano, "piano_chord"), ("1", 0x12, .piano, nil), ("Delete", 0x33, .piano, nil),
            ("A", 0x00, .shotgun, "shot"), ("Return", 0x24, .shotgun, "reload"), ("Shift", 0x38, .shotgun, nil),
        ]
        let wrong = checks.filter { KeyMap.sound(for: $0.1, pack: $0.2)?.bank != $0.3 }
        print("Key map mismatches (expect none):", wrong.isEmpty ? "none" : wrong.map { "\($0.2.rawValue)/\($0.0)" }.joined(separator: " "))

        func play(_ sound: Sound) {
            engine.trigger(sound, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Shotgun at 10 keys/sec
            let sequence: [Sound] = Array(repeating: .shot, count: 20) + [.pumpRack, .shot, .shot, .shellEject, .reload]
            for sound in sequence {
                play(sound)
                Thread.sleep(forTimeInterval: sound == .shot ? 0.1 : sound == .reload ? 1.1 : 0.4)
            }
            // Reload while shots ring: keys typed during the reload must be silent.
            for _ in 0..<3 {
                play(.shot)
                Thread.sleep(forTimeInterval: 0.05)
            }
            play(.reload)
            for sound in [Sound.shot, .shot, .pumpRack, .reload, .shot] {
                Thread.sleep(forTimeInterval: 0.12)
                play(sound)
            }
            Thread.sleep(forTimeInterval: 1.0)
            print("Keys muted by reload (expect 5):", engine.stats.snapshot().suppressedByReload)

            // Piano: home row A–L as a scale, then Space (bass) and Return (chord)
            let homeRow: [Int64] = [0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25]
            for code in homeRow {
                if let sound = KeyMap.sound(for: code, pack: .piano) { play(sound) }
                Thread.sleep(forTimeInterval: 0.15)
            }
            play(.pianoBass)
            Thread.sleep(forTimeInterval: 0.3)
            play(.pianoChord)
            Thread.sleep(forTimeInterval: 1.6)

            Thread.sleep(forTimeInterval: 1.5)
            print("Engine running after idle:", engine.stats.snapshot().engineRunning)
            play(.shot)
            Thread.sleep(forTimeInterval: 0.8)
            let s = engine.stats.snapshot()
            print(String(format: "Resume from idle: %.1f ms (resumes: %d)", s.lastResumeMs ?? -1, s.resumes))
            print(String(format: "Sounds: %d  stolen voices: %d  software p50: %.2f ms  p95: %.2f ms  output: %.1f ms (%d frames @ %.0f Hz)",
                         s.shots, s.stolenVoices, s.softwareP50Ms ?? -1, s.softwareP95Ms ?? -1,
                         s.outputLatencyMs, s.bufferFrames, s.sampleRate))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
