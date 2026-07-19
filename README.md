<p align="center">
  <img src="shells/mac/icon/abra-1024.png" width="128" alt="abra icon">
</p>

# abra

> *abracadabra* — from the Aramaic **avra kehdabra**: "I create as I speak."

Local push-to-talk dictation for macOS. **Hold Fn, speak, release** — clean
text appears wherever your cursor is. Everything runs on-device: nothing you
say ever leaves your Mac.

- **Fast** — NVIDIA Parakeet on Apple's MLX; a few seconds of speech
  transcribes in ~250ms on Apple Silicon
- **Private** — no cloud, no accounts, no telemetry; audio and transcripts
  stay in a local folder you own
- **Personal dictionary** — phrase rules fix *your* recurring mishears
  ("come in and push" → "commit and push"); add yours in `vocab.local.toml`
- **Native** — menu bar app, hold-Fn (or right Option) hotkey,
  launch at login; mic indicator only lights while you're actually recording
- **Yours to inspect** — every dictation is logged to a local SQLite corpus
  with timing metadata, which doubles as a benchmark suite for comparing
  STT models on your own voice

## Requirements

- Apple Silicon Mac, macOS 13+
- [uv](https://docs.astral.sh/uv/) and [ffmpeg](https://ffmpeg.org)
  (`brew install uv ffmpeg`)
- ~700MB disk for the model (downloaded on first run)

## Install

```bash
git clone https://github.com/ramsrib/abra ~/.abra/engine
cd ~/.abra/engine
uv sync
make app          # builds, signs, installs /Applications/Abra.app
open /Applications/Abra.app
```

Grant the permission prompts (Microphone, Accessibility, Input Monitoring —
all attributed to "abra"), then hold **Fn** and talk. Enable *Launch at
Login* from the menu bar icon.

Terminal-only use works too — `make run` starts the Python shell (hold right
Option), attributed to your terminal's permissions instead.

## How it works

```
hold key ──▶ mic capture ──▶ local STT ──▶ personal dictionary ──▶ paste at cursor
```

The load-bearing decision (see `ARCHITECTURE.md`): a **permanent Python
engine** (STT, dictionary, corpus, keep-warm) behind a small JSON protocol,
with **replaceable shells** — a Swift menu bar app and a Python terminal
shell today. Features live in the engine and survive shell rewrites.

- `abra/engine/` — STT → dictionary → (future: LLM cleanup); SQLite corpus;
  `abra-engine` protocol server
- `abra/shell/` — Python shell: pynput hotkey, mic, tones, paste
- `shells/mac/` — Swift menu bar shell (hold-Fn, the daily driver)
- `vocab.toml` / `vocab.local.toml` — dictionary rules (shared / yours)
- `EXPERIMENTS.md` — the experiment backlog this project runs on

## Your data

Every dictation stores its wav + metadata (timings, model, audio levels,
transcript) in `clips/` — local, gitignored, yours. It exists so you can
hand-correct transcripts into ground truth and benchmark engines against
your own voice (`make stats` for a quick look). Delete it anytime.

## Prior art

[VoiceInk](https://github.com/Beingpax/VoiceInk) ·
[Handy](https://github.com/cjpais/Handy) — different takes on the same idea,
both worth reading.

## License

MIT
