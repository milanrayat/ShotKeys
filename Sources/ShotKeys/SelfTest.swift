import AppKit
import Foundation

/// `ShotKeys --selftest`: plays a burst of shots through the real engine (no key tap or permission
/// needed), prints scheduling latency and loaded samples, then quits. Used to verify the audio path.
enum SelfTest {
    static func run(engine: ShotEngine) {
        engine.idleTimeout = 1
        engine.start(enabled: true, volume: 0.5, pitchVariation: 0.06, playOnRepeat: false)
        print("Loaded samples:", engine.loadedSampleCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))

        let sequence: [SoundGroup] = Array(repeating: .shot, count: 20) + [.space, .shot, .shot, .backspace, .reload]
        DispatchQueue.global(qos: .userInitiated).async {
            for group in sequence {
                engine.trigger(group, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
                Thread.sleep(forTimeInterval: group == .shot ? 0.1 : group == .reload ? 1.1 : 0.4)   // 10 keys/sec
            }
            // Reload while shots ring: keys typed during the reload must be silent.
            for _ in 0..<3 {
                engine.trigger(.shot, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
                Thread.sleep(forTimeInterval: 0.05)
            }
            engine.trigger(.reload, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
            for group in [SoundGroup.shot, .shot, .space, .reload, .shot] {
                Thread.sleep(forTimeInterval: 0.12)
                engine.trigger(group, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
            }
            Thread.sleep(forTimeInterval: 1.0)
            print("Keys muted by reload (expect 5):", engine.stats.snapshot().suppressedByReload)
            engine.trigger(.shot, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)

            Thread.sleep(forTimeInterval: 2.5)
            print("Engine running after 2.5 s idle:", engine.stats.snapshot().engineRunning)
            engine.trigger(.shot, isRepeat: false, eventTimestamp: DispatchTime.now().uptimeNanoseconds)
            Thread.sleep(forTimeInterval: 0.8)
            let s = engine.stats.snapshot()
            print(String(format: "Resume from idle: %.1f ms (resumes: %d)", s.lastResumeMs ?? -1, s.resumes))
            print(String(format: "Shots: %d  stolen voices: %d  software p50: %.2f ms  p95: %.2f ms  output: %.1f ms (%d frames @ %.0f Hz)",
                         s.shots, s.stolenVoices, s.softwareP50Ms ?? -1, s.softwareP95Ms ?? -1,
                         s.outputLatencyMs, s.bufferFrames, s.sampleRate))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
