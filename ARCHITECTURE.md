# abra architecture

## The decision (2026-07-19)

**Engine/shell split. The engine is Python, permanently. Shells are
replaceable.** Decided before feature work began so that features are never
built on throwaway code.

Rationale: every planned feature — personal dictionary, LLM cleanup,
context-aware formatting, vocabulary biasing, the corpus store — is
text-and-data pipeline logic between STT output and paste. None of it touches
the platform. The platform-coupled pieces (hotkey, mic, tones, paste, menu
bar) are small, feature-free, and cheap to rewrite per shell generation.
The STT bench therefore stops being an architecture gate: whichever backend
wins becomes an engine-internal choice.

```
┌─ shell (replaceable) ──────┐      ┌─ engine (permanent, Python) ────────────┐
│ hotkey · mic · tones ·     │ ───▶ │ STT → dictionary → cleanup → formatting │
│ paste · menu bar           │ ◀─── │ + clips.db, sessions, vocab, config     │
└────────────────────────────┘      └─────────────────────────────────────────┘
   abra/shell (Python, today)          abra/engine
   shells/mac (Swift, parallel)
```

## Layout

- `abra/engine/` — `stt.py` (backend wrapper), `dictionary.py` (vocab.toml
  rules), `core.py` (Engine: pipeline + keep-warm + persistence),
  `store.py` (SQLite), `serve.py` (stdio protocol for non-Python shells)
- `abra/shell/` — the Python shell: pynput hotkey, persistent mic stream,
  afplay tones, pasteboard injection. In-process `Engine`, no protocol hop.
- `shells/mac/` — the Swift shell (parallel track), talks to `abra-engine`
  over stdio. See its README for the roadmap.
- `experiments/` — disposable bench harnesses and A/B tests only.
- `clips/` — the corpus (wavs + clips.db). Local-only, gitignored.
- `vocab.toml` — the personal dictionary rules (committed).

## Shell ↔ engine protocol

Newline-delimited JSON over stdio (`uv run abra-engine`). stdout is
protocol-only; diagnostics go to stderr. Defined and versioned in
`abra/engine/serve.py` — that docstring is the authoritative spec.

- `{"event": "ready", "model": …}` emitted once at startup
- `ping` → liveness + model id
- `transcribe {wav, started?, ended?}` → `{text, raw_text, stt_ms, duration_s}`
  — `text` is post-dictionary (paste this); `raw_text` is the STT output.
  The engine logs the clip to the corpus itself unless started with
  `--no-save`.

## Hard-won platform rules (do not relearn these)

1. Open the mic stream once per session; arm/disarm capture. Per-clip
   CoreAudio start/stop deadlocks intermittently in the HAL (lock-order
   inversion, `sample`d 2026-07-18).
2. No audio output streams in-process — tones play via `afplay`.
3. The shell's main thread must never enter blocking C calls: MLX and
   audio work live on worker threads so Ctrl+C always lands. Exit with
   `os._exit`; "clean" audio teardown is what used to hang.
4. Mic permission belongs to the hosting terminal for the Python shell —
   and some privacy-focused terminals ship without any mic entitlement
   (recording silently yields zeros). The native shell owns its own
   permissions (part of why it exists).
5. The model gets paged out during idle and costs seconds on wake — the
   engine keep-warm heartbeat exists because clip data proved it
   (859ms avg <30s idle vs 1650ms avg >5m, max 8.8s).
6. The shell supervises the engine: auto-restart with exponential backoff,
   bounded at 5 consecutive failures, then a visible give-up with a pointer
   to `~/Library/Logs/abra-shell.log` (where engine stderr and protocol
   failures are recorded — Finder-launched apps have no stderr otherwise).
7. A running instance survives bundle replacement (`brew upgrade`,
   `make release`) executing old code — quit and relaunch after upgrades.
