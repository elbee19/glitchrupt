#!/usr/bin/env python3
"""Generate Glitchrupt's five original digital-crackle sound variants.

Run from any directory: python3 scripts/generate_sounds.py
Defaults: --seed 88501, output beside project in assets/sounds/.
Optional: --output-dir PATH --seed INTEGER
All sounds: 600 ms / 26,460 frames, stereo 44,100 Hz PCM16. No packages,
recordings, downloads, or external project files. Classic preserves the
chosen original digital crackle; the other voices use different excitation,
packet timing, gaps, and read-head motion. Every run verifies format,
headroom, RMS matching, exact zero endpoints, and deterministic synthesis.
"""

import argparse
import hashlib
import json
import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
COUNT = 26460
DURATION = 0.6

def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def master(channels, target_rms=0.15):
    """Soft density matching, -3.10 dBFS peak ceiling and short edge fades.

    Density matching targets comparable sample RMS, not a claimed perceptual
    loudness standard. The timbres intentionally remain quite different.
    """
    for i in range(COUNT):
        t = i / RATE
        fade = smooth(t / 0.0015) * smooth((DURATION - 1 / RATE - t) / 0.025)
        for channel in channels:
            channel[i] *= fade
    # Increase soft saturation only when the signal's crest factor would make
    # it substantially quieter at the common peak ceiling.
    chosen = channels
    for drive in [1.0, 1.5, 2.4, 4.0]:
        trial = [[math.tanh(value * drive) for value in channel] for channel in channels]
        peak = max(abs(v) for channel in trial for v in channel)
        rms = math.sqrt(sum(v * v for channel in trial for v in channel) / (COUNT * 2))
        chosen = trial
        if rms / max(peak, 1e-12) >= target_rms / 0.70:
            break
    peak = max(abs(v) for channel in chosen for v in channel)
    rms = math.sqrt(sum(v * v for channel in chosen for v in channel) / (COUNT * 2))
    gain = min(0.70 / max(peak, 1e-12), target_rms / max(rms, 1e-12))
    pcm = bytearray()
    for i in range(COUNT):
        pcm.extend(struct.pack('<hh', *(round(chosen[ch][i] * gain * 32767) for ch in range(2))))
    return bytes(pcm)


def classic(seed):
    """Sparse hard-edged broken packets and dry rasps; no melodic carrier."""
    rng = random.Random(seed + 200)
    channels = [[0.0] * COUNT for _ in range(2)]
    # Each packet consists of 1–5 ms repeated fragments of colored random
    # excitation. Different lengths/holds give irregular digital machine-gun
    # crackle without creating a conventional pitched note sequence.
    packets = [
        (0.000, 0.026, 1.00), (0.035, 0.012, 0.58),
        (0.057, 0.041, 0.78), (0.104, 0.018, 0.63),
        (0.132, 0.061, 0.88), (0.201, 0.009, 0.60),
        (0.222, 0.030, 0.77), (0.268, 0.016, 0.68),
        (0.296, 0.050, 0.74), (0.355, 0.019, 0.64),
        (0.393, 0.044, 0.59), (0.449, 0.017, 0.46),
        (0.482, 0.040, 0.35), (0.538, 0.035, 0.20),
    ]
    for packet_index, (start, duration, level) in enumerate(packets):
        fragment_size = rng.randrange(49, 211)
        hold = rng.choice([2, 3, 5, 7, 9])
        fragment = []
        low = 0.0
        current = 0.0
        dc = 0.0
        for j in range(fragment_size):
            if j % hold == 0:
                current = rng.uniform(-1.0, 1.0)
            low += 0.42 * (current - low)
            dc += 0.025 * (low - dc)
            fragment.append(math.tanh((low - dc) * 3.5))
        pan = rng.uniform(-0.85, 0.85)
        first = round(start * RATE)
        length = round(duration * RATE)
        low_body = 0.0
        for j in range(length):
            t = j / RATE
            envelope = smooth(t / 0.001) * smooth((duration - t) / 0.0025)
            # Flip every third repeat and shift the read head so repetition
            # stays unstable. A low noisy body supports the dry high packet.
            repeat = j // fragment_size
            k = (j + repeat * (7 + packet_index)) % fragment_size
            value = fragment[k] * (-1 if repeat % 3 == 2 else 1)
            low_body += 0.06 * (value - low_body)
            value = (0.70 * value + 0.35 * low_body) * envelope * level
            for ch in range(2):
                index = first + j + (round(0.0011 * RATE) if ch else 0)
                if index < COUNT:
                    channels[ch][index] += value * math.sqrt((1 + (pan if ch else -pan)) / 2)
    # Short downward data-reset pulses, deliberately separate from the much
    # more continuous metallic growl and from the bass-impact option.
    for ch in range(2):
        phase = 0.0
        for i in range(COUNT):
            t = i / RATE
            phase += 2 * math.pi * (48 + 65 * math.exp(-t / 0.028)) / RATE
            channels[ch][i] += 0.22 * math.sin(phase) * math.exp(-t / 0.07)
    return master(channels)


