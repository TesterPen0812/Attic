#!/usr/bin/env python3
"""Attic's interface sounds, synthesized from nothing (Planning.md Accepted
2026-11-10, "Sounds"). Standard library only, and deterministic: the same
script always writes the same bytes, so the files under
Attic/Resources/Sounds can be checked against it.

    python3 Scripts/generate_sounds.py            # write the files
    python3 Scripts/generate_sounds.py --check    # exit 1 if a file differs
    python3 Scripts/generate_sounds.py --report   # length, peak, loudness, spectrum

The family: soft mallet notes (a fundamental with a quiet octave and a short
woody overtone, raised-cosine attacks, no partial above about 4 kHz),
filtered-noise breaths for things leaving and coming back, low felt taps for
things landing. Every cue is normalised to one loudness, then offset on
purpose (undone and copied sit lower), with peaks far below full scale.
"""

import argparse
import math
import struct
import sys
from pathlib import Path

RATE = 48_000
ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Attic" / "Resources" / "Sounds"

# Loudness every cue is normalised to: the loudest 100 ms of the K-weighted
# signal (ITU-R BS.1770's filter, ungated). macOS's own interface sounds sit
# around -14 on this scale; Attic stays well under them.
TARGET_LOUDNESS = -32.0
# No cue may peak above this (dBFS), whatever its loudness.
PEAK_CEILING = -9.0


# --------------------------------------------------------------- primitives

def silence(seconds):
    return [0.0] * int(round(seconds * RATE))


def mix(into, sound, at=0.0, gain=1.0):
    start = int(round(at * RATE))
    needed = start + len(sound)
    if len(into) < needed:
        into.extend([0.0] * (needed - len(into)))
    for i, value in enumerate(sound):
        into[start + i] += value * gain
    return into


def attack_curve(t, attack):
    """A raised-cosine onset: no click, no hard edge."""
    if t >= attack:
        return 1.0
    return 0.5 - 0.5 * math.cos(math.pi * t / attack)


def note(freq, length, decay, attack=0.004, partials=((1.0, 1.0, 1.0),),
         glide_to=None, glide_time=0.03):
    """A struck tone: each partial (ratio, amplitude, decay factor) rings
    down on its own, higher ones faster, the way a soft mallet sounds. With
    `glide_to` the pitch slides exponentially from `freq` towards it."""
    count = int(round(length * RATE))
    phases = [0.0] * len(partials)
    out = []
    for i in range(count):
        t = i / RATE
        if glide_to is None:
            f = freq
        else:
            f = glide_to + (freq - glide_to) * math.exp(-t / glide_time)
        onset = attack_curve(t, attack)
        value = 0.0
        for k, (ratio, amp, decay_factor) in enumerate(partials):
            partial_f = f * ratio
            if partial_f < RATE / 2:
                value += amp * math.exp(-t / (decay * decay_factor)) * math.sin(phases[k])
            phases[k] += 2 * math.pi * partial_f / RATE
        out.append(value * onset)
    return out


