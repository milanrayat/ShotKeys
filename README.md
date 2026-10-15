# ShotKeys

A macOS menu bar app that plays a shotgun sound on every key press. Letters fire a short blast,
Space racks the pump, Enter reloads the gun, and Backspace ejects a shell.

**Just want to use it?** Download `ShotKeys.zip` from the
[latest release](https://github.com/milanrayat/ShotKeys/releases/latest) and follow
[Sharing with a friend › On their Mac](#sharing-with-a-friend). No build needed.

Personal project: not sandboxed or notarized, and not on the App Store.

## Requirements

- macOS 13 Ventura or newer (Apple Silicon or Intel; the build is universal)
- Xcode **or** just the Command Line Tools (`xcode-select --install`). No Xcode project is needed.
- Python 3 (ships with the Command Line Tools), only used to regenerate the placeholder sounds

## Build and run

```bash
scripts/build.sh --run
```

This compiles arm64 + x86_64, assembles `build/ShotKeys.app`, signs it and launches it. Look for
the burst icon in the menu bar. There is no Dock icon and no window.

To keep it around, copy `build/ShotKeys.app` to `/Applications` and launch it from there.

### Stable code signing (do this once)

macOS ties the Input Monitoring permission to the app's code signature. With ad-hoc signing the
signature changes on every build, so macOS forgets the permission each time you rebuild.

`scripts/build.sh` picks a signing identity in this order:

1. `SHOTKEYS_SIGN_IDENTITY="…" scripts/build.sh`
2. any **Apple Development** certificate in your keychain (free with an Apple ID in Xcode › Settings › Accounts)
3. a self-signed **ShotKeys Local Signing** certificate
4. ad-hoc, with a warning

If you don't have Xcode, create the self-signed certificate once:

```bash
scripts/create_signing_cert.sh
```

It adds a code-signing certificate to your login keychain and asks for your password to trust it
for code signing. Rebuild, grant Input Monitoring one more time, and it sticks from then on.

## Sharing with a friend

Easiest: send the built app. They need macOS 13+ and nothing else (no Xcode, no build).

1. Package it: `ditto -c -k --sequesterRsrc --keepParent build/ShotKeys.app dist/ShotKeys.zip`
2. Send `dist/ShotKeys.zip` (AirDrop, Messages, Drive…). It's universal, so Intel Macs work too.

On their Mac:

1. Unzip, drag **ShotKeys.app** into **Applications**, double-click it.
2. macOS blocks it the first time because it isn't notarized. Open **System Settings ›
   Privacy & Security**, scroll down, click **Open Anyway** next to "ShotKeys", and confirm.
3. Click **Open System Settings** in the ShotKeys prompt and switch ShotKeys on under
   **Input Monitoring**. Sound starts right away.

Updates: rebuild, re-zip and send again. Because builds are signed with the same
"ShotKeys Local Signing" certificate, their Input Monitoring access carries over.
The certificate's private key stays in your keychain; it is never part of the zip.

Alternative for someone who wants the source: send the project folder (without `build/`,
`dist/` and `.build/`) and have them run `scripts/build.sh --run`. They need the Command Line
Tools (`xcode-select --install`) and should run `scripts/create_signing_cert.sh` once.

## First launch: Input Monitoring

macOS requires **Input Monitoring** access for any app that listens to keystrokes in other apps.
On first launch ShotKeys explains this and offers **Open System Settings**, which goes straight
to *Privacy & Security › Input Monitoring*. Switch ShotKeys on there. Sound starts within about
a second, with no restart. Until then the menu bar icon is a warning triangle and the menu shows
the same button.

If the permission gets stuck (for example after switching signing identities), reset it:

```bash
tccutil reset ListenEvent com.milanrayat.ShotKeys
```

## Menu

| Control | What it does |
|---|---|
| Enabled switch | Mutes or unmutes instantly. Off also stops the audio engine. |
| Volume | 0–100%, applied live |
| Pitch variation | 0 to ±12% random playback rate per shot (default ±6%) |
| Play on key repeat | Off by default: holding a key fires once. On: holding a key keeps firing. |
| Test buttons | Fire each sound group without typing |
| Diagnostics | Permission state, key-press counter, shots played, measured latency, engine state, Secure Input warning |
| Quit | ⌘Q while the menu is open |

Settings are stored in UserDefaults (`com.milanrayat.ShotKeys`) and survive relaunches.

## Behavior

- **Silent keys:** modifiers alone (Shift, Cmd, Ctrl, Option, Fn, Caps Lock), arrows, Home, End,
  Page Up/Down, Escape and F-keys.
- **Shortcuts are silent:** anything pressed with Cmd or Ctrl held (Cmd+C, Ctrl+A …).
  Shift and Option still play, since they type characters.
- **Reload is exclusive:** pressing Enter cuts off any shots still ringing, and every key
  (including Enter again) stays silent until the reload finishes, so you only hear the reload.
  The menu's Diagnostics counts how many keys were muted this way. Change which groups are
  exclusive with `isExclusive` in `KeyMap.swift`.
- **Key groups** are defined in [`Sources/ShotKeys/KeyMap.swift`](Sources/ShotKeys/KeyMap.swift):
  one small table, plus per-group gain.
- **Password fields:** while macOS Secure Input is active (password fields, some terminals with
  "Secure Keyboard Entry"), macOS hides keystrokes from all event taps, so ShotKeys is silent.
  This is intended and is not worked around. The menu tells you when Secure Input is on.
- **Bluetooth headphones** add their own output delay (often 100–200 ms) on top of ShotKeys's latency.

## Sounds

Files live in `Resources/Sounds/` and are named `<group>_<n>.<ext>`:

| Group | Files | Placeholder sound |
|---|---|---|
| `shot` | `shot_1.wav` … `shot_5.wav` | short blast |
| `space` | `space_1.wav`, `space_2.wav` | pump rack "chk-chk" |
| `reload` (Enter) | `reload_1.wav`, `reload_2.wav` | 3 or 2 shells clicked into the tube, then a pump rack (~0.8–1 s) |
| `backspace` | `backspace_1.wav`, `backspace_2.wav` | dry click + shell tink |

The bundled files are synthesized placeholders from `scripts/generate_sounds.py` (CC0). To use
real recordings, drop royalty-free or CC0 files into the folder using the same names (add
`shot_6.wav` etc. for more variants), record each source in
[`Resources/Sounds/LICENSES.md`](Resources/Sounds/LICENSES.md), then rebuild. WAV, AIFF, CAF, MP3
and M4A all work. Files are converted to 48 kHz mono and leading silence is trimmed at launch.
For best results use 150–600 ms clips with a quick fade-out, normalized to similar loudness.

Regenerate the placeholders with `python3 scripts/generate_sounds.py`.

## How it works

1. A listen-only `CGEventTap` (key-down only) runs on the main run loop. The callback reads only
   the key code, modifier flags and the auto-repeat flag, never the typed character. It maps the
   code to a sound group and hands that to the audio queue, then returns.
2. A dedicated `.userInteractive` queue owns the `AVAudioEngine`: 16 voices (`AVAudioPlayerNode`
   → `AVAudioUnitVarispeed`) feed a mixer, then a peak limiter, then the master volume. Voices are
   assigned round-robin and the oldest is stolen when all are busy. Each shot gets a random rate,
   and the same variant never plays twice in a row.
3. All samples are preloaded into memory. The output buffer is set to 256 frames (~6 ms).
4. If macOS disables the tap (timeout or user input), it is re-enabled immediately. A watchdog
   also checks every 5 s.
5. When the output device changes (headphones, Bluetooth, display), the engine is rewired to the
   new device and restarted.
6. After 15 s without a shot the engine pauses, so idle CPU is 0%. The next key press resumes it
   (about 10 ms, measured).

## Privacy

- Listen-only tap: it cannot block, change or delay your input.
- Only key codes are used, to choose a sound. Nothing is logged, stored or kept as history.
- No network code and no network entitlement.

## Measured performance (MacBook, built-in speakers, 44.1 kHz)

From `build/ShotKeys.app/Contents/MacOS/ShotKeys --selftest`, which plays 25 shots at 10/s through the real engine:

| Metric | Result | Target |
|---|---|---|
| Event → buffer scheduled | 0.3–0.6 ms p50, < 1.1 ms p95 | |
| Output latency (256-frame buffer + device) | 7.2 ms | |
| **Key-to-sound, engine awake** | **≈ 8 ms** | < 20 ms typical |
| Key-to-sound, first key after idle pause | ≈ 17–19 ms (9–11 ms resume + 7 ms output) | < 30 ms p95 |
| Idle CPU (engine paused) | 0% | near 0% |
| Memory footprint | 28–29 MB | < 50 MB |
| Network sockets | none | none |

Hardware keyboard scan time is not visible to software, so it isn't included.
The live p50/p95 for your real typing is shown under Diagnostics in the menu.

## Project layout

```
Package.swift
Resources/Info.plist             LSUIElement, bundle id, macOS 13 minimum
Resources/Sounds/                samples + LICENSES.md
Sources/ShotKeys/
  ShotKeysApp.swift              @main, MenuBarExtra, app delegate
  AppState.swift                 settings, permission flow, wiring
  KeyTap.swift                   listen-only CGEventTap
  KeyMap.swift                   key code → sound group table
  ShotEngine.swift               AVAudioEngine voice pool, limiter, latency stats
  MenuView.swift                 menu bar panel UI
  SelfTest.swift                 --selftest audio check
scripts/build.sh                 build + bundle + sign (+ --run)
scripts/create_signing_cert.sh   one-time stable signing identity
scripts/generate_sounds.py       placeholder sound synthesizer
```

## Acceptance checklist (PRD §8)

- [ ] Typing in Notes, a browser and Terminal plays a shot on every letter
- [ ] 10 keys/sec gives 10 distinct shots, no dropouts or clipping
- [ ] Shift/Cmd/Ctrl/Option/Fn alone are silent; holding a letter fires once
- [ ] Space, Enter, Backspace each sound distinct
- [ ] Enter plays the reload; shots typed during it are silent
- [ ] Enabled switch silences instantly and re-enables without a restart
- [ ] Volume changes live and survives relaunch
- [ ] Without permission the menu warns and the button opens the right pane; granting starts sound without a restart
- [ ] Switching speakers ↔ headphones keeps sound playing
- [ ] No Dock icon, no window, no network connection
- [ ] Latency measured and within target (see Diagnostics)

## Future ideas

Launch at login (SMAppService), a global mute hotkey, switchable sound packs, auto-mute while the
mic is in use, per-app rules, and a key-release sound.
