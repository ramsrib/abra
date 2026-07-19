# AbraShell — native macOS shell (parallel track)

The Swift shell that will eventually replace the Python one. It owns only the
platform-coupled pieces — hotkey, mic capture, tones, paste, menu bar — and
talks to the Python engine over the stdio JSON protocol defined in
`ARCHITECTURE.md`. Features (dictionary, cleanup, formatting) never live here.

## Status

**Functional menu bar app** (dev-launched). `make mac` gives you: a mic icon
in the menu bar, hold **Fn or right Option** to record (icon goes solid),
release to transcribe and paste at the cursor. Engine runs as a child
process; icon tooltip shows state, latency, and the last transcript.

Dev-launch caveat: run from a terminal, permissions attribute to that
terminal (mic/accessibility/input monitoring — same grants the Python shell
uses). Standalone permission identity arrives with the app bundle step.
Stop the Python shell first (`make kill`) — both react to right Option.

If quick Fn taps open the emoji picker, set System Settings → Keyboard →
"Press 🌐 key to" → **Do Nothing** (hold-to-talk is mostly unaffected).

## Roadmap

1. ✅ Engine subprocess + protocol round-trip
2. ✅ Menu bar presence (NSStatusItem) with recording indicator
3. ✅ Global hotkey via CGEventTap — **Fn key verified working 2026-07-19**
   (the pynput-can't-see-it experiment: answered, yes it can)
4. ✅ AVAudioEngine capture → 16kHz mono wav → `transcribe` command
5. ✅ Paste injection (pasteboard + CGEvent ⌘V); later: AX insertion per app
6. ✅ `make app`: Abra.app bundle, Developer ID signed (com.sriramb.abra.shell),
   installed to /Applications — own permission identity, no terminal
7. ✅ Launch at Login toggle in the menu (SMAppService; needs the .app install)

Next: own the corpus/engine location properly (currently the app finds the
repo via a compile-time path — fine for a dev machine, not for distribution).

## Build & run

```bash
cd shells/mac
swift run
```
