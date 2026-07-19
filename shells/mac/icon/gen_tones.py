# /// script
# dependencies = ["numpy", "soundfile"]
# ///
"""Generate abra's recording tones (original audio, no third-party assets).

Two soft percussive tocks: rising pair for record-start, falling pair for
record-stop. Exponentially decaying sines with a touch of second harmonic —
warm, quiet, and short enough to never get in the way.

Run:  uv run shells/mac/icon/gen_tones.py
"""

from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44_100
SOUNDS = Path(__file__).resolve().parents[3] / "abra" / "shell" / "assets" / "sounds"


def tock(freq: float, dur: float = 0.11, peak: float = 0.12) -> np.ndarray:
    t = np.linspace(0, dur, int(SR * dur), endpoint=False)
    env = np.exp(-t * 45) * np.minimum(1.0, t / 0.004)   # fast attack, warm decay
    wave = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * freq * 2 * t)
    return (peak * env * wave / 1.25).astype(np.float32)


def pair(f1: float, f2: float) -> np.ndarray:
    gap = np.zeros(int(SR * 0.045), dtype=np.float32)
    return np.concatenate([tock(f1), gap, tock(f2)])


SOUNDS.mkdir(parents=True, exist_ok=True)
sf.write(SOUNDS / "record-start.wav", pair(660, 880), SR)   # rising: listening
sf.write(SOUNDS / "record-stop.wav", pair(880, 587), SR)    # falling: got it
print(f"wrote tones to {SOUNDS}")
