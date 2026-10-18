import AppKit
import Combine
import CoreGraphics

/// Settings, permission state and wiring between the key tap and the audio engine. Main thread only.
final class AppState: ObservableObject {
    static let shared = AppState()

    private enum Key {
        static let enabled = "enabled"
        static let volume = "volume"
        static let pitchVariation = "pitchVariation"
        static let playOnRepeat = "playOnRepeat"
        static let soundPack = "soundPack"
    }

    static let maxPitchVariation = 0.12

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled); engine.setEnabled(enabled) }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Key.volume); engine.setVolume(Float(volume)) }
    }
    @Published var pitchVariation: Double {
        didSet { defaults.set(pitchVariation, forKey: Key.pitchVariation); engine.setPitchVariation(Float(pitchVariation)) }
    }
    @Published var playOnRepeat: Bool {
        didSet { defaults.set(playOnRepeat, forKey: Key.playOnRepeat); engine.setPlayOnRepeat(playOnRepeat) }
    }
    @Published var soundPack: SoundPack {
        didSet { defaults.set(soundPack.rawValue, forKey: Key.soundPack); tap.pack = soundPack }
    }
    @Published private(set) var hasPermission = false

    let engine = ShotEngine()
    private(set) lazy var tap: KeyTap = {
        let tap = KeyTap { [engine] sound, isRepeat, timestamp in
            engine.trigger(sound, isRepeat: isRepeat, eventTimestamp: timestamp)
        }
        tap.pack = soundPack
        return tap
    }()

    private let defaults = UserDefaults.standard
    private var watchdog: Timer?

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.volume: 0.7,
            Key.pitchVariation: 0.06,
            Key.playOnRepeat: false,
            Key.soundPack: SoundPack.shotgun.rawValue,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        volume = defaults.double(forKey: Key.volume)
        pitchVariation = min(max(defaults.double(forKey: Key.pitchVariation), 0), Self.maxPitchVariation)
        playOnRepeat = defaults.bool(forKey: Key.playOnRepeat)
        soundPack = SoundPack(rawValue: defaults.string(forKey: Key.soundPack) ?? "") ?? .shotgun
    }

    var menuBarSymbol: String {
        if !hasPermission { return "exclamationmark.triangle" }
        return enabled ? soundPack.symbol : "speaker.slash"
    }

    func start() {
        engine.start(enabled: enabled, volume: Float(volume),
                     pitchVariation: Float(pitchVariation), playOnRepeat: playOnRepeat)
        refreshPermission()
        if !hasPermission { showPermissionIntro() }
        scheduleWatchdog()
    }

    // MARK: Permission

    /// Starts the tap as soon as Input Monitoring is granted (no restart), and stops it if access is revoked.
    func refreshPermission() {
        let granted = CGPreflightListenEventAccess()
        if granted {
            if !tap.isInstalled { tap.start() }
            tap.reenableIfNeeded()
        } else if tap.isInstalled {
            tap.stop()
        }
        let ready = granted && tap.isInstalled
        if ready != hasPermission {
            hasPermission = ready
            scheduleWatchdog()
        }
    }

    /// Poll every second while waiting for access, then every 5 s as a tap watchdog.
    private func scheduleWatchdog() {
        watchdog?.invalidate()
        let interval: TimeInterval = hasPermission ? 5 : 1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refreshPermission() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func openInputMonitoringSettings() {
        // Adds ShotKeys to the Input Monitoring list (and shows the system prompt the first time).
        CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showPermissionIntro() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ShotKeys needs Input Monitoring access"
        alert.informativeText = """
        macOS only lets an app hear key presses in other apps if you allow it under \
        Privacy & Security › Input Monitoring.

        ShotKeys only looks at which key was pressed, to pick a sound. It never reads, saves or sends what you type.

        Click “Open System Settings”, switch on ShotKeys, and sound starts right away. No restart needed.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openInputMonitoringSettings()
        }
    }
}
