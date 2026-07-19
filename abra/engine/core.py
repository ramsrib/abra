"""The abra engine: STT → dictionary → (future: LLM cleanup, formatting),
plus persistence and model keep-warm. Shells feed it audio and get text back;
everything in here survives shell rewrites.
"""

import threading
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .dictionary import Dictionary
from .store import Store
from .stt import SAMPLE_RATE, Stt

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CLIPS_DIR = REPO_ROOT / "clips"
DEFAULT_VOCAB = REPO_ROOT / "vocab.toml"

# Latency data (clips.db, 2026-07-19): stt_ms rises monotonically with idle
# gap — 859ms avg under 30s idle, 1650ms avg (8.8s max) past 5m. The model
# gets paged out. A periodic tiny inference keeps its pages resident.
KEEP_WARM_AFTER_S = 60
KEEP_WARM_CHECK_S = 15


@dataclass
class ClipResult:
    raw_text: str
    text: str           # after dictionary; what the shell should paste
    stt_ms: float
    duration_s: float
    peak: float
    idle_s: float | None
    saved_path: Path | None


class Engine:
    def __init__(self, model_id: str, save_dir: Path | None = DEFAULT_CLIPS_DIR,
                 vocab_path: Path = DEFAULT_VOCAB, keep_warm: bool = True):
        self.model_id = model_id
        self.stt = Stt(model_id)
        self.dictionary = Dictionary.load(vocab_path)
        self.store = Store(save_dir) if save_dir else None
        self.session_id = (self.store.log_session(model_id, self.stt.load_ms,
                                                  self.stt.warmup_ms)
                           if self.store else None)
        self._lock = threading.Lock()          # model is not reentrant
        self._last_inference = time.time()
        self._prev_clip_ended: float | None = None
        if keep_warm:
            threading.Thread(target=self._keep_warm_loop, daemon=True,
                             name="abra-keepwarm").start()

    def process_clip(self, audio: np.ndarray, started: float,
                     ended: float) -> ClipResult:
        idle_s = (round(started - self._prev_clip_ended, 1)
                  if self._prev_clip_ended else None)
        self._prev_clip_ended = ended

        t0 = time.perf_counter()
        with self._lock:
            raw = self.stt.transcribe(audio)
            self._last_inference = time.time()
        stt_ms = (time.perf_counter() - t0) * 1000

        text = self.dictionary.apply(raw)
        peak = float(np.abs(audio).max()) if len(audio) else 0.0

        saved = None
        if self.store is not None:
            saved = self.store.save_clip(
                audio, raw_text=raw, final_text=text,
                started=started, ended=ended, idle_s=idle_s,
                stt_ms=stt_ms, model_id=self.model_id,
                session_id=self.session_id)

        return ClipResult(raw_text=raw, text=text, stt_ms=stt_ms,
                          duration_s=len(audio) / SAMPLE_RATE, peak=peak,
                          idle_s=idle_s, saved_path=saved)

    def _keep_warm_loop(self):
        silence = np.zeros(SAMPLE_RATE // 2, dtype=np.float32)
        while True:
            time.sleep(KEEP_WARM_CHECK_S)
            if time.time() - self._last_inference < KEEP_WARM_AFTER_S:
                continue
            if self._lock.acquire(blocking=False):  # never delay a real clip
                try:
                    self.stt.transcribe(silence)
                    self._last_inference = time.time()
                finally:
                    self._lock.release()
