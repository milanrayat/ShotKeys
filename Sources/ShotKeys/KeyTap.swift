import CoreGraphics
import Foundation

/// Listen-only, system-wide key-down tap. It reads only the key code, the modifier flags and the
/// auto-repeat flag; it never reads the typed character and never stores anything.
final class KeyTap {
    typealias Handler = (_ sound: Sound, _ isRepeat: Bool, _ timestamp: CGEventTimestamp) -> Void

    private let handler: Handler
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// The active sound pack. Main thread only (the tap callback runs on the main run loop).
    var pack: SoundPack = .shotgun

    /// Number of key-down events seen this session (debug counter). Main thread only.
    private(set) var keyDownCount = 0
    /// Number of times macOS disabled the tap and we turned it back on.
    private(set) var reenableCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isInstalled: Bool { port != nil }
    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Installs the tap on the main run loop. Returns false if macOS refused (no Input Monitoring access).
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
    }

    /// Turns the tap back on if macOS disabled it. Called from the callback and from a watchdog timer.
    func reenableIfNeeded() {
        guard let port, !CGEvent.tapIsEnabled(tap: port) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        reenableCount += 1
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenableIfNeeded()
        case .keyDown:
            keyDownCount += 1
            guard !KeyMap.isShortcut(event.flags) else { return }
            guard let sound = KeyMap.sound(for: event.getIntegerValueField(.keyboardEventKeycode), pack: pack)
            else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            handler(sound, isRepeat, event.timestamp)
        default:
            break
        }
    }
}

private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    // Listen-only: the return value is ignored and the keystroke is never modified or delayed.
    return Unmanaged.passUnretained(event)
}
