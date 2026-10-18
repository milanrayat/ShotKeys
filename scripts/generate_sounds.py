#!/usr/bin/env python3
"""Generate placeholder sounds for ShotKeys (pure Python, no dependencies).

Writes 48 kHz / 16-bit mono WAVs into Resources/Sounds:
  shot_1..5.wav       short blast (noise crack + filtered body + low thump)
  space_1..2.wav      pump-action rack ("chk-chk")
  reload_1..2.wav     reload: shells clicked into the tube, then a pump rack (Enter)
  backspace_1..2.wav  dry click + shell eject
  piano_C3..G6.wav    Piano pack: 26 white-key notes (one per letter)
  piano_bass.wav      Piano pack: soft low C2 (Space)
  piano_chord.wav     Piano pack: C major chord (Enter)

Every file starts its transient at sample 0, is peak-normalised to -1 dBFS and ends in a fade.
Drop real samples into the same folder with the same naming pattern to replace them.
Usage: python3 scripts/generate_sounds.py [output_dir]
"""
import math
import os
import random
import struct
import sys
import wave

SR = 48_000


def n_samples(seconds):
    return int(seconds * SR)


def noise(n, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def lowpass(x, cutoff):
    a = 1.0 - math.exp(-2.0 * math.pi * cutoff / SR)
    y, out = 0.0, []
    for v in x:
        y += a * (v - y)
        out.append(y)
    return out


def highpass(x, cutoff):
    lp = lowpass(x, cutoff)
    return [v - l for v, l in zip(x, lp)]


def bandpass(x, freq, q):
    """RBJ band-pass biquad (0 dB peak)."""
    w0 = 2.0 * math.pi * freq / SR
    alpha = math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    b0, b2 = alpha / a0, -alpha / a0
    a1, a2 = -2.0 * math.cos(w0) / a0, (1.0 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for v in x:
        y = b0 * v + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, y
        out.append(y)
    return out


def decay(n, tau, delay=0):
    return [0.0 if i < delay else math.exp(-(i - delay) / (tau * SR)) for i in range(n)]


def mul(x, env):
    return [a * b for a, b in zip(x, env)]


def mix(*tracks):
    n = max(len(t) for t, _ in tracks)
    out = [0.0] * n
    for t, gain in tracks:
        for i, v in enumerate(t):
            out[i] += v * gain
    return out


def offset(x, seconds, total):
    d = n_samples(seconds)
    out = [0.0] * total
    for i, v in enumerate(x):
        if i + d < total:
            out[i + d] = v
    return out


def thump(n, f_start, f_end, sweep_tau, amp_tau):
    out, phase = [], 0.0
    for i in range(n):
        t = i / SR
        f = f_end + (f_start - f_end) * math.exp(-t / sweep_tau)
        phase += 2.0 * math.pi * f / SR
        out.append(math.sin(phase) * math.exp(-t / amp_tau))
    return out


def saturate(x, drive):
    k = math.tanh(drive)
    return [math.tanh(v * drive) / k for v in x]


def finish(x, fade_ms=30, peak_db=-1.0):
    n = len(x)
    fade = n_samples(fade_ms / 1000)
    for i in range(fade):
        x[n - fade + i] *= 1.0 - i / fade
    peak = max(abs(v) for v in x) or 1.0
    target = 10 ** (peak_db / 20)
    return [v * target / peak for v in x]


def resonant_click(n, rng, freqs, q, burst_ms, gain=1.0):
    burst = mul(noise(n, rng), decay(n, burst_ms / 1000))
    rings = [bandpass(burst, f, q) for f in freqs]
    return [gain * sum(r[i] for r in rings) for i in range(n)]


# --- Sounds -----------------------------------------------------------------

def shot(rng, dur, body_cut, body_tau, thump_hz, thump_tau, drive):
    n = n_samples(dur)
    crack = mul(highpass(noise(n, rng), 1500), decay(n, 0.0035))
    body = mul(lowpass(noise(n, rng), body_cut), decay(n, body_tau))
    tail = mul(lowpass(noise(n, rng), 500), decay(n, body_tau * 3))
    low = thump(n, thump_hz * 2.8, thump_hz, 0.025, thump_tau)
    return finish(saturate(mix((crack, 1.0), (body, 1.6), (tail, 0.35), (low, 1.2)), drive))


def pump_rack(rng, gap, freqs_back, freqs_fwd):
    n = n_samples(0.32)
    back = mix((resonant_click(n, rng, freqs_back, 18, 2.0), 1.0),
               (thump(n, 260, 160, 0.01, 0.02), 0.5),
               (mul(highpass(noise(n, rng), 3000), decay(n, 0.006)), 0.6))
    fwd = mix((resonant_click(n, rng, freqs_fwd, 22, 2.5), 1.2),
              (thump(n, 300, 180, 0.01, 0.025), 0.6),
              (mul(highpass(noise(n, rng), 2500), decay(n, 0.008)), 0.8))
    return finish(mix((back, 0.8), (offset(fwd, gap, n), 1.0)), fade_ms=40)


def shell_insert(rng, click_freqs, thunk_hz):
    """One shell pushed past the loading gate: metallic click + hollow brass/plastic thunk."""
    n = n_samples(0.16)
    return mix((resonant_click(n, rng, click_freqs, 16, 1.5), 1.0),
               (resonant_click(n, rng, [thunk_hz], 5, 3.0), 1.4),
               (mul(highpass(noise(n, rng), 2500), decay(n, 0.004)), 0.5))


def reload(rng, shell_times, rack_at, click_sets, thunk_hz):
    n = n_samples(rack_at + 0.36)
    tracks = []
    for t, freqs in zip(shell_times, click_sets):
        tracks.append((offset(shell_insert(rng, freqs, thunk_hz), t, n), 1.0))
    rack = pump_rack(rng, 0.11, [2300, 3700, 5100], [1900, 3100, 4600, 6200])
    tracks.append((offset(rack, rack_at, n), 1.3))
    return finish(mix(*tracks), fade_ms=40)


def shell_eject(rng, click_freq, tink_freqs, tink_delay):
    n = n_samples(0.22)
    click = mix((mul(highpass(noise(n, rng), 2000), decay(n, 0.003)), 1.0),
                (resonant_click(n, rng, [click_freq], 8, 1.0), 1.5))
    tink = resonant_click(n, rng, tink_freqs, 40, 0.8, gain=0.5)
    return finish(mix((click, 1.0), (offset(tink, tink_delay, n), 0.6)), fade_ms=25)


# --- Piano ------------------------------------------------------------------

NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
PIANO_NOTES = ["C3", "D3", "E3", "F3", "G3", "A3", "B3",
               "C4", "D4", "E4", "F4", "G4", "A4", "B4",
               "C5", "D5", "E5", "F5", "G5", "A5", "B5",
               "C6", "D6", "E6", "F6", "G6"]


def note_freq(name):
    midi = 12 * (int(name[1:]) + 1) + NOTE_OFFSETS[name[0]]
    return 440.0 * 2 ** ((midi - 69) / 12)


def piano_tone(rng, freq, dur, max_partials=10, brightness=1.0):
    """Additive piano-like tone: slightly inharmonic partials, two detuned strings per partial
    (gives the gentle beating), a fast-then-slow decay, and a short felt-hammer thump."""
    n = n_samples(dur)
    octave = math.log2(freq / 130.81)          # 0 at C3, ~3.6 at G6
    slow_tau = max(0.35, 1.2 - 0.22 * octave)  # high notes die away faster
    inharmonicity = 0.00015 * (1 + octave)
    out = [0.0] * n
    for k in range(1, max_partials + 1):
        fk = k * freq * math.sqrt(1 + inharmonicity * k * k)
        if fk > 12_000:
            break
        amp = brightness ** (k - 1) / k ** 1.25
        fast = math.exp(-1.0 / (0.09 / k ** 0.3 * SR))
        slow = math.exp(-1.0 / (slow_tau / (1 + 0.45 * (k - 1)) * SR))
        detune = 0.0007 if k < 4 else 0.0003
        w1 = 2 * math.pi * fk * (1 - detune) / SR
        w2 = 2 * math.pi * fk * (1 + detune) / SR
        out = [o + amp * (0.55 * fast ** i + 0.45 * slow ** i) * (math.sin(w1 * i) + math.sin(w2 * i))
               for i, o in enumerate(out)]
    hammer = mul(lowpass(noise(n, rng), min(3000, freq * 6)), decay(n, 0.004))
    peak = max(abs(v) for v in out) or 1.0
    return mix((out, 1.0 / peak), (hammer, 0.08))


def piano_note(rng, name):
    freq = note_freq(name)
    dur = max(0.9, 1.5 - 0.17 * math.log2(freq / 130.81))
    return finish(piano_tone(rng, freq, dur), fade_ms=150)


def piano_chord(rng, names, dur=1.6):
    n = n_samples(dur)
    tones = [piano_tone(rng, note_freq(name), dur) for name in names]
    return finish(mix(*[(t[:n], 1.0) for t in tones]), fade_ms=200)


def write_wav(path, samples):
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in samples))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Resources", "Sounds")
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(12)  # deterministic output

    sounds = {
        "shot_1": shot(rng, 0.38, 2200, 0.050, 55, 0.08, 2.5),
        "shot_2": shot(rng, 0.40, 1900, 0.060, 50, 0.09, 2.8),
        "shot_3": shot(rng, 0.36, 2600, 0.045, 60, 0.07, 2.3),
        "shot_4": shot(rng, 0.42, 2000, 0.055, 48, 0.10, 3.0),
        "shot_5": shot(rng, 0.37, 2400, 0.050, 58, 0.08, 2.6),
        "space_1": pump_rack(rng, 0.11, [2300, 3700, 5100], [1900, 3100, 4600, 6200]),
        "space_2": pump_rack(rng, 0.10, [2100, 3400, 5600], [2000, 3300, 4900]),
        "reload_1": reload(rng, [0.0, 0.19, 0.37], 0.62,
                           [[2600, 4100], [2500, 3900], [2700, 4300]], 780),
        "reload_2": reload(rng, [0.0, 0.21], 0.45,
                           [[2400, 3800], [2550, 4000]], 720),
        "backspace_1": shell_eject(rng, 3800, [6400, 9100], 0.045),
        "backspace_2": shell_eject(rng, 3300, [5900, 8300], 0.055),
    }
    for note in PIANO_NOTES:
        sounds["piano_" + note] = piano_note(rng, note)
    sounds["piano_bass"] = finish(piano_tone(rng, note_freq("C2"), 1.6, max_partials=6, brightness=0.7), fade_ms=200)
    sounds["piano_chord"] = piano_chord(rng, ["C3", "G3", "C4", "E4"])

    for name, samples in sounds.items():
        path = os.path.join(out_dir, name + ".wav")
        write_wav(path, samples)
        print(f"wrote {path} ({len(samples) / SR * 1000:.0f} ms)")


if __name__ == "__main__":
    main()
