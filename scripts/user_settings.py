#!/usr/bin/env python3
"""Read and write the user's Workshop settings.

    --json / --human / --get KEY / --set KEY=VALUE … / --reset
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SETTINGS = [
    {
        "key": "VULKAN_GPU_ID",
        "kind": "gpu",
        "default": "-1",
        "title": "Graphics device",
        "blurb": "Which GPU (if multiple) shadPS4 uses. If unsure, leave as the default.",
    },
    {
        "key": "DECKBORNE_FPS_COUNTER",
        "kind": "pills",
        "default": "auto",
        "options": [["on", "On"], ["off", "Off"]],
        "auto_var": "SHOW_FPS_DECKBORNE",
        "auto_fallback": "off",
        "title": "On-screen FPS counter",
        "blurb": "Enable in-game Frames Per Second overlay.",
    },
    {
        "key": "DECKBORNE_HDR",
        "kind": "pills",
        "default": "auto",
        "options": [["on", "On"], ["off", "Off"]],
        "auto_var": "HDR_DECKBORNE",
        "auto_fallback": "on",
        "title": "Allow HDR output",
        "blurb": "Lets shadPS4 use an HDR swapchain when the display supports one.",
    },
    {
        "key": "DECKBORNE_PRESENT_MODE",
        "kind": "pills",
        "default": "auto",
        "options": [["fifo", "Fifo"], ["mailbox", "Mailbox"], ["immediate", "Immediate"]],
        "auto_var": "PRESENT_MODE_DECKBORNE",
        "auto_fallback": "fifo",
        "title": "Present mode",
        "blurb": "How shadPS4 presents frames. Fifo is standard vsync.",
    },
    {
        "key": "DECKBORNE_SHADER_CACHE",
        "kind": "pills",
        "default": "auto",
        "options": [["on", "On"], ["off", "Off"]],
        "auto_var": "PIPELINE_CACHE",
        "auto_fallback": "off",
        "title": "Shader cache (Experimental)",
        "blurb": "Reuse compiled shaders between launches. Enabling in testing writes cache "
                 "files every launch and never reads them back.",
    },
]

BY_KEY = {s["key"]: s for s in SETTINGS}


def options_for(spec: dict) -> list[str]:
    return [o[0] for o in spec.get("options", [])]


def _as_option(raw: str) -> str:
    v = raw.strip().lower()
    if v in ("true", "1"):
        return "on"
    if v in ("false", "0"):
        return "off"
    return v


def auto_values() -> dict[str, str]:
    """What each setting's stored 'auto' currently resolves to, per config/deckborne.env.

    Read from the env itself rather than duplicated here, so the panel cannot drift from
    what stage 30 will actually write. Resolved against the DeckBorne profile.
    """
    wanted = [(s["key"], s["auto_var"]) for s in SETTINGS if s.get("auto_var")]
    out = {s["key"]: s.get("auto_fallback", "") for s in SETTINGS if s.get("auto_var")}
    if not wanted:
        return out
    root = os.environ.get("DECKBORNE_ROOT") or str(Path(__file__).resolve().parent.parent)
    script = ('source "$0/scripts/lib.sh" >/dev/null 2>&1 || exit 1; '
              'load_env >/dev/null 2>&1 || exit 1; ') + "".join(
        f'printf "%s\\n" "${{{var}}}"; ' for _, var in wanted)
    try:
        res = subprocess.run(["bash", "-c", script, root],
                             capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return out
    if res.returncode != 0:
        return out
    lines = res.stdout.splitlines()
    for (key, _), raw in zip(wanted, lines):
        val = _as_option(raw)
        if val in options_for(BY_KEY[key]):
            out[key] = val
    return out

_LINE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)="\$\{\1:-(.*)\}"\s*$')
_PLAIN = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)=(?:"([^"]*)"|\'([^\']*)\'|(\S*))\s*$')

HEADER = """\
# DeckBorne user settings — written by the UI's Workshop panel.
# Sourced by scripts/lib.sh before config/deckborne.env, so an explicit environment
# variable still wins. Only values differing from the shipped default are kept.
# Safe to delete: everything falls back to the shipped defaults.
"""


def state_dir() -> Path:
    d = os.environ.get("DECKBORNE_STATE_DIR")
    return Path(d) if d else Path.home() / ".local" / "share" / "DeckBorne"


def settings_path() -> Path:
    f = os.environ.get("DECKBORNE_SETTINGS_FILE")
    return Path(f) if f else state_dir() / "settings.env"


def validate(key: str, value: str) -> tuple[bool, str]:
    spec = BY_KEY.get(key)
    if spec is None:
        return False, f"unknown setting '{key}'"
    v = value.strip()
    if spec["kind"] == "pills":
        allowed = options_for(spec) + [spec["default"]]
        if v.lower() not in allowed:
            return False, f"{key}: expected one of {'|'.join(allowed)}, got '{value}'"
        return True, v.lower()
    if spec["kind"] == "gpu":
        try:
            n = int(v)
        except ValueError:
            return False, f"{key}: expected an integer, got '{value}'"
        if n < -1:
            return False, f"{key}: must be -1 (auto) or a device index, got {n}"
        return True, str(n)
    return False, f"{key}: no validator"


def load() -> dict[str, str]:
    try:
        text = settings_path().read_text()
    except OSError:
        return {}
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _LINE.match(line)
        if m:
            key, val = m.group(1), m.group(2)
        else:
            m = _PLAIN.match(line)
            if not m:
                continue
            key = m.group(1)
            val = next((g for g in m.groups()[1:] if g is not None), "")
        if key in BY_KEY:
            ok, norm = validate(key, val)
            if ok:
                out[key] = norm
    return out


def resolved() -> dict[str, str]:
    stored = load()
    return {s["key"]: stored.get(s["key"], s["default"]) for s in SETTINGS}


def save(values: dict[str, str]) -> None:
    keep = {k: v for k, v in values.items()
            if k in BY_KEY and v != BY_KEY[k]["default"]}
    path = settings_path()
    if not keep:
        try:
            path.unlink()
        except OSError:
            pass
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    body = [HEADER]
    for s in SETTINGS:
        if s["key"] in keep:
            body.append(f'{s["key"]}="${{{s["key"]}:-{keep[s["key"]]}}}"\n')
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("".join(body))
    os.replace(tmp, path)
    try:
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    except OSError:
        pass


def gpu_report() -> dict:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import detect_gpu
        return detect_gpu.report()
    except Exception:
        return {"source": "none", "devices": [], "auto_index": -1, "auto_reason": ""}


def human(res: dict[str, str], stored: dict[str, str]) -> str:
    lines = [f"Workshop settings ({settings_path()}):"]
    for s in SETTINGS:
        mark = "" if s["key"] in stored else "   (default)"
        lines.append(f"    {s['title']}: {res[s['key']]}{mark}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if "--set" in argv or "--reset" in argv:
        values = {} if "--reset" in argv else load()
        i = 0
        while i < len(argv):
            if argv[i] == "--set" and i + 1 < len(argv):
                pair = argv[i + 1]
                if "=" not in pair:
                    print(f"expected KEY=VALUE, got '{pair}'", file=sys.stderr)
                    return 2
                key, _, raw = pair.partition("=")
                ok, norm = validate(key.strip(), raw)
                if not ok:
                    print(norm, file=sys.stderr)
                    return 2
                values[key.strip()] = norm
                i += 2
                continue
            i += 1
        try:
            save(values)
        except OSError as exc:
            print(f"could not write {settings_path()}: {exc}", file=sys.stderr)
            return 1

    stored = load()
    res = resolved()
    if "--get" in argv:
        key = argv[argv.index("--get") + 1]
        if key not in BY_KEY:
            print(f"unknown setting '{key}'", file=sys.stderr)
            return 2
        print(res[key])
        return 0
    if "--json" in argv:
        json.dump({
            "path": str(settings_path()),
            "schema": SETTINGS,
            "values": res,
            "stored": sorted(stored),
            "auto": auto_values(),
            "gpu": gpu_report(),
        }, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    print(human(res, stored))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
