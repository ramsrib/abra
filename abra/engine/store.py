"""Clip + session persistence (SQLite). One db per corpus dir."""

import sqlite3
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from .stt import SAMPLE_RATE

SCHEMA = """
CREATE TABLE IF NOT EXISTS clips (
    id          INTEGER PRIMARY KEY,
    session_id  INTEGER,        -- row in sessions for the launch that made this
    file        TEXT NOT NULL,
    started_at  TEXT,           -- recording start, local ISO
    ended_at    TEXT,           -- recording end (key release)
    idle_s      REAL,           -- gap since previous clip ended; NULL for first of session
    duration_s  REAL,
    peak        REAL,
    rms         REAL,
    model       TEXT,
    stt_ms      REAL,
    words       INTEGER,
    transcript  TEXT,           -- raw STT output
    final_text  TEXT,           -- after dictionary/cleanup; what got pasted
    corrected   TEXT            -- human ground truth; NULL = not reviewed yet
);
CREATE TABLE IF NOT EXISTS sessions (
    id          INTEGER PRIMARY KEY,
    started_at  TEXT,
    model       TEXT,
    load_ms     REAL,           -- from_pretrained wall time
    warmup_ms   REAL            -- first (kernel-compiling) inference wall time
);
"""


def iso(ts: float | None) -> str | None:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts)) if ts else None


class Store:
    def __init__(self, save_dir: Path):
        self.save_dir = save_dir
        save_dir.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(save_dir / "clips.db", check_same_thread=False)
        self.db.executescript(SCHEMA)
        for col in ("session_id", "final_text"):  # dbs from before these columns
            cols = [r[1] for r in self.db.execute("PRAGMA table_info(clips)")]
            if col not in cols:
                self.db.execute(f"ALTER TABLE clips ADD COLUMN {col} "
                                + ("INTEGER" if col == "session_id" else "TEXT"))

    def log_session(self, model: str, load_ms: float, warmup_ms: float) -> int:
        cur = self.db.execute(
            "INSERT INTO sessions (started_at, model, load_ms, warmup_ms)"
            " VALUES (?,?,?,?)", (iso(time.time()), model, load_ms, warmup_ms))
        self.db.commit()
        return cur.lastrowid

    def save_clip(self, audio: np.ndarray, *, raw_text: str, final_text: str,
                  started: float, ended: float, idle_s: float | None,
                  stt_ms: float, model_id: str, session_id: int | None) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(started))
        wav_path = self.save_dir / f"{stamp}.wav"
        n = 1
        while wav_path.exists():
            n += 1
            wav_path = self.save_dir / f"{stamp}-{n}.wav"
        sf.write(wav_path, audio, SAMPLE_RATE)
        peak = float(np.abs(audio).max()) if len(audio) else 0.0
        rms = float(np.sqrt((audio ** 2).mean())) if len(audio) else 0.0
        self.db.execute(
            "INSERT INTO clips (session_id, file, started_at, ended_at, idle_s,"
            " duration_s, peak, rms, model, stt_ms, words, transcript, final_text)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (session_id, wav_path.name, iso(started), iso(ended), idle_s,
             len(audio) / SAMPLE_RATE, peak, rms, model_id, stt_ms,
             len(raw_text.split()), raw_text, final_text))
        self.db.commit()
        return wav_path