def fragment_source(rng, length, hold, lowpass, distortion, dc_rate=0.018):
    """Colored, nonlinear noise grain; no pitched sample or outside audio."""
    values = []
    held = 0.0
    low = 0.0
    dc = 0.0
    for j in range(length):
        if j % hold == 0:
            held = rng.uniform(-1, 1)
        low += lowpass * (held - low)
        dc += dc_rate * (low - dc)
        values.append(math.tanh((low - dc) * distortion))
    return values


def grain(channels, fragment, start, duration, level, pan=0.0,
          speed=1.0, drift=0.0, gap_hz=0.0, edge=0.001):
    """Replay a smoothed fragment with variable read-head motion and gaps."""
    first = round(start * RATE)
    length = round(duration * RATE)
    low = 0.0
    for j in range(length):
        elapsed = j / RATE
        envelope = smooth(elapsed / edge) * smooth((duration - elapsed) / (edge * 2))
        position = j * (speed + drift * elapsed / duration)
        index = int(position) % len(fragment)
        value = fragment[index]
        low += 0.07 * (value - low)
        value = value * 0.83 + low * 0.17
        if gap_hz:
            # Smoothly edged gaps preserve character without creating a hard
            # discontinuity at the recording endpoints or each grain splice.
            pulse = math.sin(2 * math.pi * gap_hz * elapsed)
            envelope *= 0.22 + 0.78 * smooth((pulse + 0.15) / 0.35)
        value *= envelope * level
        for ch in range(2):
            index = first + j + (round(0.0009 * RATE) if ch else 0)
            if index < COUNT:
                channels[ch][index] += value * math.sqrt((1 + (pan if ch else -pan) * 0.85) / 2)


def fracture(seed):
    """Ragged cuts that lengthen and tear backwards before disintegrating."""
    rng = random.Random(seed + 1100)
    channels = [[0.0] * COUNT for _ in range(2)]
    packets = [(0.000, 0.055, 0.80), (0.064, 0.017, 0.60),
               (0.086, 0.028, 0.77), (0.127, 0.082, 0.88),
               (0.215, 0.010, 0.75), (0.237, 0.024, 0.65),
               (0.272, 0.092, 0.80), (0.371, 0.044, 0.62),
               (0.431, 0.018, 0.57), (0.466, 0.066, 0.45),
               (0.543, 0.040, 0.22)]
    for j, (start, length, level) in enumerate(packets):
        fragment = fragment_source(rng, rng.randrange(147, 451), rng.choice([3, 5, 8]), 0.38, 4.8)
        speed = (-0.83 if j % 3 == 1 else 1.21) * (1 - 0.035 * j)
        grain(channels, fragment, start, length, level, (-1 if j % 2 else 1) * 0.72,
              speed=speed, drift=-0.46, gap_hz=rng.choice([0, 39, 63]), edge=0.0008)
    return master(channels)


