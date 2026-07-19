# Engineering notes & chores

The third notebook, complementing the other two:

- **`ARCHITECTURE.md`** — decisions and invariants (things that stay true)
- **`EXPERIMENTS.md`** — product/research questions and their findings
- **`NOTES.md`** (this file) — internal detail: engineering chores, operational
  knowledge, and todos that are neither architecture nor experiments.
  User-visible bugs/features graduate to GitHub issues.

## Todo

- [ ] **0.3: bundle the engine into Abra.app** (python-build-standalone +
  pre-synced deps in Resources) — removes the uv/git/`~/.abra/engine`
  dependency entirely; cask shrinks to "install app". The headline chore.
- [ ] **Self-relaunch after upgrade** — a running instance survives
  `brew upgrade`/`make release` bundle swaps and keeps executing old code
  ("zombie instance"). Detect the bundle change on disk and prompt to relaunch.
- [ ] **STT bench (experiment 02)** — blocked on ~30 hand-corrected clips in
  `clips/clips.db` (`corrected` column; workflow in the clips section of the
  old experiment notes / `make stats`).
- [ ] **Memory watch** — engine grew to 5.9GB after ~a day of use (see
  EXPERIMENTS findings). If it recurs: periodic `mx.clear_cache()` or
  idle-unload with ~1.3s reload cost.
- [ ] **Per-app paste matrix** — AX insertion where supported, ⌘V fallback;
  test clipboard-restore races in Electron apps.
- [ ] **First-word clipping check** — resuming the paused AVAudioEngine on
  hotkey press takes ~tens of ms; verify no speech onset is lost, else add a
  pre-roll buffer.

## Operational knowledge

- **Release**: `make release` does everything (build → sign → notarize →
  staple → zip → GitHub release → cask bump). Notary credentials in `.env`
  (App Store Connect API key, same convention as sibling projects).
  Bump `CFBundleShortVersionString` + `CFBundleVersion` first.
- **After any upgrade/release, quit and relaunch the app** — see zombie
  instance above.
- **Shell log**: `~/Library/Logs/abra-shell.log` — engine lifecycle, engine
  stderr, protocol failures. First place to look when the menu shows ⚠.
- **Engine supervision**: auto-restart with exponential backoff (1→16s),
  gives up after 5 consecutive failures with a log pointer. Counter resets on
  each successful `ready`.
- **Homebrew postflight runs with a sanitized PATH** — always use
  `#{HOMEBREW_PREFIX}/bin/...` absolute paths in the cask.
- **The cask pins the engine to the release tag** — breaking `main` never
  affects users; things reach brew users only via `make release`.
- **Corpus queries**: `make stats`, or sqlite3 against `clips/clips.db`
  (`clips` + `sessions` tables).
