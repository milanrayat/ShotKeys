import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

/// Low-latency sample player: preloaded buffers, a round-robin pool of voices (player + varispeed),
/// a peak limiter and a master gain. All engine state is confined to `queue`.
final class ShotEngine {
    static let voiceCount = 16
    static let ioBufferFrames: UInt32 = 256

    /// Dedicated high-priority queue. The key tap hands work to it and returns immediately.
    let queue = DispatchQueue(label: "com.milanrayat.ShotKeys.audio", qos: .userInteractive)
    let stats = LatencyStats()

    private struct Voice {
        let player: AVAudioPlayerNode
        let varispeed: AVAudioUnitVarispeed
        var busyUntil: UInt64 = 0   // uptime nanoseconds
    }

    private let engine = AVAudioEngine()
    private let voiceMixer = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0))
    /// All samples are converted to this format at load time, so any WAV/AIFF/CAF works.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// Voice mix and limiter run in stereo at 48 kHz; the main mixer resamples to the device.
    private let busFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private var voices: [Voice] = []
    /// A few frames of silence, scheduled with .interrupts to cut a voice off without stopping its player.
    private lazy var silence: AVAudioPCMBuffer = {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 64
        return buffer
    }()
    private var nextVoice = 0
    /// Samples by bank name (file stem without the variant number), e.g. "shot" or "piano_C4".
    private var banks: [String: [AVAudioPCMBuffer]] = [:]
    private var lastVariant: [String: Int] = [:]
    private var configObserver: NSObjectProtocol?

    /// Pause the engine after this long without a shot, so idle CPU is zero. The next key press resumes it.
    var idleTimeout: TimeInterval = 15
    /// When the most recent sound finishes playing (uptime nanoseconds). The idle timeout counts from here.
    private var lastSoundEndsAt: UInt64 = 0
    /// While an exclusive sound (reload) is playing, every key press is silent. Uptime nanoseconds.
    private var exclusiveUntil: UInt64 = 0
    private var idleCheckPending = false

    private var enabled = true
    private var playOnRepeat = false
    private var pitchVariation: Float = 0.06
    private var volume: Float = 0.7

    // MARK: Setup

    /// Loads samples, builds the graph and starts the engine. Blocks until done (a few ms).
    func start(enabled: Bool, volume: Float, pitchVariation: Float, playOnRepeat: Bool) {
        queue.sync {
            self.enabled = enabled
            self.volume = volume
            self.pitchVariation = pitchVariation
            self.playOnRepeat = playOnRepeat
            loadSamples()
            buildGraph()
            if enabled { startEngine() }
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
    }

    var loadedSampleCounts: [String: Int] {
        queue.sync { banks.mapValues(\.count) }
    }

    private func loadSamples() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else {
            NSLog("ShotKeys: no Sounds folder in app bundle")
            return
        }
        let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a"]
        let sorted = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sorted {
            guard let buffer = Self.loadBuffer(url: url, format: format) else { continue }
            banks[Self.bankName(for: url), default: []].append(buffer)
        }
    }

    private func buildGraph() {
        engine.attach(voiceMixer)
        engine.attach(limiter)
        for bus in 0..<Self.voiceCount {
            let voice = Voice(player: AVAudioPlayerNode(), varispeed: AVAudioUnitVarispeed())
            engine.attach(voice.player)
            engine.attach(voice.varispeed)
            engine.connect(voice.player, to: voice.varispeed, format: format)
            engine.connect(voice.varispeed, to: voiceMixer, fromBus: 0, toBus: bus, format: format)
            voices.append(voice)
        }
        engine.connect(voiceMixer, to: limiter, format: busFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: busFormat)
        connectOutput()
        engine.mainMixerNode.outputVolume = volume

        // Peak limiter keeps 10+ overlapping shots from clipping.
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.06, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    }

    /// (Re)connects main mixer → output at the current device's sample rate.
    private func connectOutput() {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 48_000
        let channels = min(max(hw.channelCount, 1), 2)
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outFormat)
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        setIOBufferSize(Self.ioBufferFrames)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("ShotKeys: audio engine failed to start: \(error.localizedDescription)")
            return
        }
        for i in voices.indices {
            voices[i].player.play()
            voices[i].busyUntil = 0
        }
        exclusiveUntil = 0
        updateOutputLatency()
        stats.setEngineRunning(true)
        lastSoundEndsAt = DispatchTime.now().uptimeNanoseconds
        scheduleIdleCheck(after: idleTimeout)
    }

    private func pauseEngine() {
        guard engine.isRunning else { return }
        engine.pause()
        stats.setEngineRunning(false)
    }

    private func scheduleIdleCheck(after delay: TimeInterval) {
        guard !idleCheckPending else { return }
        idleCheckPending = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.idleCheckPending = false
            guard self.engine.isRunning else { return }
            let idleFor = (Double(DispatchTime.now().uptimeNanoseconds) - Double(self.lastSoundEndsAt)) / 1e9
            if idleFor >= self.idleTimeout {
                self.pauseEngine()
            } else {
                self.scheduleIdleCheck(after: self.idleTimeout - idleFor)
            }
        }
    }

    /// Small device buffer (~5 ms at 48 kHz) for low latency. Bluetooth devices may ignore this.
    private func setIOBufferSize(_ frames: UInt32) {
        guard let au = engine.outputNode.audioUnit else { return }
        var value = frames
        AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &value, UInt32(MemoryLayout<UInt32>.size))
    }

    private func updateOutputLatency() {
        let output = engine.outputNode
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if let au = output.audioUnit {
            AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        }
        let rate = output.outputFormat(forBus: 0).sampleRate
        let bufferSeconds = rate > 0 ? Double(frames) / rate : 0
        stats.setOutputLatency(seconds: output.presentationLatency + bufferSeconds,
                               bufferFrames: Int(frames), sampleRate: rate)
    }

    /// Output device changed (headphones, Bluetooth, display speakers). The engine has stopped itself;
    /// rewire to the new device's format and restart.
    private func handleConfigurationChange() {
        NSLog("ShotKeys: audio configuration changed, restarting engine")
        engine.stop()
        stats.setEngineRunning(false)
        connectOutput()
        if enabled { startEngine() }
    }

    // MARK: Settings (thread-safe; applied on the audio queue)

    func setEnabled(_ value: Bool) {
        queue.async {
            self.enabled = value
            if value {
                self.startEngine()
            } else {
                // Pausing keeps everything loaded but stops the audio thread, so idle CPU is zero.
                self.pauseEngine()
            }
        }
    }

    func setVolume(_ value: Float) {
        queue.async {
            self.volume = value
            self.engine.mainMixerNode.outputVolume = value
        }
    }

    func setPitchVariation(_ value: Float) {
        queue.async { self.pitchVariation = value }
    }

    func setPlayOnRepeat(_ value: Bool) {
        queue.async { self.playOnRepeat = value }
    }

    // MARK: Playback

    /// Called from the key tap callback. Returns immediately; all work happens on `queue`.
    func trigger(_ sound: Sound, isRepeat: Bool, eventTimestamp: CGEventTimestamp) {
        queue.async { self.play(sound, isRepeat: isRepeat, eventTimestamp: eventTimestamp) }
    }

    private func play(_ sound: Sound, isRepeat: Bool, eventTimestamp: CGEventTimestamp) {
        guard enabled else { return }
        if isRepeat && !playOnRepeat { return }
        if DispatchTime.now().uptimeNanoseconds < exclusiveUntil {
            stats.recordSuppressed()
            return
        }
        guard let bank = banks[sound.bank], !bank.isEmpty else { return }
        if !engine.isRunning {
            // Woke from idle pause (or a device change left it stopped).
            let start = DispatchTime.now().uptimeNanoseconds
            startEngine()
            guard engine.isRunning else { return }
            stats.recordResume(ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        let buffer = bank[pickVariant(sound.bank, count: bank.count)]
        let rate = sound.variesPitch && pitchVariation > 0 ? 1 + Float.random(in: -pitchVariation...pitchVariation) : 1

        // Round-robin: the next voice is always the oldest, so if it is still busy we steal it.
        let index = nextVoice
        nextVoice = (nextVoice + 1) % voices.count
        let now = DispatchTime.now().uptimeNanoseconds
        if sound.isExclusive {
            // Only the reload should be heard: cut off every shot still ringing.
            for i in voices.indices where voices[i].busyUntil > now {
                voices[i].player.scheduleBuffer(silence, at: nil, options: [.interrupts], completionHandler: nil)
                voices[i].busyUntil = 0
            }
        }
        let voice = voices[index]
        let stealing = voice.busyUntil > now

        voice.varispeed.rate = rate
        voice.player.volume = sound.gain
        voice.player.scheduleBuffer(buffer, at: nil, options: stealing ? [.interrupts] : [], completionHandler: nil)
        if !voice.player.isPlaying { voice.player.play() }

        let seconds = Double(buffer.frameLength) / format.sampleRate / Double(rate)
        voices[index].busyUntil = now + UInt64(seconds * 1_000_000_000)
        if sound.isExclusive { exclusiveUntil = voices[index].busyUntil }
        lastSoundEndsAt = max(lastSoundEndsAt, voices[index].busyUntil)

        stats.recordShot(eventTimestamp: eventTimestamp, scheduledAt: DispatchTime.now().uptimeNanoseconds, stolen: stealing)
    }

    /// Random variant, never the same one twice in a row.
    private func pickVariant(_ bank: String, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var pick = Int.random(in: 0..<count)
        if pick == lastVariant[bank] {
            pick = (pick + Int.random(in: 1..<count)) % count
        }
        lastVariant[bank] = pick
        return pick
    }

    // MARK: Loading

    /// "shot_3.wav" → "shot", "piano_C4.wav" → "piano_C4": a trailing "_<number>" marks a variant.
    private static func bankName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let underscore = stem.lastIndex(of: "_") {
            let suffix = stem[stem.index(after: underscore)...]
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) { return String(stem[..<underscore]) }
        }
        return stem
    }

    private static func loadBuffer(url: URL, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: source)
            guard let converted = convert(source, to: format) else { return nil }
            return trimLeadingSilence(converted)
        } catch {
            NSLog("ShotKeys: could not load \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        converter.downmix = true
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }

    /// Leading silence is audible latency, so drop everything before the transient (−40 dBFS).
    private static func trimLeadingSilence(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData?[0] else { return buffer }
        let length = Int(buffer.frameLength)
        var first = 0
        while first < length && abs(data[first]) < 0.01 { first += 1 }
        let start = max(0, first - 16)
        guard start > 0, start < length,
              let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length - start))
        else { return buffer }
        trimmed.frameLength = AVAudioFrameCount(length - start)
        for channel in 0..<Int(buffer.format.channelCount) {
            trimmed.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + start, count: length - start)
        }
        return trimmed
    }
}

