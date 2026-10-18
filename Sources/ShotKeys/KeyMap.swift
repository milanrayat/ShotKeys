import CoreGraphics

/// A set of sounds the whole keyboard switches between, chosen in the menu.
enum SoundPack: String, CaseIterable, Identifiable {
    case shotgun
    case piano

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shotgun: return "Shotgun"
        case .piano: return "Piano"
        }
    }

    /// Menu bar icon while enabled.
    var symbol: String {
        switch self {
        case .shotgun: return "burst.fill"
        case .piano: return "pianokeys"
        }
    }

    /// Buttons in the menu's Test row.
    var testSounds: [(label: String, sound: Sound)] {
        switch self {
        case .shotgun:
            return [("Shot", .shot), ("Space", .pumpRack), ("Reload", .reload), ("Back", .shellEject)]
        case .piano:
            return [("C3", .piano("C3")), ("C4", .piano("C4")), ("C6", .piano("C6")), ("Chord", .pianoChord)]
        }
    }
}

/// One playable sound: a bank of samples in Resources/Sounds plus how to play it.
struct Sound: Hashable {
    /// File stem without the variant number: "shot" plays shot_1.wav … shot_5.wav, "piano_C4" plays piano_C4.wav.
    let bank: String
    /// Per-sound gain, applied on top of the master volume.
    var gain: Float = 1
    /// An exclusive sound cuts off every voice still ringing, and all key presses stay silent until it ends.
    var isExclusive = false
    /// Random pitch variation. Off for notes so they stay in tune.
    var variesPitch = true

    // Shotgun pack
    static let shot = Sound(bank: "shot", gain: 0.75)
    static let pumpRack = Sound(bank: "space", gain: 0.8)
    static let reload = Sound(bank: "reload", gain: 1.0, isExclusive: true)
    static let shellEject = Sound(bank: "backspace", gain: 0.7)

    // Piano pack
    static func piano(_ note: String) -> Sound { Sound(bank: "piano_" + note, gain: 0.8, variesPitch: false) }
    static let pianoBass = Sound(bank: "piano_bass", gain: 0.55, variesPitch: false)
    static let pianoChord = Sound(bank: "piano_chord", gain: 0.8, variesPitch: false)
}

/// Maps macOS virtual key codes (kVK_* in Carbon's Events.h) to sounds, per pack. Key codes are physical
/// key positions, so the piano layout follows the keyboard rows whatever the input language.
enum KeyMap {
    // MARK: Shotgun: any key not listed plays a shot

    private static let shotgunOverrides: [Int64: Sound?] = [
        0x31: .pumpRack,    // Space
        0x24: .reload,      // Return
        0x4C: .reload,      // Keypad Enter
        0x33: .shellEject,  // Delete (backspace)
        0x75: .shellEject,  // Forward Delete
    ].merging(silentKeys.map { ($0, nil) }) { $1 }

    // MARK: Piano: letters are white keys, bottom row lowest; everything not listed is silent

    private static let pianoKeys: [Int64: Sound] = {
        let rows: [[(Int64, String)]] = [
            // Z X C V B N M
            [(0x06, "C3"), (0x07, "D3"), (0x08, "E3"), (0x09, "F3"), (0x0B, "G3"), (0x2D, "A3"), (0x2E, "B3")],
            // A S D F G H J K L
            [(0x00, "C4"), (0x01, "D4"), (0x02, "E4"), (0x03, "F4"), (0x05, "G4"), (0x04, "A4"), (0x26, "B4"),
             (0x28, "C5"), (0x25, "D5")],
            // Q W E R T Y U I O P
            [(0x0C, "E5"), (0x0D, "F5"), (0x0E, "G5"), (0x0F, "A5"), (0x11, "B5"), (0x10, "C6"), (0x20, "D6"),
             (0x22, "E6"), (0x1F, "F6"), (0x23, "G6")],
        ]
        var map = Dictionary(uniqueKeysWithValues: rows.joined().map { ($0.0, Sound.piano($0.1)) })
        map[0x31] = .pianoBass    // Space
        map[0x24] = .pianoChord   // Return
        map[0x4C] = .pianoChord   // Keypad Enter
        return map
    }()

    /// Modifiers, arrows, navigation, Escape, F-keys, volume and JIS mode keys: silent in every pack.
    /// Modifiers normally arrive as flagsChanged, not keyDown, but stay silent regardless.
    private static let silentKeys: [Int64] = [
        0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x3F, 0x39,   // Cmd, Shift, Option, Control (L/R), Fn, Caps Lock
        0x7B, 0x7C, 0x7D, 0x7E,                                       // Arrows
        0x73, 0x77, 0x74, 0x79, 0x72, 0x35, 0x6E,                     // Home, End, Page Up/Down, Help, Escape, Menu
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,   // F1–F10
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,   // F11–F20
        0x48, 0x49, 0x4A, 0x66, 0x68,                                 // Volume up/down/mute, Eisu, Kana
    ]

    private static let tables: [SoundPack: [Sound?]] = [
        .shotgun: (0..<128).map { code in shotgunOverrides[Int64(code)] ?? .shot },
        .piano: (0..<128).map { code in pianoKeys[Int64(code)] },
    ]

    /// The sound for a key in the given pack, or nil when the key is silent.
    static func sound(for keyCode: Int64, pack: SoundPack) -> Sound? {
        guard keyCode >= 0, keyCode < 128 else { return nil }
        return tables[pack]![Int(keyCode)]
    }

    /// Every sound any key can play, used by the self-test to check all samples are present.
    static var allSounds: Set<Sound> {
        Set(tables.values.joined().compactMap { $0 })
    }

    /// Keyboard shortcuts (Cmd or Ctrl held) are silent. Shift and Option still type characters, so they play.
    static func isShortcut(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) || flags.contains(.maskControl)
    }
}