def brownout(seed):
    """Low dirty crackle that sags, coughs and loses voltage in slow packets."""
    rng = random.Random(seed + 2200)
    channels = [[0.0] * COUNT for _ in range(2)]
    packets = [(0.000, 0.093, 0.72), (0.108, 0.060, 0.70),
               (0.177, 0.118, 0.87), (0.311, 0.043, 0.61),
               (0.365, 0.094, 0.63), (0.479, 0.100, 0.35)]
    for j, (start, length, level) in enumerate(packets):
        fragment = fragment_source(rng, rng.randrange(211, 539), rng.choice([11, 17, 23]), 0.13, 5.5, 0.008)
        grain(channels, fragment, start, length, level, rng.uniform(-0.35, 0.35),
              speed=0.91 - 0.08 * j, drift=-0.20, gap_hz=23 + 3 * j, edge=0.002)
    phase = 0.0
    for i in range(COUNT):
        t = i / RATE
        phase += 2 * math.pi * (58 + 45 * math.exp(-t / 0.12)) / RATE
        # Distortion adds 170–500 Hz harmonics so laptop speakers preserve
        # the sagging weight even without reproducing its deepest component.
        throat = math.tanh(2.9 * (math.sin(phase) + 0.23 * math.sin(phase * 3.03)))
        gate = 0.25 + 0.75 * smooth((math.sin(2 * math.pi * 15 * t) + 0.25) / 0.5)
        envelope = math.exp(-t / 0.24) * gate * smooth(t / 0.003)
        for ch in range(2):
            channels[ch][i] += 0.25 * throat * envelope
    return master(channels)


def arc(seed):
    """Crisp brief electrical sparks in clusters, with short dark spaces."""
    rng = random.Random(seed + 3300)
    channels = [[0.0] * COUNT for _ in range(2)]
    # Many short nonperiodic grains replace the baseline's held rasps. Band
    # limiting and short events avoid a piercing sustained high oscillator.
    starts = [0.000, 0.010, 0.028, 0.051, 0.083, 0.092, 0.110,
              0.147, 0.164, 0.178, 0.203, 0.243, 0.254, 0.269,
              0.305, 0.343, 0.356, 0.377, 0.411, 0.439, 0.467,
              0.481, 0.519, 0.553, 0.571]
    for j, start in enumerate(starts):
        length = rng.uniform(0.008, 0.022)
        size = round(length * RATE)
        fragment = fragment_source(rng, size + 40, rng.choice([1, 2, 3]), 0.52, 3.0, 0.08)
        grain(channels, fragment, start, length, (0.80 - start * 0.75) * rng.uniform(0.72, 1.0),
              rng.uniform(-0.9, 0.9), speed=1.0, edge=0.00055)
    # Two short darker arc roots prevent a thin all-treble impression.
    for start in [0.0, 0.24]:
        fragment = fragment_source(rng, 274, 9, 0.20, 4.0)
        grain(channels, fragment, start, 0.060, 0.32, 0.0, speed=0.72, edge=0.0015)
    return master(channels)


def stutter(seed):
    """One recognizable broken buffer repeats, skips, then slows to a stop."""
    rng = random.Random(seed + 4400)
    channels = [[0.0] * COUNT for _ in range(2)]
    buffer = fragment_source(rng, 397, 5, 0.34, 4.0)
    # Reuse the same motif across grouped pulses. A fixed 32 ms cadence first
    # speeds into a triple-repeat, pauses, then stretches into the final cut.
    packets = [(0.000, 0.022, 0.85), (0.032, 0.022, 0.79),
               (0.064, 0.022, 0.76), (0.112, 0.019, 0.80),
               (0.137, 0.019, 0.73), (0.162, 0.019, 0.72),
               (0.207, 0.031, 0.82), (0.250, 0.031, 0.78),
               (0.293, 0.031, 0.70), (0.352, 0.044, 0.66),
               (0.410, 0.046, 0.57), (0.477, 0.056, 0.45),
               (0.553, 0.032, 0.24)]
    for j, (start, length, level) in enumerate(packets):
        grain(channels, buffer, start, length, level, (-0.5 if j % 3 == 0 else 0.5),
              speed=1.16 - 0.055 * j, drift=-0.10, edge=0.001)
    return master(channels)