/// Rolling latency samples. Written on the audio queue, read by the menu on the main thread.
final class LatencyStats {
    struct Snapshot {
        var shots = 0
        var stolenVoices = 0
        var suppressedByReload = 0
        var softwareP50Ms: Double?
        var softwareP95Ms: Double?
        var outputLatencyMs: Double = 0
        var engineRunning = false
        var resumes = 0
        var lastResumeMs: Double?
        var bufferFrames = 0
        var sampleRate: Double = 0
    }

    private let lock = NSLock()
    private var samples: [Double] = []
    private var sampleIndex = 0
    private var snapshotValue = Snapshot()
    private static let capacity = 500

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func setEngineRunning(_ running: Bool) {
        lock.lock(); defer { lock.unlock() }
        snapshotValue.engineRunning = running
    }

    func recordSuppressed() {
        lock.lock(); defer { lock.unlock() }
        snapshotValue.suppressedByReload += 1
    }

    func recordResume(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        snapshotValue.resumes += 1
        snapshotValue.lastResumeMs = ms
    }

    func setOutputLatency(seconds: Double, bufferFrames: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        snapshotValue.outputLatencyMs = seconds * 1000
        snapshotValue.bufferFrames = bufferFrames
        snapshotValue.sampleRate = sampleRate
    }

