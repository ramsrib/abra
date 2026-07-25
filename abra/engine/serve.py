"""abra-engine — the engine behind a newline-delimited JSON protocol on stdio.

This is the boundary native shells build against. Protocol (one JSON object
per line; stdout is protocol-only, diagnostics go to stderr):

  → {"id": 1, "cmd": "ping"}
  ← {"id": 1, "ok": true, "model": "..."}

  → {"id": 2, "cmd": "transcribe", "wav": "/abs/path.wav",
     "started": 1752901000.1, "ended": 1752901003.4}     # timestamps optional
  ← {"id": 2, "ok": true, "text": "...", "raw_text": "...",
     "stt_ms": 251.0, "duration_s": 3.3}

  → {"id": 3, "cmd": "dictionary"}                        # list every rule
  → {"id": 3, "cmd": "dictionary_add", "from": "ctu", "to": "CPU"}
  → {"id": 3, "cmd": "dictionary_remove", "from": "ctu"}
  ← {"id": 3, "ok": true, "path": "~/.abra/vocab.local.toml",
     "rules": [{"from": "ctu", "to": "CPU", "builtin": false}, ...]}
     # all three answer with the full post-change list; builtin rules ship
     # with the engine and only the user's own can be added or removed

  ← {"event": "ready", "model": "..."}                    # once, at startup

Errors: {"id": N, "ok": false, "error": "..."}.
"""

import argparse
import json
import os
import sys
import time

import soundfile as sf

from .core import DEFAULT_CLIPS_DIR, Engine
from .stt import SAMPLE_RATE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model",
                        default=os.environ.get("ABRA_MODEL",
                                               "mlx-community/parakeet-tdt-0.6b-v3"))
    parser.add_argument("--no-save", action="store_true",
                        help="don't store clips in the corpus")
    args = parser.parse_args()

    engine = Engine(args.model,
                    save_dir=None if args.no_save else DEFAULT_CLIPS_DIR)
    print(json.dumps({"event": "ready", "model": args.model}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            cmd = req.get("cmd")
            if cmd == "ping":
                resp = {"id": rid, "ok": True, "model": args.model}
            elif cmd == "transcribe":
                audio, sr = sf.read(req["wav"], dtype="float32")
                if audio.ndim > 1:
                    audio = audio[:, 0]
                if sr != SAMPLE_RATE:
                    raise ValueError(f"expected {SAMPLE_RATE}Hz wav, got {sr}")
                now = time.time()
                result = engine.process_clip(
                    audio, req.get("started", now), req.get("ended", now))
                resp = {"id": rid, "ok": True, "text": result.text,
                        "raw_text": result.raw_text, "stt_ms": result.stt_ms,
                        "duration_s": result.duration_s}
            elif cmd in ("dictionary", "dictionary_add", "dictionary_remove"):
                if cmd == "dictionary_add":
                    engine.dictionary.add(req["from"], req["to"])
                elif cmd == "dictionary_remove":
                    engine.dictionary.remove(req["from"])
                resp = {"id": rid, "ok": True,
                        "path": str(engine.dictionary.user_path),
                        "rules": [{"from": r.heard, "to": r.replacement,
                                   "builtin": r.builtin}
                                  for r in engine.dictionary.rules()]}
            else:
                resp = {"id": rid, "ok": False, "error": f"unknown cmd: {cmd}"}
        except json.JSONDecodeError as e:  # (a ValueError — keep the type here)
            resp = {"id": None, "ok": False, "error": f"bad request line: {e}"}
        except ValueError as e:  # rejected input — the message is the whole story
            resp = {"id": req.get("id") if isinstance(req, dict) else None,
                    "ok": False, "error": str(e)}
        except Exception as e:  # protocol must never crash the engine
            resp = {"id": req.get("id") if isinstance(req, dict) else None,
                    "ok": False, "error": f"{type(e).__name__}: {e}"}
        print(json.dumps(resp), flush=True)


if __name__ == "__main__":
    main()