VARIANTS = [
    ('classic', 'Classic', 'The original dry digital crackle, with uneven short packets and descending reset pulse.', classic),
    ('fracture', 'Fracture', 'Ragged forward and backward tearing cuts, widening gaps and unstable read-head motion.', fracture),
    ('brownout', 'Brownout', 'Darker dirty crackle, sagging low growl and sputtering voltage dropouts.', brownout),
    ('arc', 'Arc', 'Bright brief electrical sparks, irregular clustered snaps and short dark spaces.', arc),
    ('stutter', 'Stutter', 'A recognizable broken buffer repeats in groups, skips and slows to a stop.', stutter),
]


def inspect(pcm):
    """Meaningful signal invariants independent of the generator's layers."""
    if len(pcm) != COUNT * 2 * 2:
        raise ValueError('Audio must have exactly 26,460 stereo PCM16 frames')
    values = struct.unpack('<' + 'h' * (COUNT * 2), pcm)
    peak = max(abs(v) for v in values) / 32768
    rms = math.sqrt(sum((v / 32768) ** 2 for v in values) / len(values))
    if peak > 0.72:
        raise ValueError(f'Headroom exceeded: {peak}')
    if not 0.14 <= rms <= 0.16:
        raise ValueError(f'RMS outside comparison range: {rms}')
    if values[:2] != (0, 0) or values[-2:] != (0, 0):
        raise ValueError('Audio endpoints must be exactly zero in both channels')
    if values[::2] == values[1::2]:
        raise ValueError('Expected a genuine stereo signal')
    return {'peak': round(peak, 8), 'rms': round(rms, 8), 'pcm_sha256': hashlib.sha256(pcm).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parent.parent / 'assets' / 'sounds')
    parser.add_argument('--seed', type=int, default=88501)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest = {'format_version': 1, 'sample_rate': RATE, 'duration_ms': 600,
                'frames': COUNT, 'channels': 2, 'sample_width_bytes': 2,
                'seed': args.seed, 'variants': []}
    hashes = []
    for variant_id, title, detail, render in VARIANTS:
        pcm = render(args.seed)
        if pcm != render(args.seed):
            raise ValueError(f'{variant_id}: nondeterministic synthesis')
        stats = inspect(pcm)
        path = args.output_dir / f'{variant_id}.wav'
        with wave.open(str(path), 'wb') as target:
            target.setnchannels(2)
            target.setsampwidth(2)
            target.setframerate(RATE)
            target.writeframes(pcm)
        with wave.open(str(path), 'rb') as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes()) != (2, 2, RATE, COUNT):
                raise ValueError(f'{variant_id}: unexpected WAV format')
            if source.readframes(COUNT) != pcm:
                raise ValueError(f'{variant_id}: written PCM differs from generated signal')
        manifest['variants'].append({'id': variant_id, 'title': title, 'detail': detail, 'file': path.name, **stats})
        hashes.append(stats['pcm_sha256'])
        print(f'{variant_id}: 600.000 ms stereo 44100 Hz PCM16; peak={stats["peak"]:.6f}, RMS={stats["rms"]:.6f}; zero endpoints; deterministic PASS')
    if len(set(hashes)) != len(VARIANTS):
        raise ValueError('Two variants unexpectedly have identical audio')
    (args.output_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()


