"""Personal dictionary: phrase-level corrections applied to raw STT output.

Rules live in vocab.toml at the repo root — plain [replace] pairs, matched
case-insensitively on word boundaries, longest phrase first. The seed rules
come from real mishears in the clip corpus.
"""

import re
import sys
import tomllib
from pathlib import Path


class Dictionary:
    def __init__(self, rules: dict[str, str]):
        # Longest first so "come in and push" wins over any shorter overlap.
        self._rules = [
            (re.compile(rf"\b{re.escape(k)}\b", re.IGNORECASE), v)
            for k, v in sorted(rules.items(), key=lambda kv: -len(kv[0]))
        ]

    @classmethod
    def load(cls, path: Path) -> "Dictionary":
        """Load path, then merge <name>.local.toml (gitignored) over it."""
        rules: dict[str, str] = {}
        sources = [path, path.with_name(path.stem + ".local.toml")]
        for p in sources:
            if p.exists():
                with p.open("rb") as f:
                    rules.update(tomllib.load(f).get("replace", {}))
        if rules:
            print(f"dictionary: {len(rules)} rules", file=sys.stderr, flush=True)
        return cls(rules)

    def apply(self, text: str) -> str:
        for pattern, replacement in self._rules:
            text = pattern.sub(replacement, text)
        return text
