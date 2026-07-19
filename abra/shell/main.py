"""abra — the Python shell: hotkey, mic, tones, paste. All the platform-coupled
pieces, deliberately feature-free; features live in the engine.

Run:  uv run abra

Architecture notes (learned the hard way):
- The mic stream is opened ONCE and stays open; the hotkey only arms/disarms
  capture. Starting/stopping CoreAudio streams per clip intermittently
  deadlocks inside the HAL (lock-order inversion between PortAudio's
  start/stop callback and the IO thread — captured via `sample` 2026-07-18).
- Tones play via `afplay` in a child process: no output streams in-process.
- MLX work happens on the engine worker thread; the main thread only sleeps,
  so Ctrl+C is always deliverable. Exit is os._exit — attempting to "cleanly"
  stop audio on the way out is exactly what used to hang.
"""

import argparse
import functools
import os
import queue
import subprocess
import threading
import time
import traceback
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf
from pynput import keyboard

from abra.engine.core import DEFAULT_CLIPS_DIR, Engine
from abra.engine.stt import SAMPLE_RATE

MIN_CLIP_SECONDS = 0.4

HOTKEYS = {
    "alt_r": keyboard.Key.alt_r,
    "alt_l": keyboard.Key.alt_l,
    "cmd_r": keyboard.Key.cmd_r,
    "f13": getattr(keyboard.Key, "f13", keyboard.Key.alt_r),
}


class Recorder:
    """One always-open input stream; capture is gated by an arm flag."""

    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._armed = False
        self.started_at = 0.0
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            callback=self._on_audio,
        )
        self._stream.start()

    def _on_audio(self, indata, *_):
        if self._armed:
            self._chunks.append(indata.copy())

    def start(self):
        self._chunks = []
        self.started_at = time.time()
        self._armed = True

    def stop(self) -> np.ndarray:
        self._armed = False
        if not self._chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(self._chunks)[:, 0]


TONE_SR = 44_100
SOUNDS_DIR = Path(__file__).parent / "assets" / "sounds"


def _blip(freq: float, dur: float = 0.09) -> np.ndarray:
    t = np.linspace(0, dur, int(TONE_SR * dur), endpoint=False)
    env = np.minimum(1.0, np.minimum(t / 0.01, (dur - t) / 0.03))
    return (0.05 * np.sin(2 * np.pi * freq * t) * env).astype(np.float32)


def ensure_tone_files() -> tuple[Path, Path]:
    """Return (start, stop) tone paths, synthesizing fallbacks if missing."""
    start, stop = SOUNDS_DIR / "record-start.wav", SOUNDS_DIR / "record-stop.wav"
    if not (start.exists() and stop.exists()):
        SOUNDS_DIR.mkdir(parents=True, exist_ok=True)
        sf.write(start, np.concatenate([_blip(660), _blip(880)]), TONE_SR)
        sf.write(stop, np.concatenate([_blip(880), _blip(587)]), TONE_SR)
    return start, stop


