"""STT backend wrapper. Today: parakeet-mlx. The bench may swap this out —
nothing outside this module knows which engine is underneath."""

import os
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

SAMPLE_RATE = 16_000


def _ensure_tool_path():
    """parakeet-mlx shells out to ffmpeg. GUI-launched (launchd) processes get
    a bare PATH without homebrew — add the usual tool dirs so the engine works
    identically from a terminal, Finder, or launch-at-login."""
    extras = ["/opt/homebrew/bin", "/usr/local/bin",
              os.path.expanduser("~/.local/bin")]
    parts = os.environ.get("PATH", "").split(":")
    missing = [d for d in extras if d not in parts and os.path.isdir(d)]
    if missing:
        os.environ["PATH"] = ":".join(missing + parts)


def _log(msg: str):
    # Engine diagnostics go to stderr: in serve mode stdout is the protocol
    # channel and must stay clean.
    print(msg, file=sys.stderr, flush=True)


class Stt:
    def __init__(self, model_id: str):
        _ensure_tool_path()
        self.model_id = model_id
        _log(f"loading {model_id} …")
        t0 = time.perf_counter()
        from parakeet_mlx import from_pretrained
        self._model = from_pretrained(model_id)
        self.load_ms = (time.perf_counter() - t0) * 1000
        _log(f"model ready in {self.load_ms / 1000:.1f}s")

        # First inference triggers MLX kernel compilation; do it now so the
        # first real dictation isn't slow.
        t0 = time.perf_counter()
        self.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        self.warmup_ms = (time.perf_counter() - t0) * 1000
        _log(f"warmed up in {self.warmup_ms / 1000:.1f}s")

    def transcribe(self, audio: np.ndarray) -> str:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wav_path = Path(f.name)
        sf.write(wav_path, audio, SAMPLE_RATE)
        try:
            return self._model.transcribe(wav_path).text.strip()
        finally:
            wav_path.unlink(missing_ok=True)
