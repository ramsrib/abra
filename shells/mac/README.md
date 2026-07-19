# AbraShell — native macOS shell (parallel track)

The Swift shell that will eventually replace the Python one. It owns only the
platform-coupled pieces — hotkey, mic capture, tones, paste, menu bar — and
talks to the Python engine over the stdio JSON protocol defined in
`ARCHITECTURE.md`. Features (dictionary, cleanup, formatting) never live here.

## Status

**The daily driver** — shipped as the signed, notarized `Abra.app` via
`make release` / `brew install ramsrib/tap/abra`. Features:

- Menu bar app (no dock icon); icon shows state, tooltip shows latency and
  the last transcript; menu stays quiet unless starting or erroring
- Hold-to-talk hotkey via CGEventTap — **Fn** (default, invisible to pynput
  but visible here), right ⌥, or right ⌘, switchable from the Hotkey menu
- Combo passthrough: any other key pressed while holding cancels the
  recording silently — Fn+arrows and ⌘-shortcuts behave normally
- Mic-in-use indicator only lights while recording (audio engine pauses
  between clips); start tone is delayed 120ms so cancelled combos are silent
- Sequential permission prompts (mic first, then accessibility/input
  monitoring) — simultaneous dialogs clobber each other
- Engine supervision: auto-restart with backoff, bounded at 5 failures;
  diagnostics in `~/Library/Logs/abra-shell.log`
- Launch at Login (SMAppService)

Engine resolution at runtime: `$ABRA_ENGINE_DIR` → `~/.abra/engine`
(brew-install location, pinned to the release tag) → the dev checkout.

Dev loop: `make mac` runs from the terminal (permissions attribute to the
terminal). If quick Fn taps open the emoji picker, set System Settings →
Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Next

Chores and todos live in `NOTES.md` at the repo root — headline items:
bundle the engine into the .app (0.3), self-relaunch after upgrades,
per-app AX paste insertion.

## Build & run

```bash
cd shells/mac
swift run
```