def play_tone(path: Path):
    # Out-of-process playback: keeps CoreAudio output streams out of this
    # process entirely (see module docstring).
    subprocess.Popen(["afplay", str(path)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def paste_at_cursor(text: str):
    """Put text on the pasteboard, synthesize Cmd+V, restore the old contents."""
    old = subprocess.run(["pbpaste"], capture_output=True).stdout
    subprocess.run(["pbcopy"], input=text.encode())
    kb = keyboard.Controller()
    with kb.pressed(keyboard.Key.cmd):
        kb.press("v")
        kb.release("v")
    # Give the frontmost app time to read the pasteboard before restoring.
    time.sleep(0.35)
    subprocess.run(["pbcopy"], input=old)


def already_running() -> int | None:
    """Pid of another live abra instance, if any."""
    out = subprocess.run(["pgrep", "-f", r"\.venv/bin/abra( |$)"],
                         capture_output=True, text=True).stdout
    others = [int(p) for p in out.split() if int(p) != os.getpid()]
    return others[0] if others else None


def engine_loop(args, clips: queue.Queue):
    """Worker thread: owns the engine; main thread stays signal-responsive."""
    engine = Engine(args.model,
                    save_dir=None if args.no_save else Path(args.save_clips))
    print(f"hold [{args.key}] to talk, release to type. Ctrl+C to quit.")

    while True:
        audio, started, ended = clips.get()
        print("○ transcribing…", end="\r", flush=True)
        r = engine.process_clip(audio, started, ended)

        slow = (f"  ⏱ slow (idle {r.idle_s:.0f}s before)" if r.stt_ms > 600 and r.idle_s
                else "  ⏱ slow" if r.stt_ms > 600 else "")
        fixed = "" if r.text == r.raw_text else "  ✎ dictionary"
        print(f"[{r.duration_s:.1f}s clip · peak {r.peak:.3f}"
              f" → {r.stt_ms:.0f}ms stt]{slow}{fixed} {r.text}")
        if r.peak < 0.01:
            print("  ⚠ mic captured near-silence — check System Settings →"
                  " Privacy & Security → Microphone for your terminal app,"
                  " then fully restart it.")
        if r.saved_path is not None:
            print(f"  saved → {r.saved_path}")
        if r.text and not args.no_paste:
            paste_at_cursor(r.text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", choices=HOTKEYS, default="alt_r",
                        help="push-to-talk key (default: right Option)")
    parser.add_argument("--model",
                        default=os.environ.get("ABRA_MODEL",
                                               "mlx-community/parakeet-tdt-0.6b-v3"),
                        help="parakeet-mlx model id (env: ABRA_MODEL)")
    parser.add_argument("--no-paste", action="store_true",
                        help="print transcript instead of pasting")
    parser.add_argument("--save-clips", default=str(DEFAULT_CLIPS_DIR),
                        metavar="DIR",
                        help="corpus dir for wav + metadata (default: repo clips/)")
    parser.add_argument("--no-save", action="store_true",
                        help="don't store clips")
    parser.add_argument("--no-tone", action="store_true",
                        help="disable the start/stop recording tones")
    args = parser.parse_args()
    hotkey = HOTKEYS[args.key]

    if (pid := already_running()) is not None:
        print(f"another abra is already running (pid {pid}) — two instances"
              f" would both hear the hotkey and paste twice.\n"
              f"kill it first:  kill {pid}")
        raise SystemExit(1)

    device = sd.query_devices(kind="input")
    print(f"input device: {device['name']}")

    recorder = Recorder()  # opens the session-long mic stream
    start_tone, stop_tone = ensure_tone_files()
    clips: queue.Queue = queue.Queue()
    holding = False

    worker = threading.Thread(target=engine_loop, args=(args, clips),
                              daemon=True, name="abra-engine")
    worker.start()

    def never_die(fn):
        """A raised exception kills pynput's listener thread silently and the
        hotkey goes deaf. Log it and keep listening instead."""
        @functools.wraps(fn)
        def wrapped(key):
            nonlocal holding
            try:
                fn(key)
            except Exception:
                holding = False
                print(f"\n⚠ error in {fn.__name__} — still listening:")
                traceback.print_exc()
        return wrapped

    @never_die
    def on_press(key):
        nonlocal holding
        if key == hotkey and not holding:
            holding = True
            recorder.start()
            if not args.no_tone:
                play_tone(start_tone)
            print("● recording…", end="\r", flush=True)

    @never_die
    def on_release(key):
        nonlocal holding
        if key != hotkey or not holding:
            return
        holding = False
        audio = recorder.stop()
        ended = time.time()
        if not args.no_tone:
            play_tone(stop_tone)
        duration = len(audio) / SAMPLE_RATE
        if duration < MIN_CLIP_SECONDS:
            print(f"  (clip too short: {duration:.2f}s)     ")
            return
        clips.put((audio, recorder.started_at, ended))

    listener = keyboard.Listener(on_press=on_press, on_release=on_release)
    listener.start()

    # Main thread does nothing but wait for Ctrl+C. No blocking C calls here:
    # this is what guarantees the interrupt always lands.
    try:
        while True:
            time.sleep(0.5)
            if not worker.is_alive():
                print("engine thread died — exiting")
                os._exit(1)
    except KeyboardInterrupt:
        print("\nbye")
        # Do NOT stop audio streams here: FinishStoppingStream can deadlock
        # in CoreAudio (that's the hang this design exists to prevent).
        # The OS reclaims everything on exit.
        os._exit(0)


if __name__ == "__main__":
    main()