    /// Time from the key event's timestamp to the buffer being scheduled. Event timestamps are
    /// uptime nanoseconds on current macOS; fall back to mach ticks if the value doesn't fit.
    func recordShot(eventTimestamp: CGEventTimestamp, scheduledAt now: UInt64, stolen: Bool) {
        var deltaMs: Double?
        if eventTimestamp > 0 {
            let asNs = Double(now) - Double(eventTimestamp)
            let asTicks = Double(now) - Double(eventTimestamp) * Double(Self.timebase.numer) / Double(Self.timebase.denom)
            if asNs >= 0 && asNs < 1e9 {
                deltaMs = asNs / 1e6
            } else if asTicks >= 0 && asTicks < 1e9 {
                deltaMs = asTicks / 1e6
            }
        }
        lock.lock(); defer { lock.unlock() }
        snapshotValue.shots += 1
        if stolen { snapshotValue.stolenVoices += 1 }
        guard let deltaMs else { return }
        if samples.count < Self.capacity {
            samples.append(deltaMs)
        } else {
            samples[sampleIndex] = deltaMs
            sampleIndex = (sampleIndex + 1) % Self.capacity
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        var result = snapshotValue
        let sorted = samples.sorted()
        lock.unlock()
        if !sorted.isEmpty {
            result.softwareP50Ms = sorted[sorted.count / 2]
            result.softwareP95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return result
    }
}
