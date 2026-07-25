"""Personal dictionary: phrase-level corrections applied to raw STT output.

Two layers, merged:

- **seed rules** — `vocab.toml` shipped next to the engine source. Committed,
  the same for everyone, read-only from the UI.
- **your rules** — `~/.abra/vocab.local.toml`. ONE file for the whole machine,
  so `make run` from a checkout and /Applications/Abra.app never drift apart.

Rules are matched case-insensitively on word boundaries, longest phrase first.
Both files are re-read when they change on disk, so edits from the menu bar
app or a text editor land on the next dictation without an engine restart.

Writes are line-oriented rather than a TOML re-dump: hand-written comments and
formatting in the user file survive an add or a remove.
"""

import os
import re
import shutil
import sys
import threading
import tomllib
from dataclasses import dataclass
from pathlib import Path

USER_VOCAB = Path(
    os.environ.get("ABRA_USER_VOCAB", Path.home() / ".abra" / "vocab.local.toml")
).expanduser()

# Pre-0.3 the user file sat next to whichever copy of the engine was running —
# a repo checkout and ~/.abra/engine kept separate dictionaries. Seeded once
# into USER_VOCAB; the originals are left on disk but no longer read.
_LEGACY_USER_VOCABS = (Path.home() / ".abra" / "engine" / "vocab.local.toml",)

_HEADER = """\
# abra personal dictionary — your rules, applied to raw STT output.
#
# Maintained by the menu bar app (abra ▸ Dictionary…) and safe to hand-edit;
# comments and layout here are preserved. Format:
#
#   "what abra heard" = "what you meant"

[replace]
"""

# "key" = ... | bare_key = ... — enough to find the rule a line defines.
_ASSIGN = re.compile(r'^\s*(?:"((?:[^"\\]|\\.)*)"|([A-Za-z0-9_-]+))\s*=')
_TABLE = re.compile(r"^\s*\[")


@dataclass(frozen=True)
class Rule:
    heard: str
    replacement: str
    builtin: bool  # from vocab.toml — shown, but not editable


class Dictionary:
    def __init__(self, seed_path: Path, user_path: Path = USER_VOCAB):
        self._seed_path = seed_path
        self._user_path = user_path
        self._lock = threading.Lock()
        self._stamp: tuple = ()
        self._seed: dict[str, str] = {}
        self._user: dict[str, str] = {}
        self._compiled: list[tuple[re.Pattern, str]] = []
        _migrate_legacy(user_path, seed_path)
        self._refresh(force=True)

    # -- reading -----------------------------------------------------------

    def rules(self) -> list[Rule]:
        """Your rules first, then the seed rules they haven't overridden."""
        self._refresh()
        with self._lock:
            mine = [Rule(k, v, False) for k, v in self._user.items()]
            seed = [Rule(k, v, True) for k, v in self._seed.items()
                    if k.lower() not in {r.heard.lower() for r in mine}]
        return mine + seed

    @property
    def user_path(self) -> Path:
        return self._user_path

    def apply(self, text: str) -> str:
        self._refresh()
        with self._lock:
            compiled = self._compiled
        for pattern, replacement in compiled:
            # Lambda, not the string: sub() would read \1 or \h in a
            # replacement as a template escape and raise mid-dictation.
            text = pattern.sub(lambda _, r=replacement: r, text)
        return text

    def _refresh(self, force: bool = False) -> None:
        stamp = tuple(_mtime(p) for p in (self._seed_path, self._user_path))
        with self._lock:
            if not force and stamp == self._stamp:
                return
            self._stamp = stamp
            self._seed = _read(self._seed_path)
            self._user = _read(self._user_path)
            merged = {**self._seed, **self._user}
            # Longest first so "come in and push" wins over any shorter overlap.
            self._compiled = [
                (re.compile(_boundaried(k), re.IGNORECASE), v)
                for k, v in sorted(merged.items(), key=lambda kv: -len(kv[0]))
            ]
            count = len(merged)
        if force:
            print(f"dictionary: {count} rules ({self._user_path})",
                  file=sys.stderr, flush=True)

    # -- writing (user file only) ------------------------------------------

    def add(self, heard: str, replacement: str) -> None:
        heard, replacement = heard.strip(), replacement.strip()
        for label, value in (("heard", heard), ("replacement", replacement)):
            if not value:
                raise ValueError(f"{label} is empty")
            if any(c in value for c in "\r\n"):
                raise ValueError(f"{label} spans multiple lines")
        if not re.search(r"\w", heard):
            # \b…\b around a word-char-free phrase can never match.
            raise ValueError("heard phrase needs at least one letter or digit")

        lines = self._user_lines()
        line = f"{_quote(heard)} = {_quote(replacement)}"
        for i, existing in enumerate(lines):
            if _key_of(existing) == heard.lower():
                lines[i] = line  # same phrase again: retarget it
                break
        else:
            lines.append(line)
        self._write(lines)

    def remove(self, heard: str) -> None:
        lines = self._user_lines()
        kept = [ln for ln in lines if _key_of(ln) != heard.strip().lower()]
        if len(kept) == len(lines):
            raise ValueError(f"no rule for {heard!r}")
        self._write(kept)

    def _user_lines(self) -> list[str]:
        if not self._user_path.exists():
            return _HEADER.splitlines()
        lines = self._user_path.read_text().splitlines()
        if not any(_TABLE.match(ln) for ln in lines):
            lines += ["", "[replace]"]  # hand-made file with no table yet
        return lines

    def _write(self, lines: list[str]) -> None:
        self._user_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._user_path.with_suffix(".toml.tmp")
        tmp.write_text("\n".join(lines).rstrip("\n") + "\n")
        tmp.replace(self._user_path)  # atomic: a crash mid-write can't truncate
        self._refresh(force=True)


def _read(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        with path.open("rb") as f:
            return tomllib.load(f).get("replace", {})
    except (tomllib.TOMLDecodeError, OSError) as e:
        # A hand-edit with a typo must not take dictation down with it.
        print(f"dictionary: ignoring {path} — {e}", file=sys.stderr, flush=True)
        return {}


def _boundaried(phrase: str) -> str:
    """Word-boundary the phrase, but only at edges that are word characters.

    A blind \\b…\\b never matches a phrase that starts or ends in punctuation
    ('say "hi"'): the boundary would have to fall between two non-word chars.
    """
    prefix = r"\b" if re.match(r"\w", phrase) else ""
    suffix = r"\b" if re.search(r"\w\Z", phrase) else ""
    return prefix + re.escape(phrase) + suffix


def _mtime(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return None


def _quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _key_of(line: str) -> str | None:
    """The rule a line defines, lowercased — None for comments and blanks."""
    m = _ASSIGN.match(line)
    if not m:
        return None
    quoted, bare = m.groups()
    key = bare if quoted is None else re.sub(r"\\(.)", r"\1", quoted)
    return key.lower()


def _migrate_legacy(user_path: Path, seed_path: Path) -> None:
    """Seed the shared user file from wherever rules used to live."""
    if user_path.exists():
        return
    candidates = [seed_path.with_name("vocab.local.toml"), *_LEGACY_USER_VOCABS]
    found = [p for p in candidates if p.exists() and p != user_path]
    if not found:
        return
    user_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(found[0], user_path)
    print(f"dictionary: migrated {found[0]} → {user_path}",
          file=sys.stderr, flush=True)
    for other in found[1:]:
        if _read(other) != _read(user_path):
            print(f"dictionary: note — {other} has different rules and is no "
                  "longer read; merge anything you want by hand",
                  file=sys.stderr, flush=True)
