import CoreGraphics

/// The sound a key plays. Tweak the tables below to change which keys sound like what.
enum SoundGroup: String, CaseIterable {
    case shot        // letters, numbers, punctuation
    case space       // pump-action rack
    case reload      // Enter: shells in + pump rack; silences everything else while it plays
    case backspace   // dry click / shell eject
    case silent

    /// Sample file prefix in Resources/Sounds (e.g. "shot_1.wav", "shot_2.wav").
    var filePrefix: String { rawValue }

    /// An exclusive sound cuts off every voice still ringing, and all key presses stay silent until it ends.
    var isExclusive: Bool { self == .reload }

    /// Per-group playback gain, applied on top of the master volume.
    var gain: Float {
        switch self {
        case .shot: return 0.75
        case .space: return 0.8
        case .reload: return 1.0
        case .backspace: return 0.7
        case .silent: return 0
        }
    }
}

/// Maps macOS virtual key codes (kVK_* in Carbon's Events.h) to sound groups.
/// Any key not listed here plays `.shot`.
enum KeyMap {
    private static let overrides: [Int64: SoundGroup] = [
        0x31: .space,       // Space
        0x24: .reload,      // Return
        0x4C: .reload,      // Keypad Enter
        0x33: .backspace,   // Delete (backspace)
        0x75: .backspace,   // Forward Delete

        // Modifiers. These normally arrive as flagsChanged, not keyDown, but stay silent regardless.
        0x37: .silent, 0x36: .silent,   // Command L/R
        0x38: .silent, 0x3C: .silent,   // Shift L/R
        0x3A: .silent, 0x3D: .silent,   // Option L/R
        0x3B: .silent, 0x3E: .silent,   // Control L/R
        0x3F: .silent,                  // Fn
        0x39: .silent,                  // Caps Lock

        // Arrows and navigation
        0x7B: .silent, 0x7C: .silent, 0x7D: .silent, 0x7E: .silent,
        0x73: .silent, 0x77: .silent, 0x74: .silent, 0x79: .silent,   // Home, End, Page Up, Page Down
        0x72: .silent,                                                // Help / Insert
        0x35: .silent,                                                // Escape
        0x6E: .silent,                                                // Context menu

        // Function keys F1-F20
        0x7A: .silent, 0x78: .silent, 0x63: .silent, 0x76: .silent,
        0x60: .silent, 0x61: .silent, 0x62: .silent, 0x64: .silent,
        0x65: .silent, 0x6D: .silent, 0x67: .silent, 0x6F: .silent,
        0x69: .silent, 0x6B: .silent, 0x71: .silent, 0x6A: .silent,
        0x40: .silent, 0x4F: .silent, 0x50: .silent, 0x5A: .silent,

        // Volume keys on keyboards that send them as keyDown, JIS Eisu/Kana
        0x48: .silent, 0x49: .silent, 0x4A: .silent,
        0x66: .silent, 0x68: .silent,
    ]

    private static let table: [SoundGroup] = (0..<128).map { overrides[Int64($0)] ?? .shot }

    static func group(for keyCode: Int64) -> SoundGroup {
        guard keyCode >= 0, keyCode < 128 else { return .silent }
        return table[Int(keyCode)]
    }

    /// Keyboard shortcuts (Cmd or Ctrl held) are silent. Shift and Option still type characters, so they play.
    static func isShortcut(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) || flags.contains(.maskControl)
    }
}
