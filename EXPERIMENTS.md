# abra — experiment backlog

The full map of things worth trying, in rough order. Each experiment is a
numbered folder under `experiments/` that answers **one question**; winners
graduate into the real app, losers get a paragraph in this file explaining
why. Numbers get assigned when an experiment actually starts — the order
below is a suggestion, not a commitment.

## Phase 1 — prove the loop

### 01 · Python end-to-end prototype ✅ graduated
**Question:** does hotkey → record → parakeet-mlx → paste feel instant enough to use daily?

**Answer: yes.** Proven in three days of daily-driving, then promoted into the
real package (`abra/engine` + `abra/shell`). What it established:

| date | finding |
|---|---|
| 2026-07-16 | Full loop feels instant: parakeet on M-series transcribes 2–6s clips in ~250ms warm. |
| 2026-07-16 | v2 emitted all-`<unk>` for a 6.9s English clip (2046ms). Re-run later on the same wav: perfect transcript from the same model. Transient runtime corruption, plausibly Metal under memory pressure — watch for recurrence. |
| 2026-07-17 | Latency spikes (800–1400ms vs ~250ms baseline) cluster after idle gaps — model paged out. Confirmed from clips.db: 859ms avg <30s idle → 1650ms avg >5m idle, max 8.8s. Led to the engine keep-warm heartbeat. |
| 2026-07-18 | Hard hang, Ctrl+C-immune. `sample` showed a CoreAudio lock-order deadlock between PortAudio's stream stop and the HAL IO thread — triggered by per-clip stream start/stop churn. Fix: one persistent mic stream, tones via afplay, transcription on a worker thread, exit via os._exit. Also: process footprint grew to 5.9GB after ~a day — watch memory over long sessions. |
| 2026-07-16→18 | Mishear collection became the personal-dictionary seed rules (vocab.toml) and its test set. |

### STT engine bench
**Question:** which local STT engine wins on latency × accuracy for *my* voice and vocabulary?

Contenders, roughly in bench order:

