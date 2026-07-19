#!/usr/bin/env python3
"""Section-aware JSON setter for shadPS4's config.json (v0.16+).

Replaces patch_config.py, which wrote a config.toml that shadPS4 never read (wrong
directory AND wrong format — see config/deckborne.env for the full story).

Usage:
    patch_config_json.py <config.json> Section.key=value [Section.key=value ...]

MERGES into the existing file: unknown sections and unknown keys are preserved
untouched. shadPS4 keeps ALL of its settings in this one file, so clobbering it would
throw away everything the user configured in the emulator itself.

TYPES ARE LOAD-BEARING. shadPS4's loader calls j.get<T>() per key and a mismatch throws:
the exception propagates out of the whole load, so every section merged AFTER the bad one
silently reverts to defaults, and `m_loaded` is never set (so the emulator also skips its
save-on-exit). `"vblank_frequency": "60"` — a string where a number belongs — is enough to
do it, and the only symptom is one line in shad_log.txt. Hence: true/false -> bool,
digits -> int, everything else -> string, and a --check pass that re-reads and compares.

shadPS4 rewrites this file on exit (merging, preserving unknown keys), so edits must
happen while the emulator is NOT running — same discipline as Steam's VDFs.
"""
import json
import os
import shutil
import sys
from pathlib import Path


def typed(raw: str):
    low = raw.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if raw.lstrip("-").isdigit():
        return int(raw)
    return raw


def parse_assignments(argv):
    out = []
    for item in argv:
        if "=" not in item or "." not in item.split("=", 1)[0]:
            print(f"skip malformed: {item}", file=sys.stderr)
            continue
        dotted, raw = item.split("=", 1)
        section, key = dotted.split(".", 1)
        out.append((section.strip(), key.strip(), typed(raw.strip())))
    return out


def load_existing(path: Path):
    """Return the current config, or {} if absent. A CORRUPT file is backed up rather
    than merged into — shadPS4 itself resets on unparseable JSON and would drop the
    user's settings silently; at least this way the original is recoverable."""
    if not path.exists():
        return {}
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            raise ValueError("top level is not an object")
        return data
    except Exception as e:
        backup = path.with_suffix(path.suffix + ".deckborne.bak")
        shutil.copy2(path, backup)
        print(f"  ! existing config.json is unreadable ({e})", file=sys.stderr)
        print(f"  ! backed it up to {backup} and starting from a fresh object",
              file=sys.stderr)
        return {}


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    check_only = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--check"]
    path = Path(args[0])
    assignments = parse_assignments(args[1:])
    if not assignments:
        print("no valid assignments", file=sys.stderr)
        return 2

    cfg = load_existing(path)

    if check_only:
        bad = []
        for section, key, value in assignments:
            got = cfg.get(section, {}).get(key, "<missing>")
            # bool is a subclass of int in Python; compare types strictly so that
            # True never validates against 1 (shadPS4 would reject that file).
            if got != value or type(got) is not type(value):
                bad.append(f"{section}.{key}: expected {value!r} ({type(value).__name__}),"
                           f" got {got!r} ({type(got).__name__})")
        if bad:
            for b in bad:
                print(f"  ! {b}", file=sys.stderr)
            return 1
        print(f"  verified {len(assignments)} key(s) in {path.name}: "
              + ", ".join(f"{s}.{k}={v}" for s, k, v in assignments))
        return 0

    for section, key, value in assignments:
        cfg.setdefault(section, {})
        if not isinstance(cfg[section], dict):
            print(f"  ! {section} exists but is not an object — refusing to overwrite",
                  file=sys.stderr)
            return 1
        cfg[section][key] = value

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)          # atomic; a torn config.json breaks the whole load
    print(f"patched {path} ({len(assignments)} keys, {len(cfg)} sections)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
