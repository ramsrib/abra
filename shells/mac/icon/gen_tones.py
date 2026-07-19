# /// script
# dependencies = ["numpy", "soundfile"]
# ///
"""Generate Abra's subtle recording cues (original audio, no external assets).

The tones use a sine-led timbre with a quiet second harmonic, a smooth attack,
and an exponential decay. This keeps them warm and audible without sounding
like alert beeps.

Run: uv run shells/mac/icon/gen_tones.py
"""

from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44_100
SOUNDS = Path(__file__).resolve().parents[3] / "abra" / "shell" / "assets" / "sounds"
PEAK = 0.06


def soft_note(
    frequency: float,
    duration: float,
    *,
    peak: float = PEAK,
    attack: float = 0.012,
    decay: float = 0.040,
) -> np.ndarray:
    """Synthesize one warm, softly struck note with click-free boundaries."""
    sample_count = round(SR * duration)
    t = np.arange(sample_count) / SR

    # A raised-cosine attack has zero slope at both ends, avoiding a click.
    attack_samples = max(1, round(SR * attack))
    attack_phase = np.minimum(np.arange(sample_count) / attack_samples, 1.0)
    envelope = np.sin(0.5 * np.pi * attack_phase) ** 2
    envelope *= np.exp(-np.maximum(t - attack, 0.0) / decay)

    # Bring the already-quiet exponential tail exactly to zero before the cut.
    release_samples = min(round(SR * 0.015), sample_count)
    release_phase = np.linspace(0.0, np.pi / 2, release_samples)
    envelope[-release_samples:] *= np.cos(release_phase) ** 2

    # A restrained second harmonic adds body while keeping high frequencies soft.
    phase = 2 * np.pi * frequency * t
    waveform = np.sin(phase) + 0.12 * np.sin(2 * phase)
    note = envelope * waveform
    note *= peak / np.max(np.abs(note))
    return note.astype(np.float32)


def silence(duration: float) -> np.ndarray:
    return np.zeros(round(SR * duration), dtype=np.float32)


def main() -> None:
    # A rising major third reads as open/listening without becoming an alert.
    record_start = np.concatenate(
        [soft_note(523.25, 0.085), silence(0.020), soft_note(659.25, 0.105)]
    )

    # A single lower note provides a calm, unambiguous completion cue.
    record_stop = soft_note(440.00, 0.145, decay=0.050)

    SOUNDS.mkdir(parents=True, exist_ok=True)
    sf.write(SOUNDS / "record-start.wav", record_start, SR)
    sf.write(SOUNDS / "record-stop.wav", record_stop, SR)
    print(f"wrote tones to {SOUNDS}")


if __name__ == "__main__":
    main()