class Noise:
    """xorshift32: the same white noise on every machine."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF or 1

    def next(self):
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x
        return x / 2_147_483_648.0 - 1.0


def breath(length, start_hz, end_hz, seed, attack=0.012, decay=0.05, q=0.9,
           swell=False):
    """Band-passed noise whose centre sweeps from `start_hz` to `end_hz`: a
    soft whoosh. `swell` makes it grow towards its end instead (the
    reverse of a whoosh away), then close quickly."""
    noise = Noise(seed)
    count = int(round(length * RATE))
    low = band = 0.0
    damping = 1.0 / q
    out = []
    for i in range(count):
        t = i / RATE
        progress = t / length
        centre = start_hz * (end_hz / start_hz) ** progress
        f = 2.0 * math.sin(math.pi * centre / RATE)
        x = noise.next()
        low += f * band
        high = x - low - damping * band
        band += f * high
        if swell:
            rise = 0.5 - 0.5 * math.cos(math.pi * min(progress / 0.78, 1.0))
            fall = 1.0 if progress < 0.78 else math.exp(-(t - 0.78 * length) / decay)
            env = rise * fall
        else:
            env = attack_curve(t, attack) * math.exp(-t / decay)
        out.append(band * env)
    # Two more poles twice over: nothing hissy above the breath.
    return lowpass(lowpass(out, 2_200.0), 2_200.0)


def biquad(signal, b, a):
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for x in signal:
        y = b[0] * x + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def lowpass(signal, cutoff, q=0.7071):
    """A 12 dB/octave low-pass (the RBJ cookbook biquad)."""
    w = 2 * math.pi * cutoff / RATE
    alpha = math.sin(w) / (2 * q)
    a0 = 1 + alpha
    b = ((1 - math.cos(w)) / 2 / a0, (1 - math.cos(w)) / a0, (1 - math.cos(w)) / 2 / a0)
    a = (1.0, -2 * math.cos(w) / a0, (1 - alpha) / a0)
    return biquad(signal, b, a)


def one_pole_lowpass(signal, cutoff):
    k = 1.0 - math.exp(-2.0 * math.pi * cutoff / RATE)
    y = 0.0
    out = []
    for x in signal:
        y += k * (x - y)
        out.append(y)
    return out


def dc_block(signal, cutoff=40.0):
    r = math.exp(-2.0 * math.pi * cutoff / RATE)
    x1 = y1 = 0.0
    out = []
    for x in signal:
        y = x - x1 + r * y1
        x1, y1 = x, y
        out.append(y)
    return out


def finish(signal, length, fade=0.012):
    """Trim or pad to `length`, keep the highs soft, and close on silence."""
    count = int(round(length * RATE))
    signal = (signal + [0.0] * count)[:count]
    signal = one_pole_lowpass(dc_block(signal), 6_500.0)
    fade_count = int(round(fade * RATE))
    for i in range(fade_count):
        index = count - fade_count + i
        signal[index] *= 0.5 + 0.5 * math.cos(math.pi * (i + 1) / fade_count)
    return signal


# K-weighting at 48 kHz (ITU-R BS.1770-4).
K_SHELF = ((1.53512485958697, -2.69169618940638, 1.19839281085285),
           (1.0, -1.69065929318241, 0.73248077421585))
K_HIGHPASS = ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621))


def loudness(signal, window=0.1):
    """The loudest `window` of the K-weighted signal, in LKFS-like dB."""
    weighted = biquad(biquad(signal, *K_SHELF), *K_HIGHPASS)
    squares = [v * v for v in weighted]
    size = int(window * RATE)
    if len(squares) < size:
        squares += [0.0] * (size - len(squares))
    total = sum(squares[:size])
    best = total
    for i in range(size, len(squares)):
        total += squares[i] - squares[i - size]
        best = max(best, total)
    return -0.691 + 10 * math.log10(max(best / size, 1e-20))


def peak_db(signal):
    return 20 * math.log10(max(max(abs(v) for v in signal), 1e-12))


# ------------------------------------------------------------------ timbres

# Fundamental, a quiet octave, and a short woody overtone near 4x: a soft
# mallet on wood or glass, never a beep.
MALLET = ((1.0, 1.0, 1.0), (2.0, 0.16, 0.45), (3.98, 0.05, 0.12))
# For low taps: enough second and third harmonic to be heard on a laptop's
# small speakers, which barely play the fundamental.
FELT = ((1.0, 1.0, 1.0), (2.0, 0.45, 0.6), (3.0, 0.16, 0.35))

C5, E5, G5, A5, C6, E6 = 523.25, 659.26, 783.99, 880.0, 1046.50, 1318.51


# --------------------------------------------------------------------- cues

def cue_done():
    """Two soft mallet notes a fifth apart, rising: C5, then G5."""
    out = []
    mix(out, note(C5, 0.30, decay=0.075, partials=MALLET), at=0.0, gain=0.62)
    mix(out, note(G5, 0.30, decay=0.11, partials=MALLET), at=0.068, gain=1.0)
    return finish(out, 0.30, fade=0.06)


def cue_undone():
    """The same voice, a third falling, shorter and quieter: E5, then C5."""
    out = []
    mix(out, note(E5, 0.17, decay=0.045, partials=MALLET), at=0.0, gain=0.8)
    mix(out, note(C5, 0.17, decay=0.06, partials=MALLET), at=0.052, gain=1.0)
    return finish(out, 0.17, fade=0.04)


def cue_created():
    """A light pop: a short tone that bubbles up an octave."""
    out = note(440.0, 0.09, decay=0.026, attack=0.003,
               partials=((1.0, 1.0, 1.0), (2.0, 0.12, 0.5)),
               glide_to=880.0, glide_time=0.012)
    return finish(out, 0.09, fade=0.025)


def cue_trashed():
    """A soft breath falling away, with a low felt tap under it."""
    out = breath(0.14, 1_500.0, 380.0, seed=0x7A5E, attack=0.010, decay=0.045)
    mix(out, note(340.0, 0.12, decay=0.028, attack=0.003, partials=FELT,
                  glide_to=260.0, glide_time=0.03), gain=0.35)
    return finish(out, 0.14, fade=0.03)


def cue_restored():
    """The reverse: a breath rising back, closing on a small tap."""
    out = breath(0.12, 380.0, 1_500.0, seed=0x7A5E, decay=0.018, swell=True)
    mix(out, note(270.0, 0.05, decay=0.016, attack=0.003, partials=FELT,
                  glide_to=350.0, glide_time=0.015), at=0.088, gain=0.3)
    return finish(out, 0.14, fade=0.025)


def cue_emptied():
    """Longer and lower than a single delete: a felt thump, then the breath
    settling away."""
    out = breath(0.24, 1_100.0, 320.0, seed=0x51F7, attack=0.020, decay=0.075)
    mix(out, note(300.0, 0.16, decay=0.045, attack=0.004, partials=FELT,
                  glide_to=235.0, glide_time=0.05), at=0.01, gain=0.5)
    return finish(out, 0.24, fade=0.06)


def cue_dropped():
    """A soft landing: a low felt tap with a breath of contact."""
    out = note(370.0, 0.11, decay=0.032, attack=0.003, partials=FELT,
               glide_to=270.0, glide_time=0.025)
    mix(out, breath(0.03, 1_200.0, 700.0, seed=0x0D20, attack=0.002, decay=0.008), gain=0.5)
    return finish(out, 0.11, fade=0.03)


def cue_copied():
    """A tiny tick: one very short, high-ish mallet tap with a soft body."""
    out = note(E6, 0.05, decay=0.010, attack=0.002,
               partials=((1.0, 1.0, 1.0), (0.5, 0.35, 1.6)))
    return finish(out, 0.05, fade=0.015)


def cue_attached():
    """Clipped in: two quick small taps, the second a step higher."""
    out = []
    taps = ((1.0, 1.0, 1.0), (2.0, 0.2, 0.4))
    mix(out, note(G5, 0.06, decay=0.012, attack=0.002, partials=taps), gain=0.8)
    mix(out, note(A5, 0.08, decay=0.018, attack=0.002, partials=taps), at=0.042)
    return finish(out, 0.12, fade=0.03)


def cue_failed():
    """Not an alarm: two low, soft bumps, the second a little lower."""
    out = []
    mix(out, note(293.66, 0.10, decay=0.034, attack=0.006, partials=FELT), gain=1.0)
    mix(out, note(261.63, 0.12, decay=0.040, attack=0.006, partials=FELT), at=0.10, gain=0.9)
    return finish(out, 0.22, fade=0.04)


# The cue, how it is made, and its loudness offset from the target (dB).
# The order and names match `AtticSounds.Cue`.
CUES = (
    ("done", cue_done, 0.0),
    ("undone", cue_undone, -4.0),
    ("created", cue_created, -1.0),
    ("trashed", cue_trashed, -1.0),
    ("restored", cue_restored, -1.0),
    ("emptied", cue_emptied, 0.0),
    ("dropped", cue_dropped, -1.0),
    ("copied", cue_copied, -5.0),
    ("attached", cue_attached, -2.0),
    ("failed", cue_failed, -1.0),
)


def render(name):
    """The cue's samples, normalised: in [-1, 1], never above the ceiling."""
    for cue, make, offset in CUES:
        if cue == name:
            signal = make()
            gain_db = TARGET_LOUDNESS + offset - loudness(signal)
            gain_db = min(gain_db, PEAK_CEILING - peak_db(signal))
            gain = 10 ** (gain_db / 20)
            return [v * gain for v in signal]
    raise KeyError(name)


