#!/usr/bin/env python3
"""Section-aware TOML key setter for shadPS4's config.toml.

Dependency-free (no tomli_w needed): sets `key = value` inside `[Section]`,
creating the section or key if absent, preserving everything else. Only scalar
values (bool/int/string) are supported — that's all shadPS4's config needs.

Usage:
    patch_config.py <config.toml> Section.key=value [Section.key=value ...]

Values are typed by shape: true/false -> bool, digits -> int, else quoted string.
If the file doesn't exist yet it's created with just the requested keys.
"""
import sys
from pathlib import Path


def typed(raw: str) -> str:
    low = raw.lower()
    if low in ("true", "false"):
        return low
    if raw.lstrip("-").isdigit():
        return raw
    # already quoted? leave it; else quote it
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        return raw
    return '"' + raw.replace('"', '\\"') + '"'


def set_key(lines: list[str], section: str, key: str, value: str) -> list[str]:
    out, in_section, done = [], False, False
    sec_header = f"[{section}]"
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            # leaving a section: if it was ours and key never set, insert it
            if in_section and not done:
                out.append(f"{key} = {value}\n")
                done = True
            in_section = stripped == sec_header
        elif in_section and not done:
            # match `key =` (allowing leading spaces)
            head = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
            if head == key:
                indent = line[: len(line) - len(line.lstrip())]
                out.append(f"{indent}{key} = {value}\n")
                done = True
                i += 1
                continue
        out.append(line)
        i += 1

    if in_section and not done:  # section was the last one in file
        out.append(f"{key} = {value}\n")
        done = True
    if not done:  # section didn't exist at all
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        # ONE LINE PER ELEMENT. This used to append the whole block as a single
        # multi-line string, and the next set_key() call could not see it: the loop
        # tests `stripped.startswith("[") and stripped.endswith("]")`, and the blob
        # "[GPU]\nvblankFrequency = 60" ends in "0", so the section was invisible and
        # a SECOND "[GPU]" header got appended. Duplicate tables are invalid TOML.
        # Confirmed on-device: every Deck install wrote a config.toml with two [GPU]
        # sections, so none of these settings could be relied on.
        out.append("\n")
        out.append(f"{sec_header}\n")
        out.append(f"{key} = {value}\n")
    return out


def collapse_duplicate_sections(lines: list[str]) -> list[str]:
    """Merge repeated [Section] headers into one, preserving first-seen order.

    Heals files already corrupted by the bug above (they exist on real installs).
    A no-op on a well-formed file. Lines before the first header are kept as-is.
    """
    preamble: list[str] = []
    order: list[str] = []
    bodies: dict[str, list[str]] = {}
    current = None
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            current = s
            if current not in bodies:
                bodies[current] = []
                order.append(current)
            continue
        (bodies[current] if current is not None else preamble).append(line)

    out = list(preamble)
    for sec in order:
        out.append(f"{sec}\n")
        body = _dedupe_keys(bodies[sec])
        # drop leading/trailing blank lines inside a section, then re-add one after
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        out.extend(body)
        out.append("\n")
    return out


def _dedupe_keys(body: list[str]) -> list[str]:
    """Collapse repeated `key =` lines within one section: last value wins, first
    position kept. Non-assignment lines (comments, blanks) pass through untouched.

    A duplicate KEY is just as invalid as a duplicate table — TOML rejects the file
    with "Cannot overwrite a value" and shadPS4 then silently runs on DEFAULTS. That
    is what made this so hard to spot: the default vblankFrequency is 60, which is
    exactly the value we were trying to set, so the config looked like it applied.
    The giveaway was `isDevKitMode = true` in the file but `isDevKit: false` in the
    emulator's own boot log.
    """
    def keyof(line: str):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            return None
        return s.split("=", 1)[0].strip()

    latest: dict[str, str] = {}
    for line in body:
        k = keyof(line)
        if k is not None:
            latest[k] = line

    out, seen = [], set()
    for line in body:
        k = keyof(line)
        if k is None:
            out.append(line)
        elif k not in seen:
            seen.add(k)
            out.append(latest[k])
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    lines = path.read_text().splitlines(keepends=True) if path.exists() else []
    # HEAL FIRST, THEN SET. Order matters: set_key() inserts a key when it sees a
    # section header while still looking for that key, so running it against a file
    # that already has a duplicate [Section] inserts at the SECOND header and leaves
    # the real line behind it — turning a duplicate table into a duplicate KEY. Both
    # are invalid TOML. Collapsing first means set_key always sees a well-formed file.
    lines = collapse_duplicate_sections(lines)
    for assignment in sys.argv[2:]:
        if "=" not in assignment or "." not in assignment.split("=", 1)[0]:
            print(f"skip malformed: {assignment}", file=sys.stderr)
            continue
        dotted, raw = assignment.split("=", 1)
        section, key = dotted.split(".", 1)
        lines = set_key(lines, section.strip(), key.strip(), typed(raw.strip()))
    lines = collapse_duplicate_sections(lines)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines))
    print(f"patched {path} ({len(sys.argv) - 2} keys)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