*Drop-in today (experiment 01's `--model` flag takes any parakeet-mlx id):*
- **parakeet-tdt-0.6b-v2** — current default, English-only, fastest on M-series
- **parakeet-tdt-0.6b-v3** — multilingual successor (25 languages), ~same speed; try first
- **parakeet-tdt-1.1b** — bigger sibling, better accuracy; does it stay under the "feels instant" bar?

*Needs an mlx-whisper runner:*
- **whisper-large-v3-turbo** — multilingual quality ceiling; also the Tamil/Hindi code-switching option
- **distil-whisper-large-v3** — English-only speed distill; the most direct parakeet challenger

*Different runners, each with a specific reason:*
- **Apple SpeechAnalyzer** (macOS 26 on-device API) — Swift-only (bench via tiny Swift CLI), but
  effectively zero RAM cost since the system manages the model — kills the resident-700MB concern
- **whisper.cpp** — C implementation, Metal backend; matters if the real app is Swift (easy to embed)
- **Kyutai STT** (`stt-2.6b-en`, MLX support) — streaming-first; the engine for the streaming experiment
- **Moonshine** (tiny/base) — extremely small English models; relevant if abra ever goes always-on

*Wildcard (really a Phase 3 candidate):*
- **Voxtral-Mini** (Mistral 3B audio-LLM) — transcribes *and* cleans/formats in one pass;
  could collapse STT + LLM cleanup into a single model

Method: record 15–20 real dictation clips (messages, code comments, emails —
include names, jargon, your employer/project vocabulary). Run every engine over the same
clips. Score WER against hand-corrected transcripts + wall-clock latency.

- **Output:** a table in the experiment README; the winner becomes the default engine.
- **Note:** keep the clips — they're the regression suite for every later change.

## Phase 2 — make it pleasant

### Hotkey ergonomics
**Question:** which activation gesture disappears from conscious thought?

- Right Option hold (current) vs F13/F14 (remapped via Karabiner) vs double-tap-and-hold a modifier
- ~~The Fn key is special-cased by macOS and invisible to pynput — test whether a
  CGEventTap can see it~~ **ANSWERED 2026-07-19: yes.** The Swift shell's CGEventTap
  sees Fn (keycode 63 in flagsChanged) and hold-Fn-to-talk works. pynput limitation
  confirmed as Python-shell-only.
- Push-to-talk vs toggle (tap to start, tap to stop) for long dictation
- **Kill criteria:** anything that misfires during normal typing, or that you have to think about.

### Text injection methods
**Question:** what's the most reliable way to land text in *every* app?

- **Pasteboard + ⌘V** (current): works everywhere, but clobbers/restores the clipboard —
  test the restore race in Electron apps (Slack, VS Code, Discord) and terminals
- **CGEvent per-character keystrokes:** no clipboard involvement; test speed on long
  transcripts and behavior with non-ASCII
- **Accessibility API (`AXUIElement`) insertion:** cleanest when it works; map which
  apps support it and fall back per-app
- **Output:** a decision matrix (app × method → works?), and the fallback chain the real app should use.

### VAD + audio hygiene
**Question:** can silence trimming and auto-stop cut perceived latency further?

- Silero VAD (tiny, fast) to trim leading/trailing silence before STT
- Auto-stop on N seconds of silence for toggle mode
- Chunk long recordings at pause boundaries so transcription overlaps speech
- **Measure:** latency delta on real clips; false-cut rate on slow, thoughtful speech.

## Phase 3 — the magic

### LLM cleanup pass
**Question:** how much does a local LLM polish add, and is the latency worth it?

- Models: Qwen 2.5 3B / Llama 3.2 3B via Ollama or MLX; also try a 1B for speed
- Tasks, in increasing ambition: strip fillers ("um", "you know", repeated words) →
  punctuation/capitalization → self-correction handling ("meet at 3 — no wait, 4" → "meet at 4")
- Prompted rewrite vs constrained edit (the model can hallucinate; measure fidelity, not just fluency)
- **Measure:** added latency (target ≤ 500 ms), and a blind A/B — raw vs cleaned — over 20 real dictations.
- Make it a toggle from day one; raw STT is often fine for quick messages.

### Context-aware formatting
**Question:** does knowing the frontmost app improve output enough to justify the plumbing?

- Read the frontmost app via NSWorkspace: Slack → casual + emoji ok, Mail → paragraphs,
  VS Code/terminal → code-comment style, no smart quotes
- Feed app identity into the cleanup prompt
- This is the commercial dictation apps' real differentiator — worth an honest attempt before deciding it's gimmick.

### Personal dictionary — ⭐ killer feature, build early
**Question:** can a custom vocabulary fix the proper-noun problem (names, products, project jargon)?

Day-one usage already produced the test set: "CTU"→CPU, "UV run a bra"→uv run abra,
"Come in and push"→commit and push, "Oome"→OOM, and more — all preserved in
clips.db, seeded into vocab.toml / vocab.local.toml.

- Post-STT fuzzy replacement table (cheap, works with any engine)
- Engine-level: initial-prompt biasing (whisper) / keyword boosting where supported
- LLM-pass injection: "the user's vocabulary includes: …"
- **Measure:** proper-noun accuracy on the Phase 1 clip suite before/after.

### Streaming transcription
**Question:** does showing words as you speak beat fast-batch on feel?

- parakeet-mlx supports streaming; whisper needs chunked hacks
- Streaming complicates the cleanup pass (text keeps changing) — maybe stream raw, then swap in cleaned text on release
- Batch-on-release may honestly be good enough; treat this as a UX experiment, not a latency one.

## Phase 4 — become a real app

### Swift menu bar shell
**Question:** what does the production skeleton look like?

- SwiftUI menu bar app: proper Microphone/Accessibility/Input Monitoring permission flows,
  recording indicator (floating pill or menu bar animation), launch at login, sparkle-free updates later
- CGEventTap at HID level — retest the Fn key here
- Embed the Phase 1 winner: whisper.cpp links directly; parakeet needs a helper process or a port
- Read VoiceInk's source first (github.com/Beingpax/VoiceInk) — it has already hit
  the event-tap and pasteboard-restore edge cases; Handy (github.com/cjpais/Handy) for the Rust/Tauri angle.

### Python-daemon + thin-client architecture (alternative)
**Question:** can the Python prototype just… stay, with a Swift/menu-bar veneer over a local daemon?

- Keeps MLX Python ecosystem access (models, VAD, LLM) without porting
- Costs: process management, install story, memory footprint
- Decide only after the Swift shell experiment shows how painful embedding is.

## Parking lot (unordered)

- Multilingual / code-switching dictation (parakeet is English-only; whisper handles Tamil/Hindi mixing)
- Voice commands mixed into dictation ("new line", "send it")
- Whole-system dictation history with search (privacy: local SQLite, encrypted?)
- iOS companion (keyboard extension) — different beast entirely
- Fine-tuning/LoRA on own voice if accuracy plateaus

---

**Working rules:** one question per experiment · measure before opinion ·
keep the recorded clip suite as the shared benchmark · a killed experiment
gets a paragraph here on why, so it stays killed.