def encode(signal):
    """16-bit mono PCM WAV bytes, header included."""
    frames = b"".join(
        struct.pack("<h", max(-32768, min(32767, int(round(v * 32767))))) for v in signal
    )
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(frames), b"WAVE", b"fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16,
        b"data", len(frames),
    )
    return header + frames


def decode(data):
    count = (len(data) - 44) // 2
    return [v / 32767 for v in struct.unpack("<%dh" % count, data[44:44 + count * 2])]


# ------------------------------------------------------------------- report

def fft(values):
    n = len(values)
    data = [complex(v) for v in values]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            data[i], data[j] = data[j], data[i]
    size = 2
    while size <= n:
        step = complex(math.cos(-2 * math.pi / size), math.sin(-2 * math.pi / size))
        for start in range(0, n, size):
            w = 1 + 0j
            for k in range(size // 2):
                a = data[start + k]
                b = data[start + k + size // 2] * w
                data[start + k] = a + b
                data[start + k + size // 2] = a - b
                w *= step
        size *= 2
    return data


def measure(signal):
    """Length, peak, loudness, where the energy sits and how the ends meet
    silence: what the report prints and the tests check."""
    n = 1
    while n < len(signal):
        n *= 2
    spectrum = fft(signal + [0.0] * (n - len(signal)))
    power = [abs(spectrum[i]) ** 2 for i in range(n // 2)]
    hz = [i * RATE / n for i in range(n // 2)]
    total = sum(power) or 1e-20
    above = sum(p for p, f in zip(power, hz) if f >= 4_000) or 1e-20
    centroid = sum(p * f for p, f in zip(power, hz)) / total
    strongest = hz[max(range(len(power)), key=power.__getitem__)]
    rms = math.sqrt(sum(v * v for v in signal) / len(signal))
    # Energy a laptop's speakers can play (above ~250 Hz), as a share.
    audible = sum(p for p, f in zip(power, hz) if f >= 250) / total
    return {
        "ms": 1000 * len(signal) / RATE,
        "peak_db": peak_db(signal),
        "rms_db": 20 * math.log10(max(rms, 1e-12)),
        "loudness": loudness(signal),
        "centroid_hz": centroid,
        "strongest_hz": strongest,
        "above_4k_db": 10 * math.log10(above / total),
        "laptop_share": audible,
        "first": abs(signal[0]),
        "last": abs(signal[-1]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare, don't write")
    parser.add_argument("--report", action="store_true", help="print measurements")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()

    stale = []
    for name, _, _ in CUES:
        data = encode(render(name))
        path = args.output / (name + ".wav")
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(path.name)
        else:
            if not args.report:
                args.output.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        if args.report:
            m = measure(decode(data))
            print("%-9s %4.0f ms  peak %6.1f dBFS  rms %6.1f  loud %6.1f  "
                  "centroid %5.0f Hz  strongest %5.0f Hz  >4k %6.1f dB  laptop %3.0f%%"
                  % (name, m["ms"], m["peak_db"], m["rms_db"], m["loudness"],
                     m["centroid_hz"], m["strongest_hz"], m["above_4k_db"],
                     100 * m["laptop_share"]))
    if stale:
        print("Out of date: " + ", ".join(stale) + " (run Scripts/generate_sounds.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
