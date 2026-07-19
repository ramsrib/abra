# 01 — end-to-end Python prototype (graduated)

**Outcome: ✅ proven, promoted.** The loop worked well enough to daily-drive,
so the code moved to the real package on 2026-07-19: engine → `abra/engine/`,
shell → `abra/shell/`, corpus → repo-root `clips/`. Run with `uv run abra`
from the repo root. Decision record: `ARCHITECTURE.md`.

What this experiment established, kept here as the historical record:

| date | observation |
|---|---|
| 2026-07-16 | Full loop feels instant: parakeet on M-series transcribes 2–6s clips in ~250ms warm. |
| 2026-07-16 | v2 emitted all-`<unk>` for a 6.9s English clip (2046ms). Re-run later on the same wav: perfect transcript from the same model. Transient runtime corruption, plausibly Metal under memory pressure — watch for recurrence. |
| 2026-07-17 | Latency spikes (800–1400ms vs ~250ms baseline) cluster after idle gaps — model paged out. Confirmed 2026-07-19 from clips.db: 859ms avg <30s idle → 1650ms avg >5m idle, max 8.8s. Led to the engine keep-warm heartbeat. |
| 2026-07-18 | Hard hang, Ctrl+C-immune. `sample` showed a CoreAudio lock-order deadlock between PortAudio's stream stop and the HAL IO thread — triggered by per-clip stream start/stop churn. Fix: one persistent mic stream, tones via afplay, transcription on a worker thread, exit via os._exit. Also: process footprint grew to 5.9GB after ~a day — watch memory over long sessions. |
| 2026-07-16→18 | Mishear collection became the personal-dictionary seed rules (vocab.toml) and its test set. |
